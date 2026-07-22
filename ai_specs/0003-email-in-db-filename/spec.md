---
type: Spec
title: Include Registration Email in Database Filename
---

## Problem

I database degli utenti sono attualmente nominati `{prefix}_{uuid}.sqlite` (es. `mainDB_550e8400-e29b-41d4-a716-446655440000.sqlite`). Sul filesystem non è possibile identificare a quale utente appartenga un file senza aprirlo e leggere la tabella `users`. In scenari di debug, backup e amministrazione del server, questo costringe a operazioni manuali extra.

## Proposed Outcome

I file dei database utente includono l'email di registrazione nel nome, nel formato `{prefix}_{sanitizedEmail}_{uuid}.sqlite`. Un file come `mainDB_mario_dot_rossi_spam_at_gmail_dot_com_550e8400-e29b-41d4-a716-446655440000.sqlite` è immediatamente riconoscibile. [L1]

## User Stories

1. Come operatore del server, voglio che i file `.sqlite` degli utenti contengano l'email nel nome, così da poterli identificare a colpo d'occhio sul filesystem. [L1]

2. Come sviluppatore che debugga un problema utente, voglio trovare il file corretto guardando la directory, senza aprire database. [L1]

## Requirements

### R1 — Nuova funzione `_encodeEmailForFilename`

**File:** `lib/sqlite_wrapper_server.dart`

Aggiungere metodo privato sulla classe `SQLiteWrapperServerImpl`:

```dart
/// Encode email for safe inclusion in a filename.
///
/// Replaces `@` with `_at_` and `.` with `_dot_` so the email remains
/// human-readable in the filename. The result is then sanitized by
/// [_sanitizeDBName] before filesystem use.
String _encodeEmailForFilename(String email) {
  return email
      .replaceAll('@', '_at_')
      .replaceAll('.', '_dot_');
}
```

Chiamata in `_getDBName` dopo aver ottenuto l'email dal metadata della `ServiceCall`. [L2] [L6]

### R2 — `_getDBName` aggiornato per includere l'email

**File:** `lib/sqlite_wrapper_server.dart`

Modificare `_getDBName` per leggere l'email da `call.clientMetadata!['email']` e includerla nel nome, dopo l'encoding.

```dart
String _getDBName({required ServiceCall call, required String dbName}) {
    final String? uuid = call.clientMetadata!['user_uuid'];
    if (uuid == null) {
      if (Constants.sharedDB == true) {
        return dbName;
      } else {
        throw GrpcError.unauthenticated(
            'User not authenticated for non-shared database');
      }
    }
    final String email = call.clientMetadata!['email'] ?? '';
    final String emailSuffix = email.isNotEmpty
        ? '${_encodeEmailForFilename(email)}_'
        : '';
    final prefix = Constants.dbName ?? dbName;
    return "${prefix}_${emailSuffix}$uuid";
}
```

**Comportamento per casi particolari:** [L6]
- `sharedDB == true`: nessuna email, nessun UUID → nome invariato (solo `dbName`)
- `email` assente dal metadata (es. utente non loggato ma autenticato): `emailSuffix` vuoto, formato retrocompatibile `{prefix}_{uuid}.sqlite`
- `unauthenticated` mode: il metadata non contiene email né UUID, ma le RPC sono bloccate da `_getDBName` che lancia `GrpcError.unauthenticated` (già coperto da codice esistente)

### R3 — Formato filename finale

**File:** `lib/sqlite_wrapper_server.dart` (`_getDBPath`)

Il path del file risultante segue il formato: [L3]

```
{dbPath}/{prefix}_{sanitizedEmail}_{uuid}.sqlite
```

Esempio concreto:
- `Constants.dbPath = "./data"`
- `Constants.dbName = "app"`
- `email = "mario.rossi+spam@gmail.com"`
- `uuid = "550e8400-e29b-41d4-a716-446655440000"`

→ `./data/app_mario_dot_rossi_spam_at_gmail_dot_com_550e8400-e29b-41d4-a716-446655440000.sqlite`

La sanitizzazione finale contro path traversal (`_sanitizeDBName`) trasforma `+` e altri caratteri non consentiti in `_`.

### R4 — Nessuna migrazione automatica

I database esistenti con nome `{prefix}_{uuid}.sqlite` non vengono rinominati né aperti con il nuovo schema. [L4]

**Conseguenze documentate:**
- Al primo avvio dopo l'aggiornamento, gli utenti esistenti troveranno un DB vuoto (il server creerà un nuovo file con il nome contenente l'email)
- I vecchi file rimangono sul disco e devono essere gestiti manualmente dall'operatore (cancellazione o backup)
- L'operatore deve comunicare agli utenti che i dati vanno reinseriti o ripristinati da backup

### R5 — Break dell'email change non gestito

Se un utente cambia email (operazione non supportata dalle API correnti), il filename cambia e il vecchio file rimane orfano. [L5]

## Technical Decisions

- **Encoding `@` → `_at_`, `.` → `_dot_`** scelto perché è reversibile e mantiene l'email leggibile. Percent-encoding sarebbe preciso ma illeggibile. [L2]
- **`_encodeEmailForFilename` separata da `_sanitizeDBName`** per separare encoding semantico da sanitizzazione filesystem. [L6]
- **UUID come suffisso stabile** — la chiave della `DatabasePool` e l'identificatore univoco rimane l'UUID. L'email è decorazione. [L3]
- **Breaking change senza migrazione** — la rinomina automatica introdurrebbe complessità (race condition, lock, rollback) per un evento one-shot. [L4]

## Testing Strategy

**Test Seams esistenti (nessuna modifica necessaria):**
1. **`:memory:` SQLite** — già usato in `database_pool_test.dart`
2. **`FakeServiceCall`** — già presente in `sqlite_wrapper_server_test.dart`, consente di impostare `clientMetadata` arbitrari

**Test da aggiornare:**

1. **`sqlite_wrapper_server_test.dart`** — gruppo `_getDBName`:
   - Aggiungere test con email nel metadata → verifica formato `{prefix}_{email}_{uuid}`
   - Aggiungere test con email contenente `@` e `.` → verifica encoding
   - Aggiungere test con email vuota nel metadata → formato retrocompatibile `{prefix}_{uuid}`
   - Verificare che `sharedDB == true` ignori email e UUID

2. **`auth_interceptor_test.dart`** — già verifica che `call.clientMetadata!['email']` sia impostato. Nessuna modifica necessaria.

3. **`database_pool_test.dart`** — i test del pool non toccano il naming. Nessuna modifica necessaria.

## Out of Scope

- Migrazione dei database esistenti
- RPC `updateEmail` o gestione cambio email
- Modifiche al protocollo gRPC o ai messaggi proto
- Modifiche lato client (`sqlite_wrapper_grpc_example`)
- Modifiche alla `DatabasePool`

## Open Questions

Nessuna.

## Follow-Ups

- Aggiornare `CHANGELOG.md` con la modifica e il breaking change
- Aggiornare `README.md` se la sezione "Database Management" descrive il naming
- Verificare che la documentazione interna/esistente non faccia assunzioni sul nome file
