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
    // insertUser throws on duplicate email (UNIQUE constraint)
    // We catch the error and return a uniform message to prevent enumeration.
    try {
      final userid = await databaseService.insertUser(
          email: request.email, password: request.password, dbName: dbName);
      final token = authenticationService.generateToken(
          email: request.email, userid: userid);

      return AuthResponse()
        ..success = true
        ..message = 'Registration successful'
        ..token = token;
    } catch (e) {
      return AuthResponse()
        ..success = false
        ..message = 'Invalid email or password';
    }
  }

  /// Login uses the unified single-query isLoginCorrect which returns
  /// (correct, userId) in one round-trip.
  ///
  /// Both "user not found" and "wrong password" produce the same message
  /// to prevent email enumeration (R7).
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

    return AuthResponse()
      ..success = true
      ..message = 'Login successful'
      ..token = token;
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
