---
type: Interview Ledger
parent: spec.md
---

## Records

### L1

Status: current

Question: Il proto `sqlite_wrapper_rpc.proto` va modificato in un fork o direttamente?

Answer: Il pacchetto è mio, posso modificarlo.

Decision: I messaggi `WatchRequest`/`WatchResponse` e la RPC `Watch` vengono
aggiunti direttamente nel proto del pacchetto `sqlite_wrapper`. Il pacchetto
sarà pubblicato come nuova versione. Il server dipenderà dalla nuova versione.

### L2

Status: current

Question: `WatchResponse` deve distinguere singolo valore da lista. Due opzioni:
(A) `string json` + `bool singleResult`, (B) `repeated string rows`.

Answer: Opzione A.

Decision: `WatchResponse` ha `string json` (risultato serializzato) e
`bool singleResult` (replica del valore della richiesta per comodità del client).

### L3

Status: current

Question: Watch RPC deve essere autenticata o pubblica?

Answer: Autenticata come execute/select.

Decision: Watch non è in `publicPaths`. Richiede JWT valido. L'interceptor
esistente copre automaticamente tutti i metodi di `SqliteWrapperService`.

### L4

Status: current

Question: Connection pool server-side va passato via inject_x o globale statico?

Answer: Globale statico — non c'è stato per-utente.

Decision: `DatabasePool` è una classe con membri statici. Non registrata in
`inject_x`.

### L5

Status: deferred

Question: Come gestire `SQLITE_BUSY` in scritture concorrenti sul pool?

Answer: Rimandiamo — lo scheduleremo come Work Item separato dopo
l'implementazione base.

Decision: Retry baseline 3 tentativi, backoff lineare 50/100/150ms, timeout
300ms, inserito in `SQLiteWrapperServerImpl.execute()`. Eventuali ottimizzazioni
saranno valutate dopo test di carico.
