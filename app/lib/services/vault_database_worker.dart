import 'dart:async';
import 'dart:isolate';

import 'package:sembast/sembast_io.dart';

typedef VaultDatabaseRequest =
    Future<Object?> Function(
      String operation,
      String? key,
      Map<String, dynamic>? value,
    );

/// One isolate owns the database for its lifetime. Only ciphertext and connection
/// settings cross this boundary; the existing Sembast file format is unchanged.
Future<VaultDatabaseRequest> openVaultDatabaseWorker(String path) async {
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
      (path, responses.sendPort),
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

Future<void> _serveVaultDatabase((String, SendPort) setup) async {
  final (path, responses) = setup;
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
          case 'read':
            value = await records.record(request[2] as String).get(database);
          case 'write':
            await records
                .record(request[2] as String)
                .put(database, request[3] as Map<String, dynamic>);
            // Sembast swallows lazy append failures. Explicit compaction awaits
            // a complete file replacement and propagates filesystem failures.
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
