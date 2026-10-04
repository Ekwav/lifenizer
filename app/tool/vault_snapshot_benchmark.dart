import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_index_worker_io.dart';
import 'package:app/services/vault_database_worker.dart';
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
