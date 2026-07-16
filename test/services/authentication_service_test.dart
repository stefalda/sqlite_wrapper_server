import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:sqlite_wrapper_server/constants.dart';
import 'package:sqlite_wrapper_server/services/authentication_service.dart';
import 'package:test/test.dart';

void main() {
  late AuthenticationService authService;

  setUp(() {
    Constants.secretKey = 'test_secret_key_for_jwt';
    authService = AuthenticationService();
  });

  group('generateToken', () {
    test('creates a valid token with userid and email', () {
      final token = authService.generateToken(
        email: 'user@example.com',
        userid: 'uuid-123',
      );

      expect(token, isNotEmpty);

      final jwt = authService.verifyToken(token);
      expect(jwt.payload['email'], 'user@example.com');
      expect(jwt.payload['userid'], 'uuid-123');
    });

    test('sets iat in seconds and exp at 24 hours', () {
      final token = authService.generateToken(
        email: 'user@example.com',
        userid: 'uuid-123',
      );

      final jwt = authService.verifyToken(token);
      final iat = jwt.payload['iat'] as int;
      final exp = jwt.payload['exp'] as int;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // iat should be close to current time (within 5 seconds)
      expect(iat, closeTo(now, 5));
      // exp should be ~24 hours after iat
      expect(exp - iat, 86400);
    });
  });

  group('verifyToken', () {
    test('accepts a valid token', () {
      final token = authService.generateToken(
        email: 'user@example.com',
        userid: 'uuid-123',
      );

      expect(() => authService.verifyToken(token), returnsNormally);
    });

    test('rejects a tampered token', () {
      final token = authService.generateToken(
        email: 'user@example.com',
        userid: 'uuid-123',
      );
      final tampered = '${token.substring(0, token.length - 5)}xxxxx';

      expect(() => authService.verifyToken(tampered), throwsException);
    });

    test('rejects an expired token', () {
      // Manually create an expired JWT
      final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 90000;
      final jwt = JWT({
        'userid': 'uuid-123',
        'email': 'user@example.com',
        'iat': past,
        'exp': past - 1, // already expired
      });
      final token = jwt.sign(SecretKey('test_secret_key_for_jwt'));

      expect(() => authService.verifyToken(token), throwsException);
    });
  });

  group('extractEmailFromJWT', () {
    test('returns the email from the token', () {
      final token = authService.generateToken(
        email: 'extract@example.com',
        userid: 'uuid-456',
      );
      final jwt = authService.verifyToken(token);

      final email = authService.extractEmailFromJWT(jwt);
      expect(email, 'extract@example.com');
    });
  });

  group('extractUserIdFromJWT', () {
    test('returns the userid from the token', () {
      final token = authService.generateToken(
        email: 'user@example.com',
        userid: 'uuid-789',
      );
      final jwt = authService.verifyToken(token);

      final userid = authService.extractUserIdFromJWT(jwt);
      expect(userid, 'uuid-789');
    });
  });
}
