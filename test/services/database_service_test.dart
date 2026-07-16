import 'package:inject_x/inject_x.dart';
import 'package:sqlite_wrapper/sqlite_wrapper.dart';
import 'package:sqlite_wrapper_server/services/database_service.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseService databaseService;
  late SQLiteWrapperBase db;

  setUp(() async {
    InjectX.clear();
    db = SQLiteWrapperCore();
    InjectX.add<SQLiteWrapperBase>(db);
    databaseService = DatabaseService();

    // Open the users database in memory.
    // openDatabase builds a path like "path/name.sqlite".
    // When path=':memory:', we must open the DB directly so the path equals ':memory:'.
    await db.openDB(':memory:',
        onCreate: () async {
          final sql = """CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY DEFAULT (hex(randomblob(16))),
            email TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            salt TEXT NOT NULL,
            hash_algorithm TEXT DEFAULT 'sha256',
            created_at DATETIME DEFAULT current_timestamp
          );
          CREATE INDEX IF NOT EXISTS idx_email ON users(email);
          """;
          await db.execute(sql, dbName: 'test_users');
        },
        dbName: 'test_users');

    // Insert test user with legacy SHA-256 hash
    await db.execute(
      '''INSERT INTO users (id, email, password_hash, salt, hash_algorithm)
       VALUES (?, ?, ?, ?, ?)''',
      params: [
        'test-uuid-123',
        'test@example.com',
        'legacy_sha256_hash',
        'test_salt',
        'sha256',
      ],
      dbName: 'test_users',
    );
  });

  group('emailAlreadyRegistered', () {
    test('returns true for existing email', () async {
      final result = await databaseService.emailAlreadyRegistered(
        'test@example.com',
        dbName: 'test_users',
      );
      expect(result, isTrue);
    });

    test('returns false for non-existing email', () async {
      final result = await databaseService.emailAlreadyRegistered(
        'nonexistent@example.com',
        dbName: 'test_users',
      );
      expect(result, isFalse);
    });
  });

  group('insertUser', () {
    test('inserts a new user and returns the UUID', () async {
      final uuid = await databaseService.insertUser(
        email: 'newuser@example.com',
        password: 'securePassword123',
        dbName: 'test_users',
      );

      expect(uuid, isNotEmpty);

      // Verify the user was inserted with Argon2id
      final result = await db.query(
        'SELECT hash_algorithm FROM users WHERE id = ?',
        params: [uuid],
        singleResult: true,
        dbName: 'test_users',
      );
      expect(result, 'argon2id');
    });

    test('throws on duplicate email', () async {
      await expectLater(
        databaseService.insertUser(
          email: 'test@example.com',
          password: 'anotherPassword',
          dbName: 'test_users',
        ),
        throwsException,
      );
    });
  });

  group('isLoginCorrect', () {
    test('returns (false, null) for non-existing email', () async {
      final (correct, userId) = await databaseService.isLoginCorrect(
        email: 'unknown@example.com',
        password: 'anyPassword',
        dbName: 'test_users',
      );
      expect(correct, isFalse);
      expect(userId, isNull);
    });

    test('returns (false, null) for wrong password with SHA-256 user',
        () async {
      final (correct, userId) = await databaseService.isLoginCorrect(
        email: 'test@example.com',
        password: 'wrongPassword',
        dbName: 'test_users',
      );
      expect(correct, isFalse);
      expect(userId, isNull);
    });
  });
}
