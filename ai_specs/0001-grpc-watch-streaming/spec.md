---
type: Spec
title: gRPC Server-Streaming Watch
---

## Coding Conventions

Le seguenti indicazioni si applicano a TUTTI i requisiti di questa specifica:

1. **Commenti:** Non rimuovere commenti esistenti a meno che non siano
   diventati errati o fuorvianti. Aggiungere commenti esplicativi nei punti
   di codice più complessi (logica di retry, gestione disconnessione,
   reference counting, mappatura `fromMap`).
2. **Documentazione:** Aggiornare `README.md` del rispettivo repo per
   riflettere le nuove API e funzionalità (nuova RPC `Watch`, comportamento
   cross-client).
3. **Esempi:** Aggiornare il codice di esempio in
   `sqlite_wrapper_grpc_example/` per usare la nuova funzionalità watch.

## Problem

The `sqlite_wrapper` package provides a reactive `watch()` mechanism:
`SQLiteWrapperBase.watch()` creates a Dart `Stream` that emits new query results
whenever `execute()` modifies a watched table. This mechanism is **local to one
process** — it only works when the wrapper calling `execute()` is the same
instance that created the watch stream.

When using the remote gRPC mode (`SqliteWrapperGRPC`), the inherited `watch()`
creates a **local** Dart `Stream` that is fed by the local `updateStreams()`
call inside `SqliteWrapperGRPC.execute()`. This means:

1. Client A cannot see changes made by Client B (different process).
2. Updates are only pushed when the same client calls `execute()` — if another
   client modifies data, the local stream is never notified.
3. The proto file (`sqlite_wrapper_rpc.proto`) already has a commented-out
   `Watch` RPC with no `WatchRequest`/`WatchResponse` messages, leaving the
   feature structurally incomplete.
4. The server project (`sqlite_wrapper_server`) contains dead code
   (`static List<StreamInfo> streams`, `lib/stream_info.dart`) that was started
   to bridge this gap but never completed.

## Proposed Outcome

A server-streaming gRPC `Watch` RPC that lets remote clients subscribe to SQL
queries and receive real-time push updates whenever any client modifies the
watched tables. The implementation spans two repositories:

1. **`sqlite_wrapper` package**: proto changes, regenerated gRPC stubs,
   `SqliteWrapperGRPC.watch()` overridden to use the server-streaming RPC.
2. **`sqlite_wrapper_server`**: `DatabasePool` with reference-counted connection
   management, `Watch` RPC handler, `execute`/`select`/`openDB`/`closeDB`
   refactored to use the pool so that `updateStreams()` triggers automatically
   on all watch subscriptions.

## User Stories

1. As a remote client using `SqliteWrapperGRPC`, I want to call `watch()` and
   receive the initial query result plus subsequent updates pushed by the
   server, so I can build reactive UIs without polling. [L2]

2. As a remote client, I want my `watch()` subscription to receive updates
   triggered by SQL mutations from **any** client — not just my own — so that
   multi-user scenarios stay consistent in real time. [L1]

3. As the server operator, I want watch subscriptions to auto-clean when a
   client disconnects, so long-running connections do not leak memory.

## Requirements

### R1 — Proto: Definire WatchRequest, WatchResponse, scommentare Watch RPC

**Repo:** `sqlite_wrapper`  
**File:** `protos/sqlite_wrapper_rpc.proto`

```proto
message WatchRequest {
  string sql = 1;
  repeated google.protobuf.Any params = 2;
  string dbName = 3;
  repeated string tables = 4;
  bool singleResult = 5;
}

message WatchResponse {
  string json = 1;
  bool singleResult = 2;
}

service SqliteWrapperService {
  // ... existing RPCs unchanged ...
  rpc Watch(WatchRequest) returns (stream WatchResponse);
}
```

`WatchResponse.singleResult` replica il valore della richiesta per permettere
al client di decidere come interpretare `json`: singolo valore o lista. [L2]

### R2 — Rigenerare i file Dart

**Repo:** `sqlite_wrapper`  
**Script:** `protos/refresh.sh`

Eseguire `protoc` per rigenerare i file in `lib/generated/`:

```zsh
protoc --dart_out=grpc:lib/generated \
  -Iprotos \
  protos/sqlite_wrapper_rpc.proto \
  protos/google/protobuf/any.proto \
  protos/google/protobuf/wrappers.proto \
  protos/auth.proto
```

Commitare (repo `sqlite_wrapper`):
- `lib/generated/sqlite_wrapper_rpc.pb.dart`
- `lib/generated/sqlite_wrapper_rpc.pbgrpc.dart`
- `lib/generated/sqlite_wrapper_rpc.pbenum.dart`
- `lib/generated/sqlite_wrapper_rpc.pbjson.dart`

### R3 — SqliteWrapperGRPC.watch() override usando gRPC stream

**Repo:** `sqlite_wrapper`  
**File:** `lib/grpc/sqlite_wrapper_grpc.dart`

Sostituire il `watch()` ereditato da `SQLiteWrapperBase` con una versione che
usa la server-streaming RPC. Usare `StreamController` manuale (non `async*`)
perché l'override deve restituire `Stream` e la gRPC response stream va
sottoscritta con `listen()`:

```dart
@override
Stream watch(
  String sql, {
  List<Object?> params = const [],
  FromMap? fromMap,
  bool singleResult = false,
  required List<String> tables,
  String? dbName,
}) {
  final responseStream = client.watch(WatchRequest(
    sql: sql,
    params: convertParamsToAny(params),
    dbName: dbName ?? defaultDBName,
    tables: tables,
    singleResult: singleResult,
  ));
  final sc = StreamController();
  responseStream.listen(
    (response) {
      final decoded = jsonDecode(response.json);
      if (fromMap != null && response.singleResult && decoded is Map) {
        sc.add(fromMap(decoded));
      } else if (fromMap != null && !response.singleResult && decoded is List) {
        sc.add(decoded.map((e) => fromMap(e as Map)).toList());
      } else {
        sc.add(decoded);
      }
    },
    onDone: () => sc.close(),
    onError: (e) => sc.addError(e),
    cancelOnError: true,
  );
  return sc.stream;
}
```

### R4 — DatabasePool con reference counting

**Repo:** `sqlite_wrapper_server`  
**File:** `lib/database_pool.dart` (nuovo)

Pool di connessioni SQLite che supporta reference counting e callback di
migrazione (`onCreate`/`onUpgrade`). Il `refCount` parte da 0 e viene
incrementato da ogni `get()` e decrementato da `close()`. Serve per
evitare di chiudere una connessione mentre è ancora in uso da un altro
handler o da una watch attiva. [L4]

```dart
class DatabasePool {
  static final Map<String, _PoolEntry> _connections = {};

  static SQLiteWrapperCore get(
    String dbName,
    String dbPath, {
    int version = 0,
    OnCreate? onCreate,
    OnUpgrade? onUpgrade,
  }) {
    final entry = _entry(dbName, dbPath,
        version: version, onCreate: onCreate, onUpgrade: onUpgrade);
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

  static Stream subscribe({
    required String dbName,
    required String dbPath,
    required String sql,
    required List<Object?> params,
    required List<String> tables,
    required bool singleResult,
  }) {
    final entry = _entry(dbName, dbPath);
    entry.refCount++;
    return entry.wrapper.watch(sql,
        params: params, tables: tables, singleResult: singleResult);
  }

  static void unsubscribe(String dbName) {
    close(dbName);
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

**Chiave `dbName`:** Assunzione che `dbName → dbPath` sia deterministico
(garantito dal server tramite `_getDBPath`). In `sharedDB` mode tutti gli
utenti condividono lo stesso dbName → stessa connessione.

> **Nota:** `_getDBPath` in `lib/sqlite_wrapper_server.dart` fa
> `return "$dbPath/$dbName.sqlite"`. Se `Constants.dbPath` termina con `/`
> (default `"./"`), il path diventa `".//<dbName>.sqlite"` (doppio slash).
> SQLite lo tollera, ma per pulizia: usare `"$dbPath/$dbName.sqlite"`
> rimuovendo lo slash finale da `Constants.dbPath` se presente.

### R5 — Server: implementare RPC Watch

**Repo:** `sqlite_wrapper_server`  
**File:** `lib/sqlite_wrapper_server.dart`

Aggiungere override del metodo `watch` su `SQLiteWrapperServerImpl`:

```dart
@override
Stream<WatchResponse> watch(ServiceCall call, WatchRequest request) async* {
  final String dbName = _getDBName(call: call, dbName: request.dbName);
  final String dbPath = _getDBPath(dbName);

  print("Watch called: sql=${request.sql}, tables=${request.tables}, dbName=$dbName");

  final Stream stream = DatabasePool.subscribe(
    dbName: dbName,
    dbPath: dbPath,
    sql: request.sql,
    params: _unpack(request.params.toList()),
    tables: request.tables,
    singleResult: request.singleResult,
  );

  try {
    await for (final result in stream) {
      yield WatchResponse(
        json: jsonEncode(result),
        singleResult: request.singleResult,
      );
    }
  } finally {
    DatabasePool.unsubscribe(dbName);
  }
}
```

**Pre-requisito:** Prima di implementare R5, `_getDBName` in
`lib/sqlite_wrapper_server.dart` deve essere corretto per lanciare
`GrpcError.unauthenticated()` invece di una `String` quando `uuid == null &&
sharedDB == false`. Senza questo fix, Watch crasha con eccezione non
catturabile su richieste non autenticate.

**Auth:** Watch NON è in `publicPaths`. Richiede JWT valido. [L3]

**Disconnessione:** gRPC Dart cancella lo stream quando il client si
disconnette, attivando `finally` → `unsubscribe()`.

### R6 — Server: refactor execute, select, openDB, closeDB su DatabasePool

**Repo:** `sqlite_wrapper_server`  
**File:** `lib/sqlite_wrapper_server.dart`

Tutte le RPC che toccano il database devono usare `DatabasePool` invece del
campo `sqliteWrapper` singleton.

**execute** — usa `DatabasePool.get()`, avvolge in try-catch per errore SQL:

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

`pool.execute()` chiama internamente `updateStreams(tables)`, che notifica
TUTTI gli stream registrati per quel database. Qualsiasi client che fa una
scrittura triggera aggiornamenti su TUTTI i Watch attivi sulle stesse tabelle.

**select** — usa `DatabasePool.get()`, sola lettura, nessun retry:

```dart
@override
Future<SqlQueryResponse> select(ServiceCall call, SqlQueryRequest request) async {
  final String dbName = _getDBName(call: call, dbName: request.dbName);
  final pool = DatabasePool.get(dbName, _getDBPath(dbName));
  try {
    final db = pool.getDatabase();
    final res = db!.select(request.sql, _unpack(request.params.toList()));
    return SqlQueryResponse(result: jsonEncode(res));
  } catch (e) {
    throw GrpcError.invalidArgument('SQL query error: $e');
  }
}
```

**openDB** — usa `DatabasePool.get()` per warmare la connessione (con
`onCreate`/`onUpgrade` gestiti dal pool) e leggere versione e sqliteVersion:

```dart
@override
Future<OpenDBResponse> openDB(ServiceCall call, OpenDBRequest request) async {
  final String dbName = _getDBName(call: call, dbName: request.dbName);
  print("OpenDB called: version=${request.version}, dbName=$dbName");
  final pool = DatabasePool.get(dbName, _getDBPath(dbName),
      version: request.version);
  final version = await pool.getVersion();
  final sqliteVersion = await pool.query(
      "PRAGMA sqlite_version", singleResult: true);
  return OpenDBResponse(
    created: version == 0,
    version: version,
    sqliteVersion: sqliteVersion as String,
    dbName: dbName,
  );
}
```

**getVersion** — usa `DatabasePool.get()` per leggere la versione corrente:

```dart
@override
Future<GetVersionResponse> getVersion(ServiceCall call, GetVersionRequest request) async {
  final String dbName = _getDBName(call: call, dbName: request.dbName);
  final pool = DatabasePool.get(dbName, _getDBPath(dbName));
  final version = await pool.getVersion();
  return GetVersionResponse(version: version);
}
```

**setVersion** — usa `DatabasePool.get()` per impostare la versione:

```dart
@override
Future<SetVersionResponse> setVersion(ServiceCall call, SetVersionRequest request) async {
  final String dbName = _getDBName(call: call, dbName: request.dbName);
  final pool = DatabasePool.get(dbName, _getDBPath(dbName));
  await pool.setVersion(request.version);
  return SetVersionResponse(success: true);
}
```

**closeDB** — chiama `DatabasePool.close()` per decrementare il reference
count:

```dart
@override
Future<CloseDBResponse> closeDB(ServiceCall call, CloseDBRequest request) async {
  final String dbName = _getDBName(call: call, dbName: request.dbName);
  print("CloseDB called: dbName=$dbName");
  DatabasePool.close(dbName);
  return CloseDBResponse(success: true);
}
```

### R7 — Server: shutdown con DatabasePool.closeAll()

**Repo:** `sqlite_wrapper_server`  
**File:** `bin/main.dart`

Aggiungere `DatabasePool.closeAll()` nei gestori SIGINT/SIGTERM, prima di
`exit(0)`:

```dart
ProcessSignal.sigint.watch().listen((_) async {
  print("Received SIGINT, closing database...");
  DatabasePool.closeAll();
  await databaseService.closeDatabaseConnection();
  exit(0);
});

ProcessSignal.sigterm.watch().listen((_) async {
  print("Received SIGTERM, closing database...");
  DatabasePool.closeAll();
  await databaseService.closeDatabaseConnection();
  exit(0);
});
```

### R8 — Server: rimuovere dead code streams/StreamInfo

**Repo:** `sqlite_wrapper_server`

- Rimuovere `static final List<StreamInfo> streams` da `lib/sqlite_wrapper_server.dart:13`
- Eliminare `lib/stream_info.dart`
- Verificare che nessun import punti a `package:sqlite_wrapper_server/stream_info.dart`

### R9 — Test

**Repo:** `sqlite_wrapper` + `sqlite_wrapper_server`

Testare su tre livelli:

**Unit test — `sqlite_wrapper`:**
- `SqliteWrapperGRPC.watch()`: mockare `client.watch()` per restituire uno
  stream controllato. Verificare: `fromMap` applicato, `singleResult`
  propagato, errori e `onDone` gestiti.

**Unit test — `sqlite_wrapper_server`:**
- `DatabasePool.subscribe()`: verifica che subscribe emetta risultato iniziale
- `DatabasePool.unsubscribe()`: verifica rilascio risorse (`refCount` → 0)
- Due subscribe sullo stesso dbName: entrambi ricevono eventi da `execute()`
- `closeAll()`: chiude tutte le connessioni

**Integration test — `sqlite_wrapper_server`:**
- Server in-process, due client gRPC (SqliteWrapperGRPC)
- Client A watch → Client B insert → Client A riceve aggiornamento
- Client A watch → Client B update → Client A riceve aggiornamento
- Client A watch → Client B delete → Client A riceve set vuoto
- Disconnessione Client A → pool rilascia risorse
- Watch + sharedDB mode
- Watch + unauthenticated mode

## Technical Decisions

- **Proto nel pacchetto, non fork.** `sqlite_wrapper` è di proprietà dell'autore.
  I messaggi Watch vengono aggiunti direttamente e pubblicati come `0.5.0`. [L1]

- **`WatchResponse.singleResult` per disambiguare.** Il server emette JSON con
  forma diversa in base al parametro `singleResult`. Il campo `singleResult`
  replica il valore della richiesta per comodità del client. [L2]

- **Watch richiede autenticazione JWT.** Non rientra in `publicPaths`.
  L'interceptor esistente copre automaticamente tutti i metodi. [L3]

- **`DatabasePool` statico, non DI.** Non c'è stato per-utente. Un singleton
  globale è sufficiente e più semplice. [L4]

- **`SqliteWrapperGRPC.watch()` usa `StreamController` invece di `async*`.**
  La gRPC response stream va sottoscritta con `listen()`. L'override deve
  restituire un `Stream`, non un `Stream<dynamic>` tipizzato.

- **`updateStreams()` chiamato da pool.execute().** Il pool restituisce il
  `SQLiteWrapperCore` usato per la connessione. `execute()` su di esso chiama
  `updateStreams()` che notifica TUTTI gli stream registrati su QUEL wrapper.
  Poiché il pool mantiene un wrapper per `dbName`, tutti i Watch sullo stesso
  database vengono notificati.

## Testing Strategy

**Test Seams:**

1. **`:memory:` SQLite database** — già supportato da `SQLiteWrapperBase`.
   Tutti i test unitari del pool possono creare database in memoria, senza
   scrivere su disco.

2. **`SqliteWrapperServiceClient` mock** — per testare
   `SqliteWrapperGRPC.watch()` senza un server reale, mockare il client gRPC
   con un `MockSqliteWrapperServiceClient` che restituisce uno stream
   controllato per `watch()`.

3. **Server in-process** — `Server.create()` con servizi reali e
   `ClientChannel` su `localhost:0` (porta dinamica) per integration test
   senza dipendenze esterne.

**Copertura:**

- Unit test `database_pool_test.dart` — verifica reference counting,
  subscribe/unsubscribe, execute+watch integration locale
- Unit test `sqlite_wrapper_grpc_test.dart` (nel pacchetto) — verifica
  `fromMap`, `singleResult`, error propagation
- Integration test `watch_test.dart` — verifica flusso cross-client completo
  con server reale in-process

## Out of Scope

- `fromMap` serializzato via proto — non fattibile (è un callback Dart).
  Il mapping viene applicato lato client.
- Watch in modalità `useGRPC = true` su `SqliteWrapperGRPC` — uso circolare,
  non ha senso.

## Blocking Questions

Nessuna.

## Open Questions

- **Ottimizzazione retry `SQLITE_BUSY`:** la strategia baseline a 3 tentativi
  è sufficiente per il lancio. Sarà rivista dopo test di carico. [L5]

## Follow-Ups

- Pubblicare `sqlite_wrapper 0.5.0` su pub.dev.
- Aggiornare `sqlite_wrapper_server/pubspec.yaml` per dipendere da
  `sqlite_wrapper: ^0.5.0`.
- Aggiornare l'esempio Flutter
  (`sqlite_wrapper_grpc_example/lib/services/database_service.dart`)
  per mostrare watch cross-client.
