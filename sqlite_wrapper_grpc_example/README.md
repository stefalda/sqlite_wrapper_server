# SQLite Wrapper GRPC Example - Flutter Todo App

This project showcases how to use a remote SQLite database with gRPC by
connecting to an instance of `sqlite_wrapper_server`. The client application,
written in Flutter, is a simple todo app that interacts with this server.

## Overview

This example demonstrates setting up and using gRPC for communication between
Flutter applications (clients) and servers managing SQLite databases remotely.
The project structure includes:

- **`sqlite_wrapper_grpc_example`:** This folder contains the Flutter client
  application.
- **Parent Folder (`sqlite_wrapper_server`):** Contains the server-side
  implementation.

## Setup

Before you begin, ensure you have the following prerequisites installed on your
system:

1. **Flutter SDK:** Ensure Flutter is installed and set up correctly.

## Running the Example

To run this example, follow these steps:

1. **Start the Server:**

   Navigate to the parent folder where `sqlite_wrapper_server` is located and
   start it following its instructions.

2. **Open a Terminal in Flutter Project Directory:**

3. **Get Dependencies:**

   Ensure you have all dependencies installed by running:

   ```bash
   flutter pub get
   ```

4. **Run the App on an Emulator or Device:**

   Make sure your emulator is running or connect a device, then execute:

   ```bash
   flutter run
   ```

## Application Overview

The Flutter app features a simple todo list interface allowing you to:

- **Add Todo Items:** Connect and send data to the remote SQLite server.
- **View Todos:** Retrieve and display todos from the server.
- **Delete Todos:** Remove items by sending requests through gRPC.

This example is ideal for understanding how Flutter applications can leverage
gRPC to communicate with servers managing databases remotely. It provides a
foundation for building more complex applications requiring similar
architecture.
