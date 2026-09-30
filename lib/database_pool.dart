import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_wrapper/sqlite_wrapper.dart';

/// Statically-allocated pool of SQLite connections with reference counting.
///
/// The pool ensures that a single [SQLiteWrapperCore] instance is reused for
/// all callers requesting the same [dbName].  Every [get] / [subscribe]
/// increments a reference counter; every [close] / [unsubscribe] decrements
/// it.  When the counter reaches zero the underlying connection is closed and
/// the entry is evicted, so that long-running watch subscriptions keep the
/// database alive even while no RPC handler holds a short-lived reference.
class DatabasePool {
  static final Map<String, _PoolEntry> _connections = {};

  /// Returns (or creates) a wrapper for [dbName], incrementing its refcount.
  static SQLiteWrapperCore get(
    String dbName,
    String dbPath, {
    int version = 0,
    OnCreate? onCreate,
    OnUpgrade? onUpgrade,
  }) {
    final entry = _entry(dbName, dbPath,
        version: version, onCreate: onCreate, onUpgrade: onUpgrade);
    entry.refCount++;
    return entry.wrapper;
  }

  /// Decrements the refcount for [dbName] and closes the connection when
  /// it reaches zero.
  static void close(String dbName) {
    final entry = _connections[dbName];
    if (entry == null) return;
    entry.refCount--;
    if (entry.refCount <= 0) {
      entry.wrapper.closeDB();
      _connections.remove(dbName);
    }
  }

  /// Subscribes to a watch query through the pool, incrementing the refcount.
  ///
  /// The returned stream mirrors [SQLiteWrapperBase.watch]; it emits the
  /// initial query result followed by incremental updates whenever any client
  /// executes a mutation on one of the watched [tables].
  static Stream subscribe({
    required String dbName,
    required String dbPath,
    required String sql,
    required List<Object?> params,
    required List<String> tables,
    required bool singleResult,
  }) {
    final entry = _entry(dbName, dbPath);
    entry.refCount++;
    return entry.wrapper.watch(sql,
        params: params, tables: tables, singleResult: singleResult);
  }

  /// Releases the watch subscription (decrements refcount).
  ///
  /// The underlying database connection is closed when the last subscriber
  /// or short-lived caller releases it.
  static void unsubscribe(String dbName) {
    close(dbName);
  }

  /// Forcefully closes the connection for [dbName] regardless of refcount.
  ///
  /// Used by ImportBackup after replacing the database file on disk.
  /// The next [get] call will reopen the new file.
  static void forceClose(String dbName) {
    final entry = _connections.remove(dbName);
    if (entry != null) {
      entry.wrapper.closeDB();
    }
  }

  /// Closes every tracked connection and clears the pool.
  ///
  /// Intended for graceful shutdown (SIGINT / SIGTERM).
  static void closeAll() {
    for (final entry in _connections.values) {
      entry.wrapper.closeDB();
    }
    _connections.clear();
  }

  /// Internal: returns the existing entry for [dbName] or creates a new one
  /// by opening the database at [dbPath].
  static _PoolEntry _entry(
    String dbName,
    String dbPath, {
    int version = 0,
    OnCreate? onCreate,
    OnUpgrade? onUpgrade,
  }) {
    return _connections.putIfAbsent(dbName, () {
      final wrapper = SQLiteWrapperCore();
      // `SQLiteWrapperCore.openDB` applies `version` by running
      // `PRAGMA user_version = version` whenever it differs from the value
      // stored in the file. Pooled connections are re-opened with the default
      // `version: 0`, which would reset the stored version to 0 on every new
      // connection (making `created` always true and forcing clients to
      // re-run their creation script on each launch). Read the current value
      // first and open with that when the caller did not provide one.
      final effectiveVersion =
          version != 0 ? version : readVersionFromFile(dbPath);
      wrapper.openDB(dbPath,
          version: effectiveVersion, onCreate: onCreate, onUpgrade: onUpgrade);
      // Enable WAL mode for concurrent reads during backups.
      wrapper.execute('PRAGMA journal_mode=WAL;');
      return _PoolEntry(wrapper);
    });
  }

  /// Reads the `user_version` currently stored in the database file.
  ///
  /// Returns 0 when the file does not exist yet, is an in-memory database or
  /// cannot be opened (the real open in `openDB` will surface the error).
  static int readVersionFromFile(String dbPath) {
    if (dbPath == inMemoryDatabasePath) return 0;
    if (!File(dbPath).existsSync()) return 0;
    Database? db;
    try {
      db = sqlite3.open(dbPath, mode: OpenMode.readWrite);
      final rows = db.select('PRAGMA user_version;');
      if (rows.isEmpty) return 0;
      final value = rows.first.columnAt(0);
      return value is int ? value : 0;
    } catch (e) {
      // Not a readable SQLite file: let the regular open report the error.
      print('DatabasePool: cannot read user_version from $dbPath: $e');
      return 0;
    } finally {
      db?.close();
    }
  }
}

class _PoolEntry {
  final SQLiteWrapperCore wrapper;
  int refCount = 0;
  _PoolEntry(this.wrapper);
}
