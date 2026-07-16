import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:inject_x/inject_x.dart';
import 'package:sqlite_wrapper_server/auth_interceptor.dart';
import 'package:sqlite_wrapper_server/constants.dart';
import 'package:sqlite_wrapper_server/services/authentication_service.dart';
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

/// A stub [ServiceMethod] for testing the interceptor.
ServiceMethod _stubMethod(String name) {
  Object? deserializer(List<int> data) => null;
  List<int> serializer(Object? response) => [];
  return ServiceMethod<Object?, Object?>(
    name,
    (call, request) async => null,
    false,
    false,
    deserializer,
    serializer,
  );
}

void main() {
  setUp(() {
    InjectX.clear();
    Constants.secretKey = 'test_secret_for_auth';
    InjectX.add(AuthenticationService());
    SQLiteWrapperServerImpl.runUnauthenticated = false;
  });

  group('authInterceptor', () {
    test('allows public paths without token', () async {
      final call = FakeServiceCall(
        clientMetadata: {':path': '/auth.AuthService/Register'},
      );
      final result = await authInterceptor(call, _stubMethod('Register'));
      expect(result, isNull);
    });

    test('allows Echo path without token', () async {
      final call = FakeServiceCall(
        clientMetadata: {':path': '/sqlite_wrapper.SqliteWrapperService/Echo'},
      );
      final result = await authInterceptor(call, _stubMethod('Echo'));
      expect(result, isNull);
    });

    test('allows when runUnauthenticated is true', () async {
      SQLiteWrapperServerImpl.runUnauthenticated = true;
      final call = FakeServiceCall(
        clientMetadata: {':path': '/some.protected/Path'},
      );
      final result = await authInterceptor(call, _stubMethod('Path'));
      expect(result, isNull);
    });

    test('rejects requests without token on protected path', () async {
      final call = FakeServiceCall(
        clientMetadata: {':path': '/some.protected/Path'},
      );
      final result = await authInterceptor(call, _stubMethod('Path'));
      expect(result, isA<GrpcError>());
      expect(result!.code, 16); // unauthenticated
    });

    test('accepts valid token on protected path', () async {
      final authService = inject<AuthenticationService>();
      final token = authService.generateToken(
        email: 'test@example.com',
        userid: 'uuid-123',
      );

      final call = FakeServiceCall(
        clientMetadata: {
          ':path': '/some.protected/Path',
          'token': token,
        },
      );
      final result = await authInterceptor(call, _stubMethod('Path'));
      expect(result, isNull);
      expect(call.clientMetadata!['email'], 'test@example.com');
      expect(call.clientMetadata!['user_uuid'], 'uuid-123');
    });

    test('rejects invalid token on protected path', () async {
      final call = FakeServiceCall(
        clientMetadata: {
          ':path': '/some.protected/Path',
          'token': 'invalid-token-value',
        },
      );
      final result = await authInterceptor(call, _stubMethod('Path'));
      expect(result, isA<GrpcError>());
    });
  });
}
