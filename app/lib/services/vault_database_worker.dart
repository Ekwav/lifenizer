import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sembast/sembast_io.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

typedef VaultDatabaseRequest =
    Future<Object?> Function(
      String operation,
      String? key,
      Map<String, dynamic>? value,
    );

/// One isolate owns the database for its lifetime. Only ciphertext and connection
/// settings cross this boundary. Sembast remains available for existing callers;
/// native startup uses SQLite and migrates the legacy file once, read-only.
Future<VaultDatabaseRequest> openVaultDatabaseWorker(
  String path, {
  bool useSqlite = false,
  String? legacyPath,
}) async {
  final responses = ReceivePort();
  final ready = Completer<SendPort>();
  // Opening may fail before Isolate.spawn's future completes.
  ready.future.ignore();
  final pending = <int, Completer<Object?>>{};
  var sequence = 0;
  var closed = false;
  Future<Object?>? closing;
  void fail(Object error) {
    closed = true;
    if (!ready.isCompleted) ready.completeError(error);
    for (final response in pending.values) {
      response.completeError(error);
    }
    pending.clear();
    responses.close();
  }

  responses.listen((message) {
    if (message is SendPort) {
      ready.complete(message);
    } else if (message is List && message.length == 3) {
      final response = pending.remove(message[0]);
      if (message[1] == true) {
        response?.complete(message[2]);
      } else {
        response?.completeError(StateError(message[2] as String));
      }
    } else {
      fail(StateError('The local vault database worker stopped.'));
    }
  });
  try {
    await Isolate.spawn(
      _serveVaultDatabase,
      (path, responses.sendPort, useSqlite, legacyPath),
      onError: responses.sendPort,
      onExit: responses.sendPort,
    );
  } catch (_) {
    responses.close();
    rethrow;
  }
  final commands = await ready.future;
  return (operation, key, value) async {
    if (closed) {
      if (operation == 'close') return closing;
      throw StateError('The local vault database is closed.');
    }
    if (operation == 'close') closed = true;
    final id = sequence++;
    final result = Completer<Object?>();
    if (operation == 'close') closing = result.future;
    pending[id] = result;
    commands.send([id, operation, key, value]);
    return result.future;
  };
}

Future<void> _serveVaultDatabase(
  (String, SendPort, bool, String?) setup,
) async {
  final (path, responses, useSqlite, legacyPath) = setup;
  if (useSqlite) {
    await _serveSqliteDatabase(path, legacyPath, responses);
    return;
  }
  final database = await databaseFactoryIo.openDatabase(path);
  final records = stringMapStoreFactory.store('vaults');
  final commands = ReceivePort();
  responses.send(commands.sendPort);
  try {
    await for (final message in commands) {
      final request = message as List;
      final id = request[0] as int;
      final operation = request[1] as String;
      try {
        Object? value;
        switch (operation) {
          case 'sqlitePath':
            value = null;
          case 'read':
            value = await records.record(request[2] as String).get(database);
          case 'write':
            await records
                .record(request[2] as String)
                .put(database, request[3] as Map<String, dynamic>);
            // Sembast swallows lazy append failures. Explicit compaction awaits
            // a complete file replacement and propagates filesystem failures.
            await database.compact();
          case 'writeMany':
            await database.transaction((transaction) async {
              for (final entry in (request[3] as Map).entries) {
                await records
                    .record(entry.key as String)
                    .put(transaction, Map<String, dynamic>.from(entry.value));
              }
            });
            await database.compact();
          case 'deleteMany':
            await database.transaction((transaction) async {
              for (final key in (request[3] as Map)['keys'] as List) {
                await records.record(key as String).delete(transaction);
              }
            });
            await database.compact();
          case 'close':
            await database.close();
          default:
            throw ArgumentError('Unknown local vault operation.');
        }
        responses.send([id, true, value]);
      } catch (error) {
        responses.send([id, false, error.toString()]);
      }
      if (operation == 'close') break;
    }
  } finally {
    commands.close();
    await database.close();
  }
}

void _sqliteTransaction(sql.Database database, void Function() operation) {
  database.execute('BEGIN IMMEDIATE');
  try {
    operation();
    database.execute('COMMIT');
  } catch (_) {
    database.execute('ROLLBACK');
    rethrow;
  }
}

Future<void> _serveSqliteDatabase(
  String path,
  String? legacyPath,
  SendPort responses,
) async {
  final database = sql.sqlite3.open(path);
  final commands = ReceivePort();
  try {
    database.execute(
      'CREATE TABLE IF NOT EXISTS vaults '
      '(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    if (database.select('PRAGMA user_version').single.values.single == 0) {
      final previous = legacyPath != null && await File(legacyPath).exists()
          ? await databaseFactoryIo.openDatabase(
              legacyPath,
              mode: DatabaseMode.readOnly,
            )
          : null;
      try {
        final records = previous == null
            ? null
            : await stringMapStoreFactory.store('vaults').find(previous);
        _sqliteTransaction(database, () {
          for (final record in records ?? []) {
            database.execute('INSERT INTO vaults (key, value) VALUES (?, ?)', [
              record.key,
              jsonEncode(record.value),
            ]);
          }
          // The marker commits with every migrated row. A failure leaves the
          // legacy file authoritative and allows another migration attempt.
          database.execute('PRAGMA user_version = 1');
        });
      } finally {
        await previous?.close();
      }
    }
    responses.send(commands.sendPort);
    await for (final message in commands) {
      final request = message as List;
      final id = request[0] as int;
      final operation = request[1] as String;
      try {
        Object? value;
        switch (operation) {
          case 'sqlitePath':
            value = path;
          case 'read':
            final rows = database.select(
              'SELECT value FROM vaults WHERE key = ?',
              [request[2] as String],
            );
            value = rows.isEmpty
                ? null
                : jsonDecode(rows.single['value'] as String);
          case 'write':
          case 'writeMany':
            final values = operation == 'write'
                ? {request[2] as String: request[3]}
                : request[3] as Map;
            _sqliteTransaction(database, () {
              for (final entry in values.entries) {
                database.execute(
                  'INSERT OR REPLACE INTO vaults (key, value) VALUES (?, ?)',
                  [entry.key as String, jsonEncode(entry.value)],
                );
              }
            });
          case 'deleteMany':
            _sqliteTransaction(database, () {
              for (final key in (request[3] as Map)['keys'] as List) {
                database.execute('DELETE FROM vaults WHERE key = ?', [
                  key as String,
                ]);
              }
            });
          case 'close':
            database.close();
          default:
            throw ArgumentError('Unknown local vault operation.');
        }
        responses.send([id, true, value]);
      } catch (error) {
        responses.send([id, false, error.toString()]);
      }
      if (operation == 'close') break;
    }
  } finally {
    commands.close();
    database.close();
  }
}
