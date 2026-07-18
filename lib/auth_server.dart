import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:grpc/grpc.dart';
import 'package:inject_x/inject_x.dart';
import 'package:sqlite_wrapper/generated/auth.pbgrpc.dart';
import 'package:sqlite_wrapper_server/constants.dart';
import 'package:sqlite_wrapper_server/services/authentication_service.dart';
import 'package:sqlite_wrapper_server/services/database_service.dart';

class AuthServiceImpl extends AuthServiceBase {
  final authenticationService = inject<AuthenticationService>();
  final databaseService = inject<DatabaseService>();

  @override
  Future<AuthResponse> register(
      ServiceCall call, RegisterRequest request) async {
    final dbName = Constants.usersDBName;
    try {
      final userid = await databaseService.insertUser(
          email: request.email, password: request.password, dbName: dbName);
      final token = authenticationService.generateToken(
          email: request.email, userid: userid);
      final refreshToken = authenticationService.generateRefreshToken();

      await databaseService.saveRefreshToken(
        token: refreshToken,
        userUuid: userid,
        email: request.email,
        dbName: dbName,
      );

      return AuthResponse()
        ..success = true
        ..message = 'Registration successful'
        ..token = token
        ..refreshToken = refreshToken;
    } catch (e) {
      return AuthResponse()
        ..success = false
        ..message = 'Invalid email or password';
    }
  }

  @override
  Future<AuthResponse> login(ServiceCall call, LoginRequest request) async {
    final dbName = Constants.usersDBName;
    final (correct, userid) = await databaseService.isLoginCorrect(
        email: request.email, password: request.password, dbName: dbName);
    if (!correct || userid == null) {
      return AuthResponse()
        ..success = false
        ..message = 'Invalid email or password';
    }

    final token = authenticationService.generateToken(
        email: request.email, userid: userid);
    final refreshToken = authenticationService.generateRefreshToken();

    await databaseService.saveRefreshToken(
      token: refreshToken,
      userUuid: userid,
      email: request.email,
      dbName: dbName,
    );

    return AuthResponse()
      ..success = true
      ..message = 'Login successful'
      ..token = token
      ..refreshToken = refreshToken;
  }

  @override
  Future<AuthResponse> refreshToken(
      ServiceCall call, RefreshTokenRequest request) async {
    final dbName = Constants.usersDBName;

    try {
      final row = await databaseService.getRefreshToken(
        token: request.refreshToken,
        dbName: dbName,
      );

      if (row == null) {
        return AuthResponse()
          ..success = false
          ..message = 'Invalid refresh token';
      }

      final expiresAt = row['expires_at'] as String?;
      if (expiresAt != null) {
        final exp = DateTime.tryParse(expiresAt);
        if (exp != null && exp.isBefore(DateTime.now())) {
          await databaseService.deleteRefreshToken(
            token: request.refreshToken,
            dbName: dbName,
          );
          return AuthResponse()
            ..success = false
            ..message = 'Refresh token expired';
        }
      }

      final userEmail = row['email'] as String;
      final userUuid = row['user_uuid'] as String;

      // Rotate: delete old refresh token, create new one
      await databaseService.deleteRefreshToken(
        token: request.refreshToken,
        dbName: dbName,
      );

      final newAccessToken = authenticationService.generateToken(
          email: userEmail, userid: userUuid);
      final newRefreshToken = authenticationService.generateRefreshToken();

      await databaseService.saveRefreshToken(
        token: newRefreshToken,
        userUuid: userUuid,
        email: userEmail,
        dbName: dbName,
      );

      return AuthResponse()
        ..success = true
        ..message = 'Token refreshed'
        ..token = newAccessToken
        ..refreshToken = newRefreshToken;
    } catch (e) {
      return AuthResponse()
        ..success = false
        ..message = 'Refresh failed';
    }
  }

  @override
  Future<ValidateTokenResponse> validateToken(
      ServiceCall call, ValidateTokenRequest request) async {
    try {
      JWT jwt = authenticationService.verifyToken(request.token);
      return ValidateTokenResponse()
        ..valid = true
        ..userid = jwt.payload['userid'] as String
        ..email = jwt.payload['email'] as String;
    } catch (e) {
      return ValidateTokenResponse()
        ..valid = false
        ..email = '';
    }
  }
}
