/// Environment variables and shared app constants.

library;

import 'package:args/args.dart';

abstract class Constants {
  /// Listening Port of the server
  static late int serverPort;

  /// Secret used to generate JWT Keys
  static late String secretKey;

  // Calls are unauthenticated so there's no USERS DB
  static late bool runUnathenticated;

  /// Name of the database of authenticated users
  static late String usersDBName;

  /// Path to the authenticated users DB
  static late String usersDBPath;

  /// Path to where the application DB is stored
  static late String dbPath;

  /// If a DB is shared there will be only ONE DB for all the users
  /// otherwise every DB will be specific to a user
  static late bool sharedDB;

  static void parse(List<String> arguments) {
    final parser = ArgParser()
      ..addOption('port',
          help: 'Server listening port (50051 is the default)',
          defaultsTo: '50051')
      ..addOption('secret_key',
          help: 'Secret uset to generate JWT Key', defaultsTo: '')
      ..addOption('unauthenticated',
          help: 'Calls are unauthenticated so there\'s no USERS DB',
          defaultsTo: "false")
      ..addOption('users_db_name',
          help:
              'Name of the database of authenticated users  (users is default)',
          defaultsTo: "users")
      ..addOption('users_db_path',
          help: 'Path to the database of authenticated users  (./ is default)',
          defaultsTo: "./")
      ..addOption('db_path',
          help: 'Path where databases are stored (./ is default)',
          defaultsTo: "./")
      ..addOption('shared_db',
          help:
              'If a DB is shared there will be only ONE DB for all the users (default false)',
          defaultsTo: 'false');
    // Parse arguments
    ArgResults argResults;
    try {
      argResults = parser.parse(arguments);
    } catch (e) {
      print("Error: ${e.toString()}");
      print(parser.usage);
      return;
    }

    // Extract values
    serverPort = int.parse(argResults['port']);
    secretKey = argResults['secret_key'];
    runUnathenticated = argResults['unauthenticated'] == 'true';
    usersDBName = argResults['users_db_name'];
    usersDBPath = argResults['users_db_path'];
    dbPath = argResults['db_path'];
    sharedDB = argResults['shared_db'] == 'true';
  }
}
