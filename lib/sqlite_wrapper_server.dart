import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:sqlite_wrapper/sqlite_wrapper.dart';
import 'package:sqlite_wrapper_server/constants.dart';
import 'package:sqlite_wrapper_server/database_pool.dart';

/// Implementation of the SqliteService defined in the proto file.
class SQLiteWrapperServerImpl extends SqliteWrapperServiceBase {
  /// Sanitize dbName against path traversal by replacing any character
  /// that is not alphanumeric, underscore, or hyphen with an underscore.
  String _sanitizeDBName(String dbName) {
    return dbName.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  /// Encode email for safe inclusion in a filename.
  ///
  /// Replaces `@` with `_at_` and `.` with `_dot_` so the email remains
  /// human-readable in the filename. The result is further sanitized by
  /// [_sanitizeDBName] before filesystem use.
  String _encodeEmailForFilename(String email) {
    return email
        .replaceAll('@', '_at_')
        .replaceAll('.', '_dot_');
  }

  /// The DB Name is created appending to the dbName the user UUID and email.
  /// If Constants.dbName is set, it overrides the client-supplied dbName.
  ///
  /// Format: `{prefix}_{sanitizedEmail}_{uuid}`
  String _getDBName({required ServiceCall call, required String dbName}) {
    final String? uuid = call.clientMetadata!['user_uuid'];
    if (uuid == null) {
      if (Constants.sharedDB == true) {
        return dbName;
      } else {
        throw GrpcError.unauthenticated(
            'User not authenticated for non-shared database');
      }
    }
    final String email = call.clientMetadata!['email'] ?? '';
    final String emailSuffix = email.isNotEmpty
        ? '${_encodeEmailForFilename(email)}_'
        : '';
    final prefix = Constants.dbName ?? dbName;
    return '${prefix}_$emailSuffix$uuid';
  }

  String _getDBPath(String dbName) {
    // Strip trailing slash from dbPath to avoid double-slash in the final path.
    String dbPath = Constants.dbPath;
    if (dbPath.endsWith('/')) {
      dbPath = dbPath.substring(0, dbPath.length - 1);
    }
    // Sanitize dbName against path traversal
    return "$dbPath/${_sanitizeDBName(dbName)}.sqlite";
  }

  // Allow all connections without token authentication
  static bool runUnauthenticated = false;

  @override
  Future<OpenDBResponse> openDB(ServiceCall call, OpenDBRequest request) async {
    final String dbName = _getDBName(call: call, dbName: request.dbName);

    print("OpenDB called: version=${request.version}, dbName=$dbName");

    // Warm the connection via the pool so it remains open for subsequent calls.
    final pool = DatabasePool.get(dbName, _getDBPath(dbName),
        version: request.version);
    final version = await pool.getVersion();
    final sqliteVersionRaw =
        await pool.query("PRAGMA sqlite_version", singleResult: true);
    final sqliteVersion = (sqliteVersionRaw as String?) ?? '';

    // openDB is a warm-up call; decrement refcount so the pool can still
    // close cleanly.  The connection stays open because execute/select
    // and watch will call get/subscribe and re-increment.
    // (We keep the refCount bumped for the duration of this RPC only.)
    DatabasePool.close(dbName);

    return OpenDBResponse(
        created: version == 0,
        version: version,
        sqliteVersion: sqliteVersion,
        dbName: dbName);
  }

  @override
  Future<CloseDBResponse> closeDB(
      ServiceCall call, CloseDBRequest request) async {
    final String dbName = _getDBName(call: call, dbName: request.dbName);
    print("CloseDB called: dbName=$dbName");
    DatabasePool.close(dbName);
    return CloseDBResponse(success: true);
  }

  /// Execute an SQL statement with retry for SQLITE_BUSY.
  ///
  /// Retries up to 3 times with backoff 50/100/150ms.
  /// After exhaustion throws GrpcError.unavailable.
  @override
  Future<SqlQueryResponse> execute(
      ServiceCall call, SqlQueryRequest request) async {
    final String dbName = _getDBName(call: call, dbName: request.dbName);
    print(
        "Execute called: sql=${request.sql}, params=$_printParams(request.params), dbName=$dbName");
    final pool = DatabasePool.get(dbName, _getDBPath(dbName));
    try {
      final res = await _runWithRetry(() => pool.execute(
            request.sql,
            params: _unpackParams(request.params),
            tables: request.tables,
          ));
      return SqlQueryResponse(result: _valueFromDart(res));
    } catch (e) {
      if (e is GrpcError && e.code == StatusCode.unavailable) rethrow;
      throw GrpcError.invalidArgument('SQL execution error: $e');
    } finally {
      DatabasePool.close(dbName);
    }
  }

  @override
  Future<SqlQueryResponse> select(
      ServiceCall call, SqlQueryRequest request) async {
    final String dbName = _getDBName(call: call, dbName: request.dbName);
    print(
        "Select called: sql=${request.sql}, params=$_printParams(request.params), dbName=$dbName");
    final pool = DatabasePool.get(dbName, _getDBPath(dbName));
    try {
      final db = pool.getDatabase();
      if (db == null) {
        throw GrpcError.failedPrecondition('Database not opened');
      }
      final res = await db
          .select(request.sql, _unpackParams(request.params));
      return SqlQueryResponse(rows: _rowsFromMaps(res));
    } catch (e) {
      throw GrpcError.invalidArgument('SQL query error: $e');
    } finally {
      DatabasePool.close(dbName);
    }
  }

  @override
  Future<BatchResponse> executeBatch(
      ServiceCall call, BatchRequest request) async {
    print("ExecuteBatch called: count=${request.requests.length}");
    if (request.requests.isEmpty) {
      return BatchResponse();
    }

    // All requests share the same dbName (from the first request).
    final first = request.requests.first;
    final String dbName = _getDBName(call: call, dbName: first.dbName);
    final pool = DatabasePool.get(dbName, _getDBPath(dbName));

    try {
      final responses = <SqlQueryResponse>[];
      for (final req in request.requests) {
        final res = await pool.execute(
          req.sql,
          params: _unpackParams(req.params),
          tables: req.tables,
        );
        responses.add(SqlQueryResponse(result: _valueFromDart(res)));
      }
      return BatchResponse(responses: responses);
    } catch (e) {
      throw GrpcError.invalidArgument('Batch execution error: $e');
    } finally {
      DatabasePool.close(dbName);
    }
  }

  @override
  Stream<WatchResponse> watch(ServiceCall call, WatchRequest request) async* {
    final String dbName = _getDBName(call: call, dbName: request.dbName);
    final String dbPath = _getDBPath(dbName);

    print(
        "Watch called: sql=${request.sql}, tables=${request.tables}, dbName=$dbName");

    final Stream stream = DatabasePool.subscribe(
      dbName: dbName,
      dbPath: dbPath,
      sql: request.sql,
      params: _unpackParams(request.params),
      tables: request.tables,
      singleResult: request.singleResult,
    );

    try {
      await for (final result in stream) {
        if (request.singleResult) {
          if (result is Map<String, dynamic>) {
            yield WatchResponse(
              rows: _rowsFromMaps([result]),
              singleResult: true,
            );
          } else {
            yield WatchResponse(
              result: _valueFromDart(result),
              singleResult: true,
            );
          }
        } else if (result is List<Map<String, dynamic>>) {
          yield WatchResponse(
            rows: _rowsFromMaps(result),
            singleResult: false,
          );
        } else if (result is Map<String, dynamic>) {
          yield WatchResponse(
            rows: _rowsFromMaps([result]),
            singleResult: false,
          );
        } else {
          yield WatchResponse(
            result: _valueFromDart(result),
            singleResult: false,
          );
        }
      }
    } finally {
      DatabasePool.unsubscribe(dbName);
    }
  }

  @override
  Future<ExportBackupResponse> exportBackup(
      ServiceCall call, ExportBackupRequest request) async {
    final String dbName = _getDBName(call: call, dbName: request.dbName);
    final String dbPath = _getDBPath(dbName);

    print("ExportBackup called: dbName=$dbName");

    final file = File(dbPath);
    if (!await file.exists()) {
      throw GrpcError.notFound('Database file not found: $dbPath');
    }

    try {
      final data = await file.readAsBytes();
      return ExportBackupResponse(data: data);
    } catch (e) {
      throw GrpcError.internal('Failed to read database file: $e');
    }
  }

  @override
  Future<ImportBackupResponse> importBackup(
      ServiceCall call, ImportBackupRequest request) async {
    final String dbName = _getDBName(call: call, dbName: request.dbName);
    final String dbPath = _getDBPath(dbName);

    print("ImportBackup called: dbName=$dbName, data.length=${request.data.length}");

    // Validate SQLite magic bytes.
    const sqliteMagic = 'SQLite format 3\x00';
    if (request.data.length < 16 ||
        String.fromCharCodes(request.data.sublist(0, 16)) != sqliteMagic) {
      return ImportBackupResponse(
        success: false,
        message: 'Invalid SQLite database file (magic bytes mismatch)',
      );
    }

    final dbFile = File(dbPath);

    // Create a backup of the current database.
    if (await dbFile.exists()) {
      final now = DateTime.now();
      final timestamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
          '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}_${now.millisecond.toString().padLeft(3, '0')}';
      final backupPath = '${dbPath}_backup_$timestamp';

      try {
        await dbFile.copy(backupPath);
        print("ImportBackup: saved backup to $backupPath");
      } catch (e) {
        return ImportBackupResponse(
          success: false,
          message: 'Failed to create backup: $e',
        );
      }
    }

    // Force close the pool entry so the file is not locked.
    DatabasePool.forceClose(dbName);

    // Write the new database file.
    try {
      await dbFile.writeAsBytes(request.data);
      print("ImportBackup: restored database from backup data");
      return ImportBackupResponse(
        success: true,
        message: 'Database restored successfully',
      );
    } catch (e) {
      // Try to restore from backup on write failure.
      return ImportBackupResponse(
        success: false,
        message: 'Failed to write database: $e',
      );
    }
  }

  @override
  Future<ExportCSVResponse> exportCSV(
      ServiceCall call, ExportCSVRequest request) async {
    final String dbName = _getDBName(call: call, dbName: request.dbName);
    final String dbPath = _getDBPath(dbName);

    print("ExportCSV called: dbName=$dbName, sql=${request.sql}");

    final pool = DatabasePool.get(dbName, dbPath);
    try {
      final results = await pool.query(request.sql);
      final csv = _mapListToCsv(results as List<Map<String, dynamic>>);
      return ExportCSVResponse(data: Uint8List.fromList(utf8.encode(csv)));
    } catch (e) {
      throw GrpcError.invalidArgument('CSV export error: $e');
    } finally {
      DatabasePool.close(dbName);
    }
  }

  // ==================== Helper methods ====================

  String _printParams(Iterable<Param> params) {
    return "[${params.map((p) {
      switch (p.whichValue()) {
        case Param_Value.stringValue: return "'${p.stringValue}'";
        case Param_Value.intValue: return p.intValue.toString();
        case Param_Value.doubleValue: return p.doubleValue.toString();
        case Param_Value.boolValue: return p.boolValue.toString();
        case Param_Value.bytesValue: return "BLOB(${p.bytesValue.length})";
        case Param_Value.notSet: return "null";
      }
    }).join(", ")}]";
  }

  /// Unpack a list of Param messages back to Dart Object? list.
  List<Object?> _unpackParams(Iterable<Param> params) {
    return params.map((param) {
      switch (param.whichValue()) {
        case Param_Value.stringValue:
          return param.stringValue;
        case Param_Value.intValue:
          return param.intValue.toInt();
        case Param_Value.doubleValue:
          return param.doubleValue;
        case Param_Value.boolValue:
          return param.boolValue;
        case Param_Value.bytesValue:
          return param.bytesValue;
        case Param_Value.notSet:
          return null;
      }
    }).toList();
  }

  /// Convert a list of Maps (from DatabaseCore.select) to a list of protobuf Rows.
  List<Row> _rowsFromMaps(List<Map<String, dynamic>> maps) {
    return maps.map((map) {
      final columns = map.entries.map((entry) {
        return Column(name: entry.key, value: _valueFromDart(entry.value));
      }).toList();
      return Row(columns: columns);
    }).toList();
  }

  /// Wrap a Dart value into a protobuf Value.
  Value _valueFromDart(Object? value) {
    if (value is int) return Value(intValue: Int64(value));
    if (value is String) return Value(stringValue: value);
    if (value is bool) return Value(boolValue: value);
    if (value is double) return Value(doubleValue: value);
    if (value is Uint8List) return Value(bytesValue: value);
    return Value();
  }

  @override
  Future<GetVersionResponse> getVersion(
      ServiceCall call, GetVersionRequest request) async {
    final String dbName = _getDBName(call: call, dbName: request.dbName);

    print("GetVersion called: dbName=$dbName");
    final pool = DatabasePool.get(dbName, _getDBPath(dbName));
    try {
      final version = await pool.getVersion();
      return GetVersionResponse(version: version);
    } finally {
      DatabasePool.close(dbName);
    }
  }

  @override
  Future<SetVersionResponse> setVersion(
      ServiceCall call, SetVersionRequest request) async {
    final String dbName = _getDBName(call: call, dbName: request.dbName);
    print("SetVersion called: dbName=$dbName, version=${request.version}");
    final pool = DatabasePool.get(dbName, _getDBPath(dbName));
    try {
      await pool.setVersion(request.version);
      return SetVersionResponse(success: true);
    } finally {
      DatabasePool.close(dbName);
    }
  }

  /// Echo method... used for testing
  @override
  Future<EchoResponse> echo(ServiceCall call, EchoRequest request) async {
    print("Echo called with message ${request.message}");
    return EchoResponse(message: request.message);
  }

  /// Execute [fn] with up to 3 retries and backoff for SQLITE_BUSY errors.
  ///
  /// Non-BUSY errors propagate immediately.  After all retries are exhausted
  /// a [GrpcError.unavailable] is thrown.
  Future<T> _runWithRetry<T>(Future<T> Function() fn,
      {int maxRetries = 3}) async {
    const backoffMs = [50, 100, 150];
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        return await fn();
      } catch (e) {
        final errorStr = e.toString();
        if (errorStr.contains('SQLITE_BUSY')) {
          if (attempt < maxRetries - 1) {
            await Future.delayed(Duration(milliseconds: backoffMs[attempt]));
            continue;
          }
          throw GrpcError.unavailable(
              'Database busy after $maxRetries attempts: $e');
        }
        // Non-BUSY error: propagate as-is.
        rethrow;
      }
    }
    throw GrpcError.unavailable('Database busy after $maxRetries attempts');
  }

  /// Convert a list of maps to CSV format with proper escaping.
  ///
  /// The first row contains column headers.
  String _mapListToCsv(List<Map<String, dynamic>> mapList) {
    if (mapList.isEmpty) return '';

    final buffer = StringBuffer();
    final keys = mapList.first.keys.toList();

    // Header row
    buffer.writeln(keys.map(_csvEscape).join(','));

    // Data rows
    for (final map in mapList) {
      buffer.writeln(keys.map((k) => _csvEscape(map[k])).join(','));
    }

    return buffer.toString();
  }

  /// Escape a value for CSV (handle null, commas, double quotes, newlines).
  String _csvEscape(dynamic value) {
    if (value == null) return '';
    final s = value.toString();
    // Must escape if contains comma, double-quote, or newline.
    if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }
}
