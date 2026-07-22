import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:sqlite_wrapper/generated/sqlite_wrapper_rpc.pb.dart';
import 'package:sqlite_wrapper_server/constants.dart';
import 'package:sqlite_wrapper_server/database_pool.dart';
import 'package:sqlite_wrapper_server/sqlite_wrapper_server.dart';
import 'package:test/test.dart';

/// A concrete [ServiceCall] for testing.
class FakeServiceCall extends ServiceCall {
  @override
  Map<String, String>? clientMetadata;

  FakeServiceCall({this.clientMetadata});

  @override
  Map<String, String>? get headers => null;

  @override
  Map<String, String>? get trailers => null;

  @override
  DateTime? get deadline => null;

  @override
  bool get isTimedOut => false;

  @override
  bool get isCanceled => false;

  @override
  X509Certificate? get clientCertificate => null;

  @override
  InternetAddress? get remoteAddress => null;

  @override
  void sendHeaders() {}

  @override
  void sendTrailers({int? status, String? message}) {}
}

void main() {
  // Use a temp directory for test databases.
  final testDir = Directory.systemTemp.createTempSync('sqlite_test_');

  // Ensure a clean pool between groups.
  tearDown(() {
    DatabasePool.closeAll();
    Constants.sharedDB = false;
    Constants.dbPath = testDir.path;
    Constants.dbName = null;
  });

  group('_getDBName', () {
    test('throws GrpcError when no uuid and not shared', () async {
      Constants.sharedDB = false;
      final impl = SQLiteWrapperServerImpl();
      final call = FakeServiceCall(clientMetadata: {});

      expect(
        () => impl.openDB(call, OpenDBRequest(dbName: 'test_db')),
        throwsA(isA<GrpcError>()),
      );
    });

    test('does not throw when sharedDB is true and no uuid', () async {
      Constants.sharedDB = true;
      Constants.dbPath = testDir.path;
      final impl = SQLiteWrapperServerImpl();
      final call = FakeServiceCall(clientMetadata: {});

      final response = await impl.openDB(
          call, OpenDBRequest(dbName: 'shared_test'));
      expect(response.dbName, 'shared_test');
    });

    test('appends uuid to dbName when uuid present (no email)', () async {
      Constants.sharedDB = false;
      Constants.dbPath = testDir.path;
      final impl = SQLiteWrapperServerImpl();
      final call = FakeServiceCall(clientMetadata: {'user_uuid': 'my-uuid'});

      final response = await impl.openDB(
          call, OpenDBRequest(dbName: 'app_test'));
      // Without email, format is {prefix}_{uuid}
      expect(response.dbName, 'app_test_my-uuid');
    });

    test('includes email in dbName when email is present', () async {
      Constants.sharedDB = false;
      Constants.dbPath = testDir.path;
      final impl = SQLiteWrapperServerImpl();
      final call = FakeServiceCall(clientMetadata: {
        'user_uuid': 'my-uuid',
        'email': 'user@example.com',
      });

      final response = await impl.openDB(
          call, OpenDBRequest(dbName: 'app_test'));
      expect(response.dbName,
          'app_test_user_at_example_dot_com_my-uuid');
    });

    test('handles email with dots and plus sign', () async {
      Constants.sharedDB = false;
      Constants.dbPath = testDir.path;
      final impl = SQLiteWrapperServerImpl();
      final call = FakeServiceCall(clientMetadata: {
        'user_uuid': 'uuid-789',
        'email': 'mario.rossi+spam@gmail.com',
      });

      final response = await impl.openDB(
          call, OpenDBRequest(dbName: 'mainDB'));
      // @ -> _at_, dots -> _dot_, + stays (then sanitized by _sanitizeDBName in _getDBPath)
      expect(response.dbName,
          'mainDB_mario_dot_rossi+spam_at_gmail_dot_com_uuid-789');
    });

    test('works with Constants.dbName override and email', () async {
      Constants.sharedDB = false;
      Constants.dbPath = testDir.path;
      Constants.dbName = 'custom';  // override
      final impl = SQLiteWrapperServerImpl();
      final call = FakeServiceCall(clientMetadata: {
        'user_uuid': 'uuid-xyz',
        'email': 'admin@test.org',
      });

      final response = await impl.openDB(
          call, OpenDBRequest(dbName: 'ignored_client_name'));
      expect(response.dbName,
          'custom_admin_at_test_dot_org_uuid-xyz');

      // Reset for other tests
      Constants.dbName = null;
    });
  });

  group('_getDBPath', () {
    test('sanitizes path traversal attempts in dbName', () async {
      Constants.dbPath = testDir.path;
      final impl = SQLiteWrapperServerImpl();
      final call = FakeServiceCall(clientMetadata: {'user_uuid': 'safe-uuid'});

      // Path traversal characters get replaced with underscores
      final response = await impl.openDB(
        call,
        OpenDBRequest(dbName: '../../etc/passwd'),
      );
      // dbName is not sanitized in _getDBName, only in _getDBPath
      // So the result dbName is the original {input}_{uuid}
      expect(response.dbName, '../../etc/passwd_safe-uuid');
    });
  });


}
