import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:inject_x/inject_x.dart';
import 'package:sqlite_wrapper/generated/auth.pbgrpc.dart';
import 'package:sqlite_wrapper/sqlite_wrapper.dart';
import 'package:sqlite_wrapper_server/auth_interceptor.dart';
import 'package:sqlite_wrapper_server/auth_server.dart';
import 'package:sqlite_wrapper_server/constants.dart';
import 'package:sqlite_wrapper_server/database_pool.dart';
import 'package:sqlite_wrapper_server/services/authentication_service.dart';
import 'package:sqlite_wrapper_server/services/database_service.dart';
import 'package:sqlite_wrapper_server/sqlite_wrapper_server.dart';
import 'package:test/test.dart';

void main() {
  late Server server;
  late ClientChannel channel;
  late AuthServiceClient authClient;
  late SqliteWrapperServiceClient sqliteClient;
  late Directory testDir;

  setUp(() async {
    InjectX.clear();
    testDir = Directory.systemTemp.createTempSync('grpc_int_test_');

    // Configure constants
    Constants.secretKey = 'integration_test_secret';
    Constants.sharedDB = true; // Use shared DB for simplicity
    Constants.dbPath = testDir.path;
    Constants.usersDBName = 'integration_users';
    Constants.usersDBPath = testDir.path;
    Constants.serverPort = 0;

    SQLiteWrapperServerImpl.runUnauthenticated = false;

    // Set up services
    InjectX.add<SQLiteWrapperBase>(SQLiteWrapperCore());
    InjectX.add(DatabaseService());
    InjectX.add(AuthenticationService());

    final databaseService = inject<DatabaseService>();

    // Create the users database
    await databaseService.openDatabase(
      path: testDir.path,
      name: 'integration_users',
    );

    // Start the in-process server
    server = Server.create(
      services: [SQLiteWrapperServerImpl(), AuthServiceImpl()],
      interceptors: [authInterceptor],
    );
    await server.serve(port: 0);

    final port = server.port;
    if (port == null) {
      throw StateError('Server failed to bind to a port');
    }

    channel = ClientChannel(
      'localhost',
      port: port,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );

    authClient = AuthServiceClient(channel);
    sqliteClient = SqliteWrapperServiceClient(channel);
  });

  tearDown(() async {
    await channel.shutdown();
    await server.shutdown();
    DatabasePool.closeAll();
    testDir.deleteSync(recursive: true);
  });

  group('Echo', () {
    test('returns the same message', () async {
      final response = await sqliteClient.echo(EchoRequest(message: 'hello'));
      expect(response.message, 'hello');
    });
  });

  group('Register and Login', () {
    test('full registration and login flow', () async {
      final registerResponse = await authClient.register(RegisterRequest(
        email: 'integration@test.com',
        password: 'StrongP@ss1',
      ));
      expect(registerResponse.success, isTrue);
      expect(registerResponse.errorCode, 0);
      expect(registerResponse.message, 'Registration successful');
      expect(registerResponse.token, isNotEmpty);

      final loginResponse = await authClient.login(LoginRequest(
        email: 'integration@test.com',
        password: 'StrongP@ss1',
      ));
      expect(loginResponse.success, isTrue);
      expect(loginResponse.errorCode, 0);
      expect(loginResponse.message, 'Login successful');
      expect(loginResponse.token, isNotEmpty);
    });

    test('register with duplicate email returns failure', () async {
      await authClient.register(RegisterRequest(
        email: 'dup@test.com',
        password: 'Password1',
      ));
      final response = await authClient.register(RegisterRequest(
        email: 'dup@test.com',
        password: 'Password1',
      ));
      expect(response.success, isFalse);
      expect(response.errorCode, 3);
      expect(response.message, 'Invalid email or password');
    });

    test('login with wrong password returns failure', () async {
      await authClient.register(RegisterRequest(
        email: 'wrongpw@test.com',
        password: 'CorrectPw1',
      ));
      final response = await authClient.login(LoginRequest(
        email: 'wrongpw@test.com',
        password: 'WrongPw1',
      ));
      expect(response.success, isFalse);
      expect(response.errorCode, 2);
      expect(response.message, 'Invalid email or password');
    });

    test('login with non-existent email returns failure', () async {
      final response = await authClient.login(LoginRequest(
        email: 'nobody@test.com',
        password: 'anyPass1',
      ));
      expect(response.success, isFalse);
      expect(response.errorCode, 1);
      expect(response.message, 'Invalid email or password');
    });
  });
}
