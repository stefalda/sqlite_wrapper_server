# SQLiteWrapperServer

SQLiteWrapperServer is a Dart-based server designed for remote access to SQLite
databases using gRPC. This project supports applications with local-first
architecture (iOS, Android, Desktop) by enabling web support through remote
database storage.

## Features

- **Remote Database Access:** Utilizes the `sqlite_wrapper` package for seamless
  interaction with SQLite databases over a network.
- **User Authentication:** Supports user registration and authentication using
  email and password. Each authenticated user is assigned a unique UUID.
- **Database Management:** Users have their own databases, named by combining
  the provided `dbName` with their unique UUID.
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

Configure the server using environment variables or command line arguments. Key
configuration options include:

| Variable             | Description                                  | Default Value |
| -------------------- | -------------------------------------------- | ------------- |
| `SERVER_PORT`        | Listening port of the server                 | 50051         |
| `SECRET_KEY`         | Secret used to generate JWT keys             |               |
| `RUN_UNATHENTICATED` | Allows unauthenticated access                | false         |
| `USERS_DB_NAME`      | Name of the database for authenticated users | users         |
| `USERS_DB_PATH`      | Path to the authenticated users DB           | ./            |
| `DB_PATH`            | Path where application databases are stored  | ./            |
| `SHARED_DB`          | If true, a single shared database is used    | false         |

### Running the Server

Start the server with custom configurations:

```bash
dart bin/main.dart --define=SERVER_PORT=50012 \
                   --define=RUN_UNATHENTICATED=false \
                   --define=SECRET_KEY=a1b2c33d4e5f6g7h8i9jakblc
```

### VSCode Launch Configuration

Configure the server in VSCode by editing `launch.json`:

```json
{
    "name": "Dart",
    "type": "dart",
    "request": "launch",
    "program": "bin/main.dart",
    "toolArgs": [
        "--define=SERVER_PORT=50012",
        "--define=RUN_UNATHENTICATED=false",
        "--define=SECRET_KEY=a1b2c33d4e5f6g7h8i9jakblc"
    ]
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
version: "3.8"

services:
    sqlitewrapperserver:
        build: .
        ports:
            - "50012"
        environment:
            SERVER_PORT: "50012"

    envoy:
        image: envoyproxy/envoy:v1.31-latest
        volumes:
            - ./envoy.yaml:/etc/envoy/envoy.yaml
        ports:
            - "8080:8080"
```

### Deployment

Build and run the Docker containers:

```bash
docker-compose up --build
```

## Usage

### User Registration and Authentication

Users must provide an email and password upon first connection to generate a
unique UUID, stored in the local users database.

### Database Access

Authenticated users have their own SQLite databases named by combining `dbName`
with their assigned UUID.

## License

This project is licensed under MIT License.

---

For more details or contributions, please refer to our GitHub repository.
