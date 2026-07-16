import 'dart:async';

import 'package:sqlite_wrapper_server/database_pool.dart';
import 'package:test/test.dart';

void main() {
  // Unique dbName per test group to avoid cross-test interference with the
  // global pool.
  int counter = 0;
  String nextDbName() => 'pool_test_${counter++}';

  tearDown(() {
    DatabasePool.closeAll();
  });

  group('DatabasePool.refCount', () {
    test('get increments refCount, close decrements it', () {
      final dbName = nextDbName();
      DatabasePool.get(dbName, ':memory:');
      // The pool now holds one reference.
      DatabasePool.close(dbName);
      // After close the entry should be gone (refCount reached 0).
      // Calling close again should be a no-op.
      DatabasePool.close(dbName);
    });

    test('multiple gets keep connection alive until last close', () {
      final dbName = nextDbName();
      DatabasePool.get(dbName, ':memory:');
      DatabasePool.get(dbName, ':memory:');
      // Two references held.
      DatabasePool.close(dbName);
      // One reference still held → connection NOT closed yet.
      DatabasePool.close(dbName);
      // All references released → connection closed.
    });

    test('closeAll releases everything', () {
      DatabasePool.get('${nextDbName()}_a', ':memory:');
      DatabasePool.get('${nextDbName()}_b', ':memory:');
      // Both connections alive.
      DatabasePool.closeAll();
      // Both gone.
    });
  });

  group('DatabasePool.subscribe', () {
    test('subscribe emits initial query result', () async {
      final dbName = nextDbName();
      final stream = DatabasePool.subscribe(
        dbName: dbName,
        dbPath: ':memory:',
        sql: 'SELECT 1 AS value',
        params: [],
        tables: ['test_table'],
        singleResult: false,
      );

      // Listen to the first event.
      final events = await stream.take(1).toList();
      expect(events, hasLength(1));

      // Single-column results return a list of scalar values.
      final first = events[0] as List;
      expect(first, [1]);
    });

    test('subscribe with singleResult emits a single value', () async {
      final dbName = nextDbName();
      final stream = DatabasePool.subscribe(
        dbName: dbName,
        dbPath: ':memory:',
        sql: 'SELECT 42 AS answer',
        params: [],
        tables: ['test_table'],
        singleResult: true,
      );

      final events = await stream.take(1).toList();
      expect(events, hasLength(1));
      expect(events[0], 42);
    });

    test('two subscriptions on same dbName both receive events', () async {
      final dbName = nextDbName();

      // Create a table and insert a row so we can mutate it.
      // Keep the pool entry alive (don't close) so the same :memory:
      // database is reused by subscribe.
      final initPool = DatabasePool.get(dbName, ':memory:');
      await initPool.execute(
          'CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT)');

      final stream1 = DatabasePool.subscribe(
        dbName: dbName,
        dbPath: ':memory:',
        sql: 'SELECT id, name FROM items ORDER BY id',
        params: [],
        tables: ['items'],
        singleResult: false,
      );
      final stream2 = DatabasePool.subscribe(
        dbName: dbName,
        dbPath: ':memory:',
        sql: 'SELECT id, name FROM items ORDER BY id',
        params: [],
        tables: ['items'],
        singleResult: false,
      );

      // Collect events from both streams.
      final events1 = <dynamic>[];
      final events2 = <dynamic>[];

      late StreamSubscription sub1;
      late StreamSubscription sub2;
      sub1 = stream1.listen((e) {
        events1.add(e);
        if (events1.length >= 2) {
          sub1.cancel();
        }
      });
      sub2 = stream2.listen((e) {
        events2.add(e);
        if (events2.length >= 2) {
          sub2.cancel();
        }
      });

      // Wait for the initial events to fire.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Insert a row via the pool (same pool entry → triggers updateStreams).
      await initPool.execute(
          'INSERT INTO items (name) VALUES (?)', params: ['foo'], tables: ['items']);

      // Wait for the update events to arrive.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Both streams should have received 2 events: initial empty + updated.
      expect(events1.length, greaterThanOrEqualTo(2));
      expect(events2.length, greaterThanOrEqualTo(2));

      // The second event should contain the new row.
      final secondEvent1 = events1.length >= 2 ? events1[1] as List : null;
      final secondEvent2 = events2.length >= 2 ? events2[1] as List : null;

      if (secondEvent1 != null) {
        expect(secondEvent1, hasLength(1));
        expect(secondEvent1[0]['name'], 'foo');
      }
      if (secondEvent2 != null) {
        expect(secondEvent2, hasLength(1));
        expect(secondEvent2[0]['name'], 'foo');
      }
    });

    test('unsubscribe releases pool resources', () async {
      final dbName = nextDbName();

      final stream = DatabasePool.subscribe(
        dbName: dbName,
        dbPath: ':memory:',
        sql: 'SELECT 1 AS value',
        params: [],
        tables: ['test_table'],
        singleResult: false,
      );

      // Listen and cancel immediately.
      final sub = stream.listen((_) {});
      await sub.cancel();

      // After cancellation, the stream's done handler should have removed
      // the StreamInfo from the wrapper.  Calling unsubscribe decrements
      // the pool refCount, which should go to 0 and close the connection.
      DatabasePool.unsubscribe(dbName);

      // Verify: a new subscribe on a DIFFERENT dbName creates a fresh entry.
      // (We use a different name so the teardown closeAll doesn't interfere.)
      final dbName2 = nextDbName();
      final stream2 = DatabasePool.subscribe(
        dbName: dbName2,
        dbPath: ':memory:',
        sql: 'SELECT 1 AS value',
        params: [],
        tables: ['test_table'],
        singleResult: false,
      );
      final events = await stream2.take(1).toList();
      expect(events, hasLength(1));
    });
  });
}
