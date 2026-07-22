---
type: Interview Ledger
parent: spec.md
---

## Records

### L1

Status: current

Question: Quale problema risolve includere l'email nel filename DB?

Recommended Answer: Debuggabilità — rendere i file `.sqlite` immediatamente riconoscibili sul filesystem senza aprire il database.

Answer: sì

Decision: Includere l'email di registrazione nel nome del file DB per riconoscibilità immediata sul filesystem.

### L2

Status: current

Question: Come sanitizzare l'email per il filename?

Recommended Answer: Sostituire `@` → `_at_` e `.` → `_dot_`, poi applicare la sanitizzazione standard `[^a-zA-Z0-9_-]` → `_`.

Answer: 1 (opzione esplicita e reversibile)

Decision: Encoding email con `@` → `_at_`, `.` → `_dot_`, poi sanitizzazione standard. Funzione separata `_encodeEmailForFilename()`.

### L3

Status: current

Question: Quale formato per il filename?

Options:
1. `{prefix}_{sanitizedEmail}_{uuid}.sqlite`
2. `{prefix}_{uuid}_{sanitizedEmail}.sqlite`
3. `{prefix}_{sanitizedEmail}.sqlite`

Answer: 1

Decision: Formato `{prefix}_{sanitizedEmail}_{uuid}.sqlite`. L'UUID rimane l'identificatore univoco, l'email è decorazione leggibile.

### L4

Status: current

Question: Come gestire la migrazione dei database esistenti (`{prefix}_{uuid}.sqlite` senza email)?

Options:
1. Rinomina automatica del file all'openDB successivo
2. Breaking change — file esistenti non vengono più aperti
3. Niente migrazione in questa spec

Answer: 2

Decision: Breaking change documentato. I database esistenti rimangono sul disco ma non vengono più aperti. Gli utenti esistenti devono ricreare i loro DB.

### L5

Status: current

Question: Cosa succede se un utente cambia email?

Recommended Answer: Accettabile come comportamento per ora. Il cambio email non è supportato dalle API correnti (nessuna RPC `updateEmail`). Se in futuro verrà aggiunto, si potrà gestire la rinomina in quella sede.

Answer: ok

Decision: Cambio email non gestito. Se l'email cambia, il filename cambia e il vecchio file rimane orfano. Accettabile perché l'operazione è rara e non supportata dalle API attuali.

### L6

Status: current

Question: Dove inserire l'encoding dell'email?

Recommended Answer: Nuova funzione `_encodeEmailForFilename()` separata da `_sanitizeDBName()`. Chiamata in `_getDBName` prima di assemblare il nome. `_sanitizeDBName` in `_getDBPath` si occupa della sanitizzazione filesystem residua.

Answer: sì

Decision: `_encodeEmailForFilename()` trasforma `@` → `_at_` e `.` → `_dot_`. `_sanitizeDBName` resta responsabile della sanitizzazione `[^a-zA-Z0-9_-]` → `_`.

Constraints:
- `sharedDB` mode: nessun cambiamento (nessuna email per-utente)
- `unauthenticated` mode: nessun cambiamento (nessun metadata utente)
- Scope limitato a `lib/sqlite_wrapper_server.dart`
- Nessuna modifica al protocollo gRPC o alla pool lato client
