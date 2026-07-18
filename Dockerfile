# Stage 1: Build the Dart application
FROM dart:stable AS build

RUN apt-get update && \
    apt-get -y install libsqlite3-0 libsqlite3-dev

# Resolve app dependencies.
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get

# Copy app source code and AOT compile it.
COPY . .
# Ensure packages are still up-to-date if anything has changed
RUN dart pub get --offline

# Build the app using `dart build cli` (supports native-assets build hooks
# from sqlite3, which `dart compile exe` cannot handle).
RUN dart build cli -t bin/main.dart -o build/cli && \
    mv build/cli/bundle/bin/main build/cli/bundle/bin/server

# Identify required SQLite libraries
RUN find /usr/lib -name "libsqlite3.so*" | xargs -I{} cp {} /runtime/lib/

# Create an empty data dir
RUN mkdir /data

# Build minimal serving image from the CLI bundle and required system
# libraries and configuration files stored in `/runtime/` from the build stage.
FROM scratch
# The bundle already contains the binary + native assets (libsqlite3.so)
# at the correct relative paths.
COPY --from=build /app/build/cli/bundle /app
# System runtime libraries (libc, libm, ld-linux, etc.)
COPY --from=build /runtime/ /
# Shell for CMD variable expansion
COPY --from=build /bin/sh /bin/sh
# Empty data dir
COPY --from=build /data /data

# Start server.
EXPOSE 50051
CMD ["/bin/sh", "-c", "/app/bin/server --port \"${PORT:-50051}\" --secret_key \"$SECRET_KEY\" --unauthenticated \"${UNAUTHENTICATED:-false}\" --users_db_name \"${USERS_DB_NAME:-users}\" --users_db_path \"${USERS_DB_PATH:-/data}\" --db_name \"${DB_NAME:-}\" --db_path \"${DB_PATH:-/data}\" --shared_db \"${SHARED_DB:-false}\""]


