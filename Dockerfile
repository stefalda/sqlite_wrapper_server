# Stage 1: Build the Dart application
FROM dart:latest AS build

WORKDIR /app

# Copy pubspec files and install dependencies
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

# Copy the entire project to the working directory
COPY . .

# Build the app (release mode)
RUN dart compile exe bin/main.dart -o /app/sqlitewrapperserver

# Stage 2: Deploy in a minimal Alpine container
FROM alpine:latest AS deploy

WORKDIR /app

# Install necessary runtime dependencies for your application
# For example, if you need curl or any other packages:
RUN apk --no-cache add \
    libstdc++ \
    bash \
    coreutils

# Copy the compiled executable from the build stage
COPY --from=build /app/sqlitewrapperserver .

# Expose necessary ports (if your application uses HTTP/HTTPS, for example)
EXPOSE 50012

# Define entry point to run your Dart application
ENTRYPOINT ["./sqlitewrapperserver", "--define=SERVER_PORT=50012", "--define=SECRET_KEY=a1b2c33d4e5f6g7h8i9jakblc"]