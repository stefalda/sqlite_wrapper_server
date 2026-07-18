import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:sqlite_wrapper_server/constants.dart';
import 'package:uuid/uuid.dart';

class AuthenticationService {
  final String _jwtSecret = Constants.secretKey;

  JWT verifyToken(String token) {
    return JWT.verify(token, SecretKey(_jwtSecret));
  }

  /// Return the email in the verified JWT
  String extractEmailFromJWT(JWT jwt) {
    return jwt.payload['email'] as String;
  }

  String extractUserIdFromJWT(JWT jwt) {
    return jwt.payload['userid'] as String;
  }

  /// Generate the token and return to user.
  ///
  /// Uses Unix timestamps (seconds) for `iat` and adds `exp` at 24 hours.
  String generateToken({required String email, required String userid}) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final jwt = JWT(
      {
        'userid': userid,
        'email': email,
        'iat': now,
        'exp': now + 86400,
      },
    );
    return jwt.sign(SecretKey(_jwtSecret));
  }

  /// Generate a cryptographically random refresh token (opaque string).
  /// Refresh tokens are stored server-side and do not use JWT.
  String generateRefreshToken() {
    return Uuid().v4();
  }
}
