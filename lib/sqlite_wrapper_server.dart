import 'dart:async';
import 'dart:convert';

import 'package:grpc/grpc.dart';
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart';
import 'package:protobuf/well_known_types/google/protobuf/wrappers.pb.dart';
import 'package:sqlite_wrapper/sqlite_wrapper.dart';
import 'package:sqlite_wrapper_server/constants.dart';
import 'package:sqlite_wrapper_server/database_pool.dart';

/// Implementation of the SqliteService defined in the proto file.
class SQLiteWrapperServerImpl extends SqliteWrapperServiceBase {
  /// The DB Name is created appending to the dbName the user UUID.
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
    return "${dbName}_$uuid";
  }

  String _getDBPath(String dbName) {
    // Strip trailing slash from dbPath to avoid double-slash in the final path.
    String dbPath = Constants.dbPath;
    if (dbPath.endsWith('/')) {
      dbPath = dbPath.substring(0, dbPath.length - 1);
    }
    return "$dbPath/$dbName.sqlite";
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
    final sqliteVersion =
        await pool.query("PRAGMA sqlite_version", singleResult: true);

    // openDB is a warm-up call; decrement refcount so the pool can still
    // close cleanly.  The connection stays open because execute/select
    // and watch will call get/subscribe and re-increment.
    // (We keep the refCount bumped for the duration of this RPC only.)
    DatabasePool.close(dbName);

    return OpenDBResponse(
        created: version == 0,
        version: version,
        sqliteVersion: sqliteVersion as String,
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

  @override
  Future<SqlQueryResponse> execute(
      ServiceCall call, SqlQueryRequest request) async {
    final String dbName = _getDBName(call: call, dbName: request.dbName);
    print(
        "Execute called: sql=${request.sql}, params=${request.params}, dbName=$dbName");
    final pool = DatabasePool.get(dbName, _getDBPath(dbName));
    try {
      // Use tables from request so that updateStreams is triggered
      // on the correct tables (the wrapper's execute calls updateStreams).
      final res = await pool.execute(
        request.sql,
        params: _unpack(request.params.toList()),
        tables: request.tables,
      );
      return SqlQueryResponse(result: jsonEncode(res));
    } catch (e) {
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
        "Select called: sql=${request.sql}, params=${request.params}, dbName=$dbName");
    final pool = DatabasePool.get(dbName, _getDBPath(dbName));
    try {
      final db = pool.getDatabase();
      if (db == null) {
        throw GrpcError.failedPrecondition('Database not opened');
      }
      final res =
          db.select(request.sql, _unpack(request.params.toList()));
      return SqlQueryResponse(result: jsonEncode(res));
    } catch (e) {
      throw GrpcError.invalidArgument('SQL query error: $e');
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
      params: _unpack(request.params.toList()),
      tables: request.tables,
      singleResult: request.singleResult,
    );

    try {
      await for (final result in stream) {
        yield WatchResponse(
          json: jsonEncode(result),
          singleResult: request.singleResult,
        );
      }
    } finally {
      DatabasePool.unsubscribe(dbName);
    }
  }

  List<Object?> _unpack(List<Any> params) {
    return params.map((any) {
      if (any.typeUrl.endsWith('Int64Value')) {
        return any.unpackInto(Int64Value()).value.toInt();
      } else if (any.typeUrl.endsWith('StringValue')) {
        return any.unpackInto(StringValue()).value;
      } else if (any.typeUrl.endsWith('BoolValue')) {
        return any.unpackInto(BoolValue()).value;
      } else if (any.typeUrl.endsWith('DoubleValue')) {
        return any.unpackInto(DoubleValue()).value.toDouble();
      } else if (any.typeUrl == '') {
        return null;
      }
      throw ArgumentError('Unknown type: ${any.typeUrl}');
    }).toList();
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
}
