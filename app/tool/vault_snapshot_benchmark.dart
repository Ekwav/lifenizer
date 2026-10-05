import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_index_worker_io.dart';
import 'package:app/services/vault_chunk_file_store.dart';
import 'package:app/services/vault_chunks.dart';
import 'package:app/services/vault_database_worker.dart';
import 'package:app/services/vault_worker_io.dart';
import 'package:sembast/sembast_io.dart';

Future<void> main(List<String> arguments) async {
  final messageCount = arguments.isEmpty ? 126281 : int.parse(arguments.first);
  final conversationCount = (messageCount / 12).ceil();
  final conversations = List.generate(
    conversationCount,
    (i) => Conversation(
      id: 'thread-$i',
      title: 'Archive thread $i',
      source: 'discord',
      participantIds: [],
      segments: List.generate(
        12,
        (j) => ConversationSegment(
          id: 'message-$i-$j',
          text:
              'An exported discussion about plans, groceries and deployment. ' *
              3,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      ),
    ),
  );
  final crypto = VaultCrypto();
  await crypto.unlock(
    email: 'benchmark@example.test',
    passphrase: 'Synthetic benchmark secret',
    vaultSalt: 'synthetic-salt',
  );
  final directory = await Directory.systemTemp.createTemp('vault-benchmark-');
  final backgroundStore = arguments.contains('--background-store');
  final db = backgroundStore
      ? null
      : await databaseFactoryIo.openDatabase('${directory.path}/vault.db');
  final worker = backgroundStore
      ? await openVaultDatabaseWorker('${directory.path}/vault.db')
      : null;
  final record = stringMapStoreFactory.store('vaults').record('snapshot');
  Future<Map<String, Object>> measured(
    String name,
    Future<void> Function() action,
  ) async {
    final clock = Stopwatch()..start();
    var last = 0;
    var maxGap = 0;
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final now = clock.elapsedMicroseconds;
      final gap = now - last;
      if (gap > maxGap) maxGap = gap;
      last = now;
      ticks++;
    });
    await action();
    final elapsed = clock.elapsedMicroseconds;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    timer.cancel();
    return {
      'operation': name,
      'elapsedMs': elapsed / 1000,
      'maxEventLoopGapMs': maxGap / 1000,
      'ticks': ticks,
    };
  }

  EncryptedPayload? payload;
  final metrics = <Map<String, Object>>[];
  metrics.add(
    await measured('serialize-and-encrypt', () async {
      payload = await crypto.encryptJson({
        'conversations': conversations,
      }, background: arguments.contains('--background'));
    }),
  );
  metrics.add(
    await measured('encrypted-database-write', () async {
      final value = {
        'cipherText': payload!.cipherText,
        'nonce': payload!.nonce,
      };
      if (worker != null) {
        await worker('write', 'snapshot', value);
      } else {
        await record.put(db!, value);
      }
    }),
  );
  if (arguments.contains('--startup')) {
    crypto.lock();
    metrics.add(
      await measured(
        'derive-vault-key',
        () => crypto.unlock(
          email: 'benchmark@example.test',
          passphrase: 'Synthetic benchmark secret',
          vaultSalt: 'synthetic-salt',
          background: arguments.contains('--background'),
        ),
      ),
    );
  }
  Map<String, dynamic>? restored;
  metrics.add(
    await measured('decrypt-and-parse', () async {
      restored = await crypto.decryptJson(
        cipherText: payload!.cipherText,
        nonce: payload!.nonce,
        background: arguments.contains('--background'),
      );
    }),
  );
  if (arguments.contains('--startup')) {
    late List<Conversation> models;
    metrics.add(
      await measured('restore-conversation-models', () async {
        models = (restored!['conversations'] as List)
            .map(
              (item) =>
                  Conversation.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList(growable: false);
      }),
    );
    metrics.add(
      await measured('prepare-search', () async {
        if (arguments.contains('--background')) {
          await prepareSearchIndex((models, const {}, const {}), (_) {});
        } else {
          ConversationSearchIndex.build(
            conversations: models,
            participantById: const {},
            relationTextByConversation: const {},
          );
        }
      }),
    );
  }
  if (arguments.contains('--startup')) {
    // Format v2: core record plus one encrypted chunk per bucket.
    final stores = stringMapStoreFactory.store('vaults');
    Future<Map<String, dynamic>?> read(String key) async {
      final value = worker != null
          ? await worker('read', key, null) as Map<String, dynamic>?
          : await stores.record(key).get(db!);
      return value == null ? null : Map<String, dynamic>.from(value);
    }

    Future<void> writeMany(Map<String, Map<String, dynamic>> values) async {
      if (worker != null) {
        await worker('writeMany', null, Map<String, dynamic>.of(values));
      } else {
        await db!.transaction((transaction) async {
          for (final entry in values.entries) {
            await stores.record(entry.key).put(transaction, entry.value);
          }
        });
      }
    }

    final background = arguments.contains('--background');
    final chunkCount = vaultChunkCountFor(conversations.length);
    final groups = List.generate(chunkCount, (_) => <Conversation>[]);
    for (final conversation in conversations) {
      groups[vaultChunkFor(conversation.id, chunkCount)].add(conversation);
    }
    final lanes = background ? vaultWorkerCount() : 1;
    Future<void> inLanes(int count, Future<void> Function(int) task) async {
      var next = 0;
      Future<void> lane() async {
        while (next < count) {
          await task(next++);
        }
      }

      await Future.wait([for (var i = 0; i < lanes; i++) lane()]);
    }

    final chunkPayloads = <EncryptedPayload?>[for (final _ in groups) null];
    metrics.add(
      await measured('v2-full-save-encrypt-chunks-parallel', () async {
        await inLanes(groups.length, (n) async {
          chunkPayloads[n] = await crypto.encryptJson({
            'conversations': groups[n],
          }, background: background);
        });
      }),
    );
    final corePayload = await crypto.encryptJson({
      'cursor': 1,
      'participants': const [],
    }, background: background);
    metrics.add(
      await measured('v2-full-save-database-write', () async {
        await writeMany({
          for (var n = 0; n < groups.length; n++)
            'chunk:$n': {
              'cipherText': chunkPayloads[n]!.cipherText,
              'nonce': chunkPayloads[n]!.nonce,
            },
          'core': {
            'cipherText': corePayload.cipherText,
            'nonce': corePayload.nonce,
          },
        });
      }),
    );
    final decodedChunks = List<Map<String, dynamic>?>.filled(
      groups.length,
      null,
    );
    metrics.add(
      await measured('v2-load-core-and-decrypt-chunks-parallel', () async {
        await read('core');
        await inLanes(groups.length, (n) async {
          final record = (await read('chunk:$n'))!;
          decodedChunks[n] = await crypto.decryptJson(
            cipherText: record['cipherText'] as String,
            nonce: record['nonce'] as String,
            background: background,
          );
        });
      }),
    );
    metrics.add(
      await measured('v2-restore-conversation-models', () async {
        var restored = 0;
        for (final chunk in decodedChunks) {
          for (final item in chunk!['conversations'] as List) {
            Conversation.fromJson(Map<String, dynamic>.from(item as Map));
            restored++;
          }
        }
        if (restored != conversations.length) throw StateError('lost data');
      }),
    );
    metrics.add(
      await measured('v2-partial-save-one-dirty-chunk', () async {
        final n = vaultChunkFor('thread-1', chunkCount);
        final chunk = await crypto.encryptJson({
          'conversations': groups[n],
        }, background: background);
        final core = await crypto.encryptJson({
          'cursor': 2,
          'participants': const [],
        }, background: background);
        await writeMany({
          'chunk:$n': {'cipherText': chunk.cipherText, 'nonce': chunk.nonce},
          'core': {'cipherText': core.cipherText, 'nonce': core.nonce},
        });
      }),
    );
  }
  if (arguments.contains('--startup')) {
    // Format v2 with chunk files: ciphertext outside the database, small core.
    final background = arguments.contains('--background');
    final chunkCount = vaultChunkCountFor(conversations.length);
    final groups = List.generate(chunkCount, (_) => <Conversation>[]);
    for (final conversation in conversations) {
      groups[vaultChunkFor(conversation.id, chunkCount)].add(conversation);
    }
    final files = FileVaultChunkStore('${directory.path}/chunks');
    final coreDb = '${directory.path}/core.db';
    final coreWorker = background
        ? await openVaultDatabaseWorker(coreDb)
        : null;
    final coreDirect = background
        ? null
        : await databaseFactoryIo.openDatabase(coreDb);
    final coreStore = stringMapStoreFactory.store('vaults');
    Future<void> writeCore(Map<String, dynamic> value) async {
      if (coreWorker != null) {
        await coreWorker('write', 'core', value);
      } else {
        await coreStore.record('core').put(coreDirect!, value);
      }
    }

    final lanes = background ? vaultWorkerCount() : 1;
    Future<void> inLanes(int count, Future<void> Function(int) task) async {
      var next = 0;
      Future<void> lane() async {
        while (next < count) {
          await task(next++);
        }
      }

      await Future.wait([for (var i = 0; i < lanes; i++) lane()]);
    }

    final payloads = <EncryptedPayload?>[for (final _ in groups) null];
    await inLanes(groups.length, (n) async {
      payloads[n] = await crypto.encryptJson({
        'conversations': groups[n],
      }, background: background);
    });
    final core = await crypto.encryptJson({
      'cursor': 1,
    }, background: background);
    metrics.add(
      await measured('v2-files-full-save-write', () async {
        await files.writeChunks('bench', {
          for (var n = 0; n < groups.length; n++)
            n: {
              'cipherText': payloads[n]!.cipherText,
              'nonce': payloads[n]!.nonce,
            },
        });
        await writeCore({'cipherText': core.cipherText, 'nonce': core.nonce});
      }),
    );
    var loaded = 0;
    metrics.add(
      await measured('v2-files-parallel-load-and-decrypt', () async {
        await inLanes(groups.length, (n) async {
          final decoded = await files.decryptChunk(
            crypto,
            'bench',
            n,
            payloads[n]!.nonce,
            background: background,
          );
          loaded += (decoded['conversations'] as List).length;
        });
      }),
    );
    if (loaded != conversations.length) throw StateError('lost data');
    metrics.add(
      await measured('v2-files-partial-save-one-dirty-chunk', () async {
        final n = vaultChunkFor('thread-1', chunkCount);
        final chunk = await crypto.encryptJson({
          'conversations': groups[n],
        }, background: background);
        final next = await crypto.encryptJson({
          'cursor': 2,
        }, background: background);
        await files.writeChunks('bench', {
          n: {'cipherText': chunk.cipherText, 'nonce': chunk.nonce},
        });
        await writeCore({'cipherText': next.cipherText, 'nonce': next.nonce});
      }),
    );
    metrics.add(
      await measured('v2-files-core-only-save', () async {
        final next = await crypto.encryptJson({
          'cursor': 3,
        }, background: background);
        await writeCore({'cipherText': next.cipherText, 'nonce': next.nonce});
      }),
    );
    if (coreWorker != null) {
      await coreWorker('close', null, null);
    } else {
      await coreDirect!.close();
    }
  }
  stdout.writeln(
    jsonEncode({
      'conversations': conversationCount,
      'messages': conversationCount * 12,
      'ciphertextBytes': payload!.cipherText.length,
      'metrics': metrics,
    }),
  );
  crypto.lock();
  if (worker != null) {
    await worker('close', null, null);
  } else {
    await db!.close();
  }
  await directory.delete(recursive: true);
}
