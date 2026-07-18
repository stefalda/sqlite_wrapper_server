## 1.2.2

- Use the sqlite_wrapper 0.5.2 to fix gPRC problems

## 1.2.1

- Fixed missing await in select

## 1.2.0

- **Argon2id password hashing:** SHA-256 replaced with Argon2id via
  `cryptography_plus`. Existing SHA-256 hashes are migrated to Argon2id on
  next successful login; the `hash_algorithm` column tracks the algorithm
  version per user.
- **JWT fixes:** `iat` now uses Unix seconds (RFC 7519 §2), `exp` added at
  24 hours. Typo `runUnathenticated` renamed to `runUnauthenticated` with a
  `@Deprecated` alias. Race condition closed by setting the flag before
  `server.serve()`.
- **Single-query auth:** `register` and `login` each issue 1 query instead
  of 3. `insertUser` returns the generated UUID directly. `isLoginCorrect`
  returns `(bool, String?)` and uses Map key access (fixes the `res[0]`
  crash on multi-column `query()` results).
- **Path traversal protection:** `_sanitizeDBName` strips non-alphanumeric
  characters from `dbName` before filesystem interpolation.
- **SQLITE_BUSY retry:** `execute` retries up to 3 times with 50/100/150ms
  backoff, then throws `GrpcError.unavailable`.
- **Uniform login errors:** Both "email not found" and "wrong password"
  return `'Invalid email or password'` to prevent user enumeration.
- **Dependency cleanup:** Removed unused `sqlite3` and `fixnum` direct
  dependencies; added `cryptography_plus`.
- **Test coverage:** 5 new test files (unit + integration) — 35 tests total.
- **README updated:** reflects the new cryptography dependency, Argon2id,
  and JWT expiry documentation.

## 1.1.0

- **New `Watch` RPC (server-streaming gRPC):** clients can now subscribe to SQL
  queries and receive real-time push updates whenever any client modifies the
  watched tables. The server uses a `DatabasePool` with reference-counted
  connections so mutations from any RPC trigger `updateStreams()` on all active
  watch subscriptions — enabling reactive multi-user UIs without polling.
- **New `DatabasePool`:** static, reference-counted connection pool that
  replaces the singleton `sqliteWrapper` pattern. Every `get()` increments a
  refcount; every `close()` decrements it. When the counter reaches zero the
  underlying connection is closed. Watch subscriptions (`subscribe`/`unsubscribe`)
  keep the connection alive for their duration.
- **Internal refactor:** all existing RPC handlers (`execute`, `select`,
  `openDB`, `closeDB`, `getVersion`, `setVersion`) now go through
  `DatabasePool` instead of a per-instance wrapper, ensuring that `execute()`
  calls notify watch streams regardless of which client triggered the mutation.
- **Auth fix:** `_getDBName` now throws `GrpcError.unauthenticated()` instead of
  a raw `String` when a non-shared database is accessed without authentication.
- **Path cleanup:** `_getDBPath` strips trailing slashes from `Constants.dbPath`
  to avoid double-slash paths.
- **Dead code removed:** deleted `lib/stream_info.dart` and the unused
  `static List<StreamInfo> streams` field.
- **Graceful shutdown:** `DatabasePool.closeAll()` is called on SIGINT/SIGTERM.
- **Dockerfile:** switched to `dart build cli` (Dart 3.10+ native assets),
  replacing `dart compile exe` which no longer supports packages with build hooks
  (`sqlite3`).

## 1.0.0

- Initial version.
