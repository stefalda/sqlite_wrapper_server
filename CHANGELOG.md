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
