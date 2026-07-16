---
type: Interview Ledger
parent: spec.md
---

## Records

### L1

Status: current

Question: Il server apre e chiude SQLite a ogni richiesta RPC. Come risolvere?

Answer: Connection pool con reference counting (DatabasePool).

Decision: `DatabasePool` mantiene connessioni per `dbName`, con `refCount`
per gestire apertura/chiusura concorrente. Il pool è globale statico.

### L2

Status: current

Question: Password hashing: SHA-256 o Argon2?

Answer: Argon2id tramite `cryptography_plus`.

Decision: Sostituire SHA-256 con Argon2id. Migrazione graduale: hash SHA-256
esistenti convertiti al prossimo login (colonna `hash_algorithm`).

### L3

Status: current

Question: JWT: `iat` in millisecondi, nessun `exp`. Va fixato?

Answer: Sì.

Decision: `iat` in secondi UNIX, aggiungere `exp` a 24h. Fixare anche race
condition `runUnauthenticated` e rename typo.

### L4

Status: current

Question: `query()` con `singleResult: true` restituisce `Map` non `List`.
Il codice usa `res[0]` — bug.

Answer: Usare chiavi nominali (`res['id']`, `res['salt']`, `res['password_hash']`).

Decision: Eliminare query duplicate in register/login. `insertUser` restituisce
UUID. `isLoginCorrect` restituisce `(bool, String?)`. Accesso a Map con
chiavi nominali.

### L5

Status: current

Question: `_getDBName` lancia una stringa quando uuid è null. Va fixato?

Answer: Sì, deve lanciare `GrpcError.unauthenticated`.

Decision: Sostituire `throw ("Something is wrong...")` con
`throw GrpcError.unauthenticated('User not authenticated')`. Sanificare
anche `_getDBPath` contro path traversal.

### L6

Status: current

Question: Errori SQL arrivano come `GrpcError.internal` senza dettagli.

Answer: Usare `GrpcError.invalidArgument` con messaggio.

Decision: RPC execute/select avvolte in try-catch, errore mappato a
`GrpcError.invalidArgument` con dettaglio.

### L7

Status: current

Question: Login ("User not found" vs "Invalid password") permette enumeration.

Answer: Unificare messaggi.

Decision: Entrambi i casi restituiscono `success: false` con messaggio
"Invalid email or password".

### L8

Status: current

Question: `sqlite3`, `grpc`, `fixnum`, `protobuf` sono tutti transitivi di
`sqlite_wrapper`. Si possono rimuovere?

Answer: Solo `sqlite3` e `fixnum` (0 import diretti). `grpc` e `protobuf`
sono importati dal server.

Decision: Rimuovere solo `sqlite3` e `fixnum` da `pubspec.yaml`.

### L9

Status: current

Question: StreamInfo/streams in SQLiteWrapperServerImpl: codice morto?

Answer: Sì, rimuovere.

Decision: Rimuovere `static final List<StreamInfo> streams` e
`lib/stream_info.dart`. Già coperto da 0001-grpc-watch-streaming.
