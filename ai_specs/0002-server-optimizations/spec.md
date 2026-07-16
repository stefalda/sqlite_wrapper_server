---
type: Spec
title: Server Optimizations — Security, Performance, Maintainability
---

## Coding Conventions

Le seguenti indicazioni si applicano a TUTTI i requisiti di questa specifica:

1. **Commenti:** Non rimuovere commenti esistenti a meno che non siano
   diventati errati o fuorvianti. Aggiungere commenti esplicativi nei punti
   di codice più complessi (retry logic, reference counting, migrazione
   Argon2, mapping `query()` result).
2. **Documentazione:** Aggiornare `README.md` per riflettere le modifiche
   (nuova dipendenza `cryptography_plus`, JWT con expiry, connection
   pooling).

## Problem

The `sqlite_wrapper_server` has accumulated technical debt across ten areas
that affect security, performance, and maintainability. The most severe issues
are:

1. **Connection churn**: Every RPC (`execute`, `select`, `getVersion`,
   `setVersion`) opens a new SQLite connection and immediately closes it.
   With N concurrent requests, N file descriptors are opened and closed
   per second. [L1]
2. **Weak password hashing**: SHA-256 is a general-purpose fast hash,
   vulnerable to brute-force and rainbow table attacks. [L2]
3. **JWT token defects**: `iat` is in milliseconds (violates RFC 7519 §2),
   tokens never expire, and a race condition at startup lets unauthenticated
   requests through when `runUnauthenticated` is enabled. [L3]
4. **Redundant SQL queries**: `register` and `login` each issue 3 queries
   when 1 suffices. An existing bug treats `query()` `Map` return as a
   `List` via integer index access, causing a runtime crash. [L4]
5. **Path traversal risk**: `_getDBPath` interpolates `dbName` directly
   into a filesystem path. `_getDBName` throws a raw `String` (not
   `GrpcError`) when the user UUID is null. [L5]
6. **Silent error swallowing**: Exceptions from `sqliteWrapper.execute()`
   propagate as opaque `GrpcError.internal` without details. [L6]
7. **User enumeration via login**: Distinct "User not found" vs "Invalid
   password" messages allow email enumeration through timing. [L7]
8. **Redundant dependencies**: `sqlite3` and `fixnum` are listed in
   `pubspec.yaml` but never imported directly. [L8]
9. **Zero test coverage**: The `test/` directory is empty. [L4]
10. **Dead code**: `static List<StreamInfo> streams` and
    `lib/stream_info.dart` are unused. [L9]

## Proposed Outcome

A hardened server with connection pooling, Argon2id password hashing,
RFC-compliant JWTs, optimized database queries, path sanitization,
structured error handling, uniform login responses, clean dependencies,
baseline test coverage, and removal of dead code.

## User Stories

1. As a server operator, I want connection pooling so that the server
   handles concurrent requests without file descriptor churn. [L1]
2. As a user, I want my password hashed with Argon2id so that a database
   breach does not expose plaintext passwords. [L2]
3. As a user, I want my JWT session to expire after 24h so that a stolen
   token has limited window of use. [L3]
4. As a developer, I want register/login to use 1 query each so that
   authentication latency is minimized. [L4]
5. As a server operator, I want path traversal prevented so that users
   cannot read/write arbitrary files on the server. [L5]
6. As a developer debugging SQL issues, I want the server to return
   clear error messages instead of opaque 500s. [L6]
7. As a server operator, I want login messages to be uniform so that
   attackers cannot enumerate valid emails. [L7]
8. As a maintainer, I want `pubspec.yaml` to list only direct imports
   so that dependency audit tools report accurately. [L8]
9. As a developer, I want unit test coverage for the core services so
   that regressions are caught before deployment.
10. As a maintainer, I want dead code removed so that the codebase is
   easier to navigate. [L9]

## Requirements

### R1 — Connection Pool

**File:** `lib/database_pool.dart` (nuovo)

Pool di connessioni SQLite con reference counting. [L1]

```dart
class DatabasePool {
  static final Map<String, _PoolEntry> _connections = {};

  static SQLiteWrapperCore get(String dbName, String dbPath) {
    final entry = _entry(dbName, dbPath);
    entry.refCount++;
    return entry.wrapper;
  }

  static void close(String dbName) {
    final entry = _connections[dbName];
    if (entry == null) return;
    entry.refCount--;
    if (entry.refCount <= 0) {
      entry.wrapper.closeDB();
      _connections.remove(dbName);
    }
  }

  static void closeAll() {
    for (final entry in _connections.values) {
      entry.wrapper.closeDB();
    }
    _connections.clear();
  }

  static _PoolEntry _entry(
    String dbName,
    String dbPath, {
    int version = 0,
    OnCreate? onCreate,
    OnUpgrade? onUpgrade,
  }) {
    return _connections.putIfAbsent(dbName, () {
      final wrapper = SQLiteWrapperCore();
      wrapper.openDB(dbPath,
          version: version, onCreate: onCreate, onUpgrade: onUpgrade);
      return _PoolEntry(wrapper);
    });
  }
}

class _PoolEntry {
  final SQLiteWrapperCore wrapper;
  int refCount = 0;
  _PoolEntry(this.wrapper);
}
```

RPC da migrare al pool: `execute`, `select`, `openDB`, `closeDB`,
`getVersion`, `setVersion`. Ogni RPC chiama `DatabasePool.get(dbName, dbPath)`
invece di aprire/chiudere la connessione manualmente.

> **Nota:** Il design esteso del pool con supporto watch è definito in
> `0001-grpc-watch-streaming`. Questa implementazione base è sufficiente
> per gli usi non-watch.

**Retry `SQLITE_BUSY`:** Applicare 3 tentativi con backoff 50/100/150ms in
`SQLiteWrapperServerImpl.execute()`. Fallimento → `GrpcError.unavailable`.

**Dipendenza:** R6 (Error Handling) dipende da R1. Implementare R6 solo
dopo R1. Il codice di R6 usa `DatabasePool.get()` definito qui.

### R2 — Argon2id Password Hashing

**File:** `lib/services/database_service.dart`

Sostituire SHA-256 con Argon2id tramite `cryptography_plus`. [L2]

```dart
import 'package:cryptography_plus/cryptography_plus.dart';

const _argon2 = Argon2id(
  parallelism: 1,
  memory: 19456,
  iterations: 2,
  hashLength: 32,
);
```

**Migrazione dati esistenti:**

1. Aggiungere colonna `hash_algorithm TEXT DEFAULT 'sha256'` alla tabella
   `users`
2. Al login:
   - Se `hash_algorithm == 'sha256'`: verificare con SHA-256 legacy,
     poi rigenerare hash con Argon2id e aggiornare la riga
   - Se `hash_algorithm == 'argon2id'`: verificare direttamente con Argon2id
3. Se SHA-256 fallisce e la riga non è migrata → login negato (password
   errata)

**Dipende da:** `pub get cryptography_plus: ^3.0.0`

### R3 — JWT Fixes

**File:** `lib/services/authentication_service.dart`, `bin/main.dart`

Tre fix distinti, in questo ordine: [L3]

**(a) `iat` in secondi, aggiungere `exp` (24h):**

```dart
final jwt = JWT({
  'userid': userid,
  'email': email,
  'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
});
```

**(b) Typo `runUnathenticated` (fare prima):** Rinominare in `runUnauthenticated`
in tutti i file (`lib/constants.dart:15`, `lib/sqlite_wrapper_server.dart:36`,
`lib/main.dart:30,32`). Aggiungere alias `@Deprecated`:

```dart
@Deprecated('Use runUnauthenticated instead')
static bool get runUnathenticated => runUnauthenticated;
```

**(c) Race condition all'avvio (dopo rename):** Spostare
`SQLiteWrapperServerImpl.runUnauthenticated` PRIMA di `server.serve()`.
Dopo il rename (b), sia il campo statico che la costante usano il nuovo nome:

```dart
SQLiteWrapperServerImpl.runUnauthenticated = Constants.runUnauthenticated;
await server.serve(port: port);
```

### R4 — Query Duplicate Elimination

**File:** `lib/services/database_service.dart`

Due cambiamenti: [L4]

**(a) `insertUser` restituisce l'UUID generato:**

```dart
Future<String> insertUser({
  required String email,
  required String password,
  required String dbName,
}) async {
  final id = Uuid().v7();
  // ... insert ...
  return id;
}
```

**(b) `isLoginCorrect` restituisce userId + usa chiavi nominali:**

```dart
Future<(bool, String?)> isLoginCorrect({
  required String email,
  required String password,
  required String dbName,
}) async {
  final sql = 'SELECT id, salt, password_hash FROM users WHERE email = ?';
  final res = await inject<SQLiteWrapperBase>().query(
    sql, params: [email], singleResult: true, dbName: dbName,
  );
  if (res == null) return (false, null);
  final match = _secureCompare(
    res['password_hash'] as String,
    _getDigestValue(res['salt'] as String, password),
  );
  return (match, match ? res['id'] as String : null);
}
```

**`register()` aggiornato** — chiama `insertUser` (che restituisce UUID)
invece di fare 3 query:

```dart
@override
Future<AuthResponse> register(ServiceCall call, RegisterRequest request) async {
  final dbName = Constants.usersDBName;
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
    // insertUser fallisce se email duplicata (UNIQUE constraint)
    return AuthResponse()
      ..success = false
      ..message = 'Invalid email or password';  // [L7]
  }
}
```

> `insertUser` lancia `GrpcError.alreadyExists` se l'email è già registrata
> (UNIQUE constraint violato). Il catch trasforma in risposta uniforme.

**`login()` aggiornato** — usa `isLoginCorrect` che restituisce `(bool, String?)`
invece di fare 3 query:

```dart
@override
Future<AuthResponse> login(ServiceCall call, LoginRequest request) async {
  final dbName = Constants.usersDBName;
  final (correct, userid) = await databaseService.isLoginCorrect(
    email: request.email, password: request.password, dbName: dbName);
  if (!correct || userid == null) {
    return AuthResponse()
      ..success = false
      ..message = 'Invalid email or password';  // [L7]
  }
  final token = authenticationService.generateToken(
    email: request.email, userid: userid);
  return AuthResponse()
    ..success = true
    ..message = 'Login successful'
    ..token = token;
}
```

### R5 — Path Sanitization + _getDBName Fix

**File:** `lib/sqlite_wrapper_server.dart`

**(a) Sanitizzare `dbName` contro path traversal: [L5]**

```dart
String _sanitizeDBName(String dbName) {
  return dbName.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
}
```

Applicare in `_getDBPath` prima dell'interpolazione.

**(b) Fix `_getDBName` throw:**

```dart
// Sostituire:
throw ("Something is wrong... why isn't the user logged in?");
// Con:
throw GrpcError.unauthenticated('User not authenticated');
```

### R6 — Error Handling nelle RPC

**File:** `lib/sqlite_wrapper_server.dart`

Avvolgere `execute` e `select` in try-catch. [L6]

```dart
@override
Future<SqlQueryResponse> execute(ServiceCall call, SqlQueryRequest request) async {
  final String dbName = _getDBName(call: call, dbName: request.dbName);
  final pool = DatabasePool.get(dbName, _getDBPath(dbName));
  try {
    final res = await pool.execute(
      request.sql,
      params: _unpack(request.params.toList()),
    );
    return SqlQueryResponse(result: jsonEncode(res));
  } catch (e) {
    throw GrpcError.invalidArgument('SQL execution error: $e');
  }
}
```

Stessa struttura per `select` con messaggio `'SQL query error: $e'`.

> **Dipendenza:** R6 presuppone R1 già implementato. Usa `DatabasePool.get()`
> definito in R1. Se implementato prima di R1, il codice non compila.

**`openDB`** — passa `request.version` al pool per gestire le migrazioni:

```dart
@override
Future<OpenDBResponse> openDB(ServiceCall call, OpenDBRequest request) async {
  final String dbName = _getDBName(call: call, dbName: request.dbName);
  print("OpenDB called: version=${request.version}, dbName=$dbName");
  final pool = DatabasePool.get(dbName, _getDBPath(dbName),
      version: request.version);
  final version = await pool.getVersion();
  return OpenDBResponse(
    created: version == 0,
    version: version,
    sqliteVersion: '',  // TODO: usare PRAGMA sqlite_version
    dbName: dbName,
  );
}
```

> Nota: `_entry()` in R1 ora accetta `version`, `onCreate`, `onUpgrade`.
> La prima chiamata a `DatabasePool.get()` per un dbName apre la connessione
> con questi parametri. Le chiamate successive usano la connessione cached.

### R7 — Uniform Login Messages

**File:** `lib/auth_server.dart` [L7]

```dart
return AuthResponse()
  ..success = false
  ..message = 'Invalid email or password';
```

Identico messaggio sia per email non registrata che per password errata.

### R8 — Dependency Cleanup

**File:** `pubspec.yaml` [L8]

Rimuovere:
- `sqlite3: ^3.4.0`
- `fixnum: ^1.1.1`

Mantenere `grpc: ^5.1.0` e `protobuf: ^6.0.0` (import diretti).

### R9 — Test Coverage

**File:** nuovi file sotto `test/`

Struttura:

```
test/
  services/
    database_service_test.dart          # CRUD utenti, password hashing
    authentication_service_test.dart    # JWT generation/verify/expiry
  database_pool_test.dart               # get/close/closeAll/caching
  sqlite_wrapper_server_test.dart       # unit: _getDBName, _getDBPath
  auth_interceptor_test.dart            # unit: auth flow
  integration/
    grpc_server_test.dart               # integration: full server in-process
```

Requisiti per i test:

1. **DatabaseServiceTest**: Usa `SQLiteWrapperBase` con `:memory:` DB.
   Mock `inject<T>()` con `InjectX.reset()` e `InjectX.add()`.
   Copre: insertUser, emailAlreadyRegistered, isLoginCorrect (SHA-256 e
   Argon2id dopo migrazione R2).

2. **AuthenticationServiceTest**: `Constants.secretKey` va inizializzato
   prima di ogni test (`Constants.secretKey = 'test_secret';`).
   Copre: generateToken, verifyToken, expiry di 24h.

3. **DatabasePoolTest**: Test con DB in memoria. Copre: `get()` restituisce
   wrapper funzionante (execute/select), `close()` decrementa refCount e
   chiude a 0, `closeAll()` chiude tutte le connessioni, due `get()`
   consecutivi restituiscono lo stesso wrapper (caching per dbName).
   **Non usa `subscribe`/`unsubscribe`** — quei metodi sono nel pool
   esteso di `0001-grpc-watch-streaming/`.

4. **SqliteWrapperServerTest**: Copre: `_getDBName` con sharedDB, senza
   uuid, `_getDBPath` con dbName sanificato.

5. **AuthInterceptorTest**: Copre: richieste senza token, token valido,
   token scaduto, path pubblico bypassa auth.

6. **IntegrationTest**: Server in-process con `Server.create()`. Client
   gRPC chiama Echo, Register, Login, Execute, Select.

### R10 — Dead Code Removal

**File:** `lib/sqlite_wrapper_server.dart`, `lib/stream_info.dart`

- Rimuovere `static final List<StreamInfo> streams` da
  `SQLiteWrapperServerImpl`
- Eliminare `lib/stream_info.dart`
- Verificare nessun import a `package:sqlite_wrapper_server/stream_info.dart`

> **Nota:** Già coperto da `0001-grpc-watch-streaming/` R8.

## Technical Decisions

- **Pool globale statico** — nessuno stato per-utente, singleton è
  sufficiente. [L1]
- **`cryptography_plus`** — scelto perché attivamente mantenuto
  (ultimo aggiornamento 4 mesi fa), include Argon2id nativo, 150 pub
  points. [L2]
- **`hash_algorithm` colonna** — approccio più semplice per tracciare
  la migrazione. Alternativa (sentinel value nell'hash stesso) è meno
  esplicita. [L2]
- **JWT sempre con `exp` a 24h** — breaking change per token esistenti.
  Gli utenti rifaranno login dopo l'aggiornamento. [L3]
- **Map key access** — `query()` con `singleResult: true` e >1 colonna
  restituisce `Map<String, dynamic>`. L'accesso con `res[0]` è un bug.
  Usare `res['column_name']`. [L4]
- **`throw GrpcError.unauthenticated`** — `_getDBName` è chiamato da
  RPC handlers gRPC. Il framework cattura l'errore e lo traduce nel
  codice gRPC appropriato. [L5]
- **Try-catch in RPC handler, non nel pool** — il pool non deve
  decidere la strategia di errore. Il chiamante (handler RPC) la
  decide. [L6]
- **Test con `:memory:`** — già supportato da `SQLiteWrapperBase`,
  nessuna dipendenza esterna.

## Testing Strategy

**Test Seams:**

1. **`:memory:` SQLite** — `SQLiteWrapperCore()` con path `:memory:`
   per tutti i test che coinvolgono il database, senza scrivere su disco.
2. **`InjectX.reset()`** — per isolare test di `DatabaseService` che
   usano `inject<T>()`, chiamare `InjectX.reset()` in `setUp` e
   `InjectX.add<SQLiteWrapperBase>(SQLiteWrapperCore())` in `setUp`.
3. **`Constants` override diretto** — `Constants.secretKey` è
   `static late`, assegnabile direttamente (`Constants.secretKey = 'x'`)
   senza passare da `Constants.parse()`.
4. **Server in-process** — `Server.create()` su `localhost:0` per
   integration test senza dipendenze di rete.

**Copertura:**
- Unit test: 5 file, tutti scrivibili indipendentemente (R9 requisito 1-5)
- Integration test: 1 file, dipende da R1 (pool) e R2 (Argon2id)

## Out of Scope

- Client-side changes (Flutter example) — focus è solo server.
- Async factories o lazy registration via `InjectX` — non necessario.
- Optimizing `SQLITE_BUSY` retry strategy — strategy baseline inclusa,
  ottimizzazioni future dopo test di carico.
- gRPC Watch streaming — coperto da `0001-grpc-watch-streaming/`.

## Blocking Questions

Nessuna.

## Open Questions

- **`SQLITE_BUSY` timeout**: 300ms è sufficiente? Il valore è baseline
  e sarà rivisto dopo test di carico in produzione.
- **Argon2id parametri**: memory=19456, iterations=2. Validare su
  hardware di produzione.

## Follow-Ups

- Pubblicare nuova versione del server dopo tutte le modifiche.
- Eseguire test di carico per validare retry e parametri Argon2id.
