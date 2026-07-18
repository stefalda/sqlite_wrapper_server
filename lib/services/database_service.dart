import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:inject_x/inject_x.dart';
import 'package:sqlite_wrapper/sqlite_wrapper.dart';
import 'package:uuid/uuid.dart';

/// Argon2id instance for password hashing (OWASP recommended baseline).
///
/// memory: 19 MiB = 19456 x 1kB blocks
/// iterations: 2
/// parallelism: 1
/// hashLength: 32 bytes
final _argon2 = Argon2id(
  parallelism: 1,
  memory: 19456,
  iterations: 2,
  hashLength: 32,
);

class DatabaseService {
  /// Open or create the users database
  Future<void> openDatabase(
      {required String path, required String name}) async {
    if (!path.endsWith("/")) {
      path = "$path/";
    }
    inject<SQLiteWrapperBase>().openDB("$path$name.sqlite", onCreate: () async {
      final sql = """CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY DEFAULT (hex(randomblob(16))),
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      salt TEXT NOT NULL,
      hash_algorithm TEXT DEFAULT 'sha256',
      created_at DATETIME DEFAULT current_timestamp
      );

      CREATE INDEX IF NOT EXISTS idx_email ON users(email);

      CREATE TABLE IF NOT EXISTS refresh_tokens (
        token TEXT PRIMARY KEY,
        user_uuid TEXT NOT NULL,
        email TEXT NOT NULL,
        expires_at DATETIME NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );

      CREATE INDEX IF NOT EXISTS idx_refresh_token_email ON refresh_tokens(email);
      """;
      await inject<SQLiteWrapperBase>().execute(sql, dbName: name);
    }, dbName: name);
  }

  /// Check if the user email is already registered
  Future<bool> emailAlreadyRegistered(String email,
      {required String dbName}) async {
    final sql = "SELECT count(*) FROM users WHERE email = ?";
    int count = await inject<SQLiteWrapperBase>()
        .query(sql, params: [email], singleResult: true, dbName: dbName);
    return count > 0;
  }

  /// Insert a new user and return the generated UUID.
  Future<String> insertUser({
    required String email,
    required String password,
    required String dbName,
  }) async {
    // Generate a random salt
    final salt = Uuid().v4();

    // Hash the password with Argon2id using the salt as nonce
    final digest = await _argon2idHash(password, salt);

    // Prepare the SQL statement with placeholders
    const sqlInsertUser =
        'INSERT INTO users (id, email, password_hash, salt, hash_algorithm) VALUES (?, ?, ?, ?, ?);';

    // Use a UUID v7 for the ID
    final id = Uuid().v7();

    try {
      await inject<SQLiteWrapperBase>().execute(
        sqlInsertUser,
        params: [
          id,
          email,
          digest,
          salt,
          'argon2id',
        ],
        dbName: dbName,
      );
    } catch (e) {
      // UNIQUE constraint violation → rethrow as alreadyExists
      rethrow;
    }
    return id;
  }

  /// Verify login credentials and return (success, userId).
  ///
  /// Supports legacy SHA-256 hashes and migrates them to Argon2id on
  /// successful verification.
  Future<(bool, String?)> isLoginCorrect({
    required String email,
    required String password,
    required String dbName,
  }) async {
    const sql = 'SELECT id, salt, password_hash, hash_algorithm FROM users WHERE email = ?';
    final res = await inject<SQLiteWrapperBase>()
        .query(sql, params: [email], singleResult: true, dbName: dbName);
    if (res == null) return (false, null);

    final storedHash = res['password_hash'] as String;
    final salt = res['salt'] as String;
    final hashAlgo = res['hash_algorithm'] as String? ?? 'sha256';
    final userId = res['id'] as String;

    if (hashAlgo == 'sha256') {
      // Legacy SHA-256 verification
      final incomingDigest = _sha256Digest(salt, password);
      if (!_secureCompare(storedHash, incomingDigest)) {
        return (false, null);
      }
      // Migrate to Argon2id on successful login
      final newHash = await _argon2idHash(password, salt);
      await inject<SQLiteWrapperBase>().execute(
        'UPDATE users SET password_hash = ?, hash_algorithm = ? WHERE id = ?',
        params: [newHash, 'argon2id', userId],
        dbName: dbName,
      );
      return (true, userId);
    }

    // Argon2id verification
    final match = await _argon2idVerify(password, salt, storedHash);
    return (match, match ? userId : null);
  }

  /// Hash a password with Argon2id using [salt] as nonce.
  /// Returns the hex-encoded hash.
  Future<String> _argon2idHash(String password, String salt) async {
    final secretKey = SecretKey(utf8.encode(password));
    final nonce = utf8.encode(salt);
    final derivedKey = await _argon2.deriveKey(
      secretKey: secretKey,
      nonce: nonce,
    );
    final bytes = await derivedKey.extractBytes();
    return base64Encode(bytes);
  }

  /// Verify a password against a stored Argon2id hash.
  Future<bool> _argon2idVerify(
      String password, String salt, String storedHash) async {
    final secretKey = SecretKey(utf8.encode(password));
    final nonce = utf8.encode(salt);
    final derivedKey = await _argon2.deriveKey(
      secretKey: secretKey,
      nonce: nonce,
    );
    final bytes = await derivedKey.extractBytes();
    final computedHash = base64Encode(bytes);
    return _secureCompare(storedHash, computedHash);
  }

  /// Legacy SHA-256 digest used during migration.
  String _sha256Digest(String salt, String password) {
    final combinedPassword = '$salt$password';
    final bytes = utf8.encode(combinedPassword);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // Constant-time string comparison to prevent timing attacks
  bool _secureCompare(String a, String b) {
    if (a.length != b.length) {
      return false;
    }

    var result = 0;

    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }

    return result == 0;
  }

  Future<void> closeDatabaseConnection() async {
    for (String dbName in inject<SQLiteWrapperBase>().getDatabases().getNames()) {
      inject<SQLiteWrapperBase>().closeDB(dbName: dbName);
    }
  }

  /// Return userId from email
  Future<String> getUserId(
      {required String email, required String dbName}) async {
    final sql = "SELECT id FROM users WHERE email = ?";
    return await inject<SQLiteWrapperBase>()
        .query(sql, params: [email], singleResult: true, dbName: dbName);
  }

  /// Save a refresh token for the user with a 30-day expiration.
  Future<void> saveRefreshToken({
    required String token,
    required String userUuid,
    required String email,
    required String dbName,
  }) async {
    final expiresAt = DateTime.now().add(const Duration(days: 30)).toIso8601String();
    const sql = '''INSERT OR REPLACE INTO refresh_tokens (token, user_uuid, email, expires_at)
                    VALUES (?, ?, ?, ?)''';
    await inject<SQLiteWrapperBase>().execute(
      sql,
      params: [token, userUuid, email, expiresAt],
      dbName: dbName,
    );
  }

  /// Retrieve a refresh token row, or null if not found.
  Future<Map<String, dynamic>?> getRefreshToken({
    required String token,
    required String dbName,
  }) async {
    const sql = 'SELECT token, user_uuid, email, expires_at FROM refresh_tokens WHERE token = ?';
    return await inject<SQLiteWrapperBase>().query(
      sql,
      params: [token],
      singleResult: true,
      dbName: dbName,
    );
  }

  /// Delete a refresh token (used during rotation or expiry).
  Future<void> deleteRefreshToken({
    required String token,
    required String dbName,
  }) async {
    const sql = 'DELETE FROM refresh_tokens WHERE token = ?';
    await inject<SQLiteWrapperBase>().execute(sql, params: [token], dbName: dbName);
  }
}
