# SQLiteWrapperServer

SQLiteWrapperServer is a Dart-based server designed for remote access to SQLite
databases using gRPC. This project supports applications with local-first
architecture (iOS, Android, Desktop) by enabling web support through remote
database storage.

## Features

- **Remote Database Access:** Utilizes the `sqlite_wrapper` package for seamless
  interaction with SQLite databases over a network.
- **User Authentication:** Supports user registration and authentication using
  email and password. Passwords are hashed with **Argon2id** (OWASP first
  choice); legacy SHA-256 hashes are migrated automatically on next login.
- **JWT sessions:** Tokens include `iat` (Unix seconds) and `exp` (24 hours)
  for RFC-compliant session management.
- **Database Management:** Users have their own databases, named by combining
  the provided `dbName` with their unique UUID.
- **Connection pooling:** All RPCs share a static `DatabasePool` with reference
  counting, eliminating file-descriptor churn under concurrent load.
- **Efficient binary protocol (v1.3.0+):** Replaced `google.protobuf.Any` params
  with a compact `Param` oneof and JSON-encoded results with structured `Row`/
  `Value` messages. Reduces payload size by 60–80%.
- **Batch execution (v1.3.0+):** The new `ExecuteBatch` RPC processes multiple
  SQL statements in a single round-trip, reducing latency for composite
  operations.
- **gRPC compression (v1.3.0+):** gzip compression is enabled for both request
  and response messages on native platforms via `GzipCodec` + `CodecRegistry`.
- **Real-time Watch (Server-Streaming gRPC):** Subscribe to SQL queries via the
  `Watch` RPC and receive push updates whenever any client modifies the watched
  tables. The server uses a reference-counted connection pool so that mutations
  from any client trigger notifications on all active watch subscriptions —
  enabling reactive multi-user UIs without polling.
- **ExportBackup RPC (v1.4.0+):** Export the entire database file as bytes
  for backup. Uses WAL mode so the file can be read while connections are
  active. Useful for web clients that cannot access the filesystem.
- **ImportBackup RPC (v1.4.0+):** Import/restore a database from bytes.
  Validates SQLite magic bytes, saves a timestamped backup of the current DB,
  force-closes the pool entry, and writes the new file.
- **ExportCSV RPC (v1.4.0+):** Execute a client-supplied SQL query and return
  the result as a properly escaped CSV string with header row.
- **WAL mode (v1.4.0+):** WAL journal mode is enabled automatically in
  `DatabasePool` after opening each database for concurrent read access.
- **forceClose (v1.4.0+):** `DatabasePool.forceClose()` forcefully closes
  a pooled connection regardless of refcount, used by ImportBackup after
  file replacement.
- **Demo Flutter Client:** Includes a sample client application to demonstrate
  functionality.
- **Proxy Integration:** Due to CORS restrictions and Dart gRPC limitations, the
  server should be placed behind a proxy like Envoy.

## Getting Started

### Prerequisites

- Dart SDK
- gRPC tools
- Docker (optional)
- Envoy Proxy (for deployment)

### Configuration

Configure the server using command line arguments. Key configuration options
include:

| Variable          | Description                                  | Default Value |
| ----------------- | -------------------------------------------- | ------------- |
| `port`            | Listening port of the server                 | 50051         |
| `secret_key`      | Secret used to generate JWT keys             |               |
| `unauthenticated` | Allows unauthenticated access                | false         |
| `users_db_name`   | Name of the database for authenticated users | users         |
| `users_db_path`   | Path to the authenticated users DB           | ./            |
| `db_name`         | Override the app DB name prefix (default: client-supplied "mainDB") |              |
| `db_path`         | Path where application databases are stored  | ./            |
| `shared_db`       | If true, a single shared database is used    | false         |

### Running the Server

Start the server with custom configurations:

```bash
dart bin/main.dart --port=50012 \
                   --unauthenticated=false \
                   --secret_key=a1b2c33d4e5f6g7h8i9jakblc
```

### VSCode Launch Configuration

Configure the server in VSCode by editing `launch.json`:

```json
{
    "name": "Dart",
    "type": "dart",
    "request": "launch",
    "program": "bin/main.dart",
    "args": ["--port", "50051", "--secret_key", "a1b2c33d4e5f6g7h8i9jakblc"]
}
```

## Using Envoy as a Proxy

### Sample Envoy Configuration

Create an `envoy.yaml` file with the following configuration to handle CORS and
proxy gRPC traffic:

```yaml
admin:
    access_log_path: /tmp/admin_access.log
    address:
        socket_address: { address: 0.0.0.0, port_value: 9901 }

static_resources:
    listeners:
        - name: listener_0
          address:
              socket_address: { address: 0.0.0.0, port_value: 50052 }
          filter_chains:
              - filters:
                    - name: envoy.filters.network.http_connection_manager
                      typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                          codec_type: auto
                          stat_prefix: ingress_http
                          route_config:
                              name: local_route
                              virtual_hosts:
                                  - name: local_service
                                    domains: ["*"]
                                    routes:
                                        - match: { prefix: "/" }
                                          route:
                                              cluster: echo_service
                                              timeout: 0s
                                              max_stream_duration:
                                                  grpc_timeout_header_max: 0s
                                    cors:
                                        allow_origin_string_match:
                                            - prefix: "*"
                                        allow_methods: GET, PUT, DELETE, POST, OPTIONS
                                        allow_headers: keep-alive,user-agent,cache-control,content-type,content-transfer-encoding,custom-header-1,x-accept-content-transfer-encoding,x-accept-response-streaming,x-user-agent,x-grpc-web,grpc-timeout,token
                                        max_age: "1728000"
                                        expose_headers: custom-header-1,grpc-status,grpc-message
                          http_filters:
                              - name: envoy.filters.http.grpc_web
                                typed_config:
                                    "@type": type.googleapis.com/envoy.extensions.filters.http.grpc_web.v3.GrpcWeb
                              - name: envoy.filters.http.cors
                                typed_config:
                                    "@type": type.googleapis.com/envoy.extensions.filters.http.cors.v3.Cors
                              - name: envoy.filters.http.router
                                typed_config:
                                    "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
    clusters:
        - name: echo_service
          connect_timeout: 0.25s
          type: logical_dns
          # HTTP/2 support
          typed_extension_protocol_options:
              envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
                  "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
                  explicit_http_config:
                      http2_protocol_options: {}
          lb_policy: round_robin
          load_assignment:
              cluster_name: cluster_0
              endpoints:
                  - lb_endpoints:
                        - endpoint:
                              address:
                                  socket_address:
                                      # address: gRPC-server
                                      address: 0.0.0.0
                                      port_value: 50051
```

### Docker Compose Setup

Use the following `docker-compose.yaml` file to run both the server and Envoy:

```yaml
services:
    sqlitewrapperserver:
        #build: . build locally
        image: sfalda/sqlite_wrapper_server:latest
        ports:
            - "50051"
        volumes:
            - ./data:/data
        environment:
            PORT: 50051
            SECRET_KEY: "a1b2c33d4e5f6g7h8i9jakblc"
            UNAUTHENTICATED: false
            USERS_DB_NAME: users
            USERS_DB_PATH: /data
            DB_NAME: ""
            DB_PATH: /data
            SHARED_DB: false

    envoy:
        image: envoyproxy/envoy:v1.33-latest
        volumes:
            - ./envoy/envoy.yaml:/etc/envoy/envoy.yaml
        ports:
            - "50052:50052"
            #- "9901:9901" # admin console
```

### Deployment

Build and run the Docker containers:

```bash
docker compose up

# Override the app DB name prefix:
# DB_NAME=babibooks docker compose up
```

## Usage

### User Registration and Authentication

Users must provide an email and password upon first connection to generate a
unique UUID, stored in the local users database.

### Database Access

Authenticated users have their own SQLite databases named by combining `dbName`
with their assigned UUID.

### Batch Execution (v1.3.0+)

Clients can batch multiple SQL statements in a single round-trip using the
`ExecuteBatch` RPC. The server processes each statement sequentially and
returns the results in order. This is exposed via `SqliteWrapperGRPC.executeBatch()`.

```dart
final results = await db.executeBatch([
  "INSERT INTO publishers (publishername, publisherid) VALUES (?, ?)",
  "INSERT INTO authors (authorname, authorid) VALUES (?, ?)",
  "INSERT INTO books (title, authorid, publisherid, bookid) VALUES (?, ?, ?, ?)",
], paramsList: [
  ["John Wiley", "pub-123"],
  ["J. R. R. Tolkien", "auth-456"],
  ["The Hobbit", "auth-456", "pub-123", "book-789"],
]);
// results[0] → last_insert_rowid for publisher
// results[1] → last_insert_rowid for author
// results[2] → last_insert_rowid for book
```

### Real-time Watch (gRPC Server-Streaming)

Clients can call the `Watch` RPC to subscribe to a SQL query. The server pushes
the initial result followed by incremental updates whenever any client (including
other users) executes a mutation on one of the watched tables. The feature is
exposed via `SqliteWrapperGRPC.watch()` — the same API as the local `watch()`,
but backed by a server-streaming gRPC call.

```dart
final stream = database.watch("SELECT * FROM todos",
    tables: ["todos"], fromMap: Todo.fromMap);
```

The server uses a `DatabasePool` that reference-counts connections per database
name. Watch subscriptions keep the connection alive; mutations from any RPC go
through the pool and trigger `updateStreams()` on all active streams, enabling
real-time cross-client updates.

## License

This project is licensed under MIT License.

---

For more details or contributions, please refer to our GitHub repository.
