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

# Build the app (release mode)
RUN dart compile exe bin/main.dart -o bin/server

# Identify required SQLite libraries
RUN find /usr/lib -name "libsqlite3.so*" | xargs -I{} cp {} /runtime/lib/

# Create an empty data dir
RUN mkdir /data

#DEBUG
#RUN /bin/sh

# Build minimal serving image from AOT-compiled `/server` and required system
# libraries and configuration files stored in `/runtime/` from the build stage.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/server /app/bin/
# Copy only the required SQLite libraries from the collected directory
COPY --from=build /runtime/lib /lib/
# Copy sh so we can expand the environment varianble
COPY --from=build /bin/sh /bin/sh
# Copy the empty data dir
COPY --from=build /data /data

# Start server.
EXPOSE 50051
CMD /bin/sh -c '/app/bin/server --port 50051 --secret_key "$SECRET_KEY" --unauthenticated "$UNAUTHENTICATED" --shared_db "$SHARED_DB" --users_db_path=/data --db_path=/data'


