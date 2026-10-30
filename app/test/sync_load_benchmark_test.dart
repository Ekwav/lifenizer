// Opt in: SYNC_LOAD_SIZES=1000,10000 flutter test
// test/sync_load_benchmark_test.dart --reporter expanded
// SYNC_LOAD_OUTPUT optionally writes the JSON result alongside stdout.
import 'dart:convert';
import 'dart:io';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/vault_chunk_file_store.dart';
import 'package:app/services/vault_database_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _salt = 'synthetic-sync-load-salt';
final _key = List<int>.generate(32, (i) => i);
final _date = DateTime.utc(2026, 10, 28);
final _words =
    ('We discussed the project schedule with Alice and Bob before '
            'planning dinner groceries travel weather music books software testing '
            'deployment meetings family exercise coffee garden budget research')
        .split(' ');
String _text(int i, int segment) => List.generate(
  25,
  (word) => _words[(i + segment * 25 + word) % _words.length],
).join(' ');

Conversation _conversation(int i, {String suffix = ''}) => Conversation(
  id: 'conversation-$i',
  title: 'Synthetic discussion $i$suffix',
  source: 'manual-text',
  participantIds: const [],
  startedAt: _date,
  endedAt: _date,
  segments: List.generate(
    8,
    (j) => ConversationSegment(
      id: 'message-$i-$j',
      text: _text(i, j),
      createdAt: _date,
    ),
  ),
);

// Transport only: same append-only sequence, idempotent IDs, 500-item pull
// limit and last-returned cursor as backend SyncEndpoints. No backend timing.
class _Server {
  final envelopes = <Map<String, dynamic>>[];
  final ids = <String>{};
  final pushSizes = <int>[];
  int pulls = 0, requestBytes = 0, responseBytes = 0;

  void append(Map<String, dynamic> envelope) {
    if (ids.add(envelope['id'] as String)) {
      envelopes.add({...envelope, 'serverSequence': envelopes.length + 1});
    }
  }

  Future<http.Response> handle(http.Request request) async {
    requestBytes += request.bodyBytes.length;
    Object body;
    switch (request.url.path) {
      case '/api/auth/login':
        body = {
          'authToken': 'synthetic-token',
          'userId': 'synthetic-user',
          'vaultId': 'synthetic-vault',
          'vaultSalt': _salt,
        };
      case '/api/imports/capabilities':
        body = [];
      case '/api/sync/push':
        final batch = jsonDecode(request.body)['envelopes'] as List;
        pushSizes.add(batch.length);
        for (final envelope in batch) {
          append(Map<String, dynamic>.from(envelope as Map));
        }
        body = {'cursor': envelopes.length};
      case '/api/sync/pull':
        pulls++;
        final since = int.parse(request.url.queryParameters['since']!);
        final items = envelopes.skip(since).take(500).toList();
        body = {
          'cursor': items.isEmpty ? since : items.last['serverSequence'],
          'envelopes': items,
        };
      default:
        throw StateError('Unexpected request: ${request.url}');
    }
    final bytes = utf8.encode(jsonEncode(body));
    responseBytes += bytes.length;
    return http.Response.bytes(bytes, 200);
  }
}

void main() {
  final sizes = Platform.environment['SYNC_LOAD_SIZES'];
  final results = <Map<String, Object?>>[];
  for (final count in (sizes ?? '1000,10000').split(',').map(int.parse)) {
    test(
      'encrypted sync load: $count conversations',
      () async {
        final directory = await Directory.systemTemp.createTemp('sync-load-');
        final server = _Server();
        final crypto = VaultCrypto()..unlockDeviceKey(_key);
        final store = LocalVaultStore.remote(
          await openVaultDatabaseWorker(
            '${directory.path}/vault.sqlite',
            useSqlite: true,
          ),
        );
        final devices = <LifenizerAppState>[];
        var now = _date;
        LifenizerAppState device() {
          final state = LifenizerAppState(
            localStore: store,
            chunkStore: FileVaultChunkStore('${directory.path}/chunks'),
            syncClock: () => now,
            apiFactory: (url) => LifenizerApiClient(
              baseUrl: url,
              client: MockClient(server.handle),
            ),
          );
          devices.add(state);
          return state;
        }

        Future<void> login(
          LifenizerAppState state, {
          bool offline = false,
        }) async {
          await state.login(
            baseUrl: 'https://synthetic.example.test',
            email: 'benchmark@example.test',
            password: 'synthetic-password',
            passphrase: 'synthetic-passphrase',
            deviceVaultKey: base64Encode(_key),
            deviceVaultSalt: _salt,
            offline: offline,
          );
          await state.waitForBackgroundSync();
          expect(state.error, isNull);
          expect(state.syncError, isNull);
        }

        Future<void> append(int i, {String suffix = ''}) async {
          final payload = await crypto.encryptJson(
            _conversation(i, suffix: suffix).toJson(),
          );
          server.append(
            SyncEnvelope(
              id: 'envelope-$i$suffix',
              deviceId: 'synthetic-remote',
              entityType: 'conversation',
              entityId: 'conversation-$i',
              operation: 'upsert',
              revision: suffix.isEmpty ? 1 : 2,
              cipherText: payload.cipherText,
              nonce: payload.nonce,
              keyId: payload.keyId,
              clientCreatedAt: _date,
            ).toJson(),
          );
        }

        Future<Map<String, Object?>> measure(
          String operation,
          Future<void> Function() action,
        ) async {
          final beforePulls = server.pulls;
          final beforePushes = server.pushSizes.length;
          final beforeRequest = server.requestBytes;
          final beforeResponse = server.responseBytes;
          final observed = devices.isEmpty ? null : devices.last;
          final fullBuilds = observed?.fullSearchBuilds ?? 0;
          final incrementalUpdates = observed?.incrementalSearchUpdates ?? 0;
          final stageMs = <String, double>{};
          final clock = Stopwatch()..start();
          var last = 0;
          var stage = observed?.syncProgress?.stage.name ?? 'idle';
          void changed() {
            final elapsed = clock.elapsedMicroseconds;
            stageMs.update(
              stage,
              (value) => value + (elapsed - last) / 1000,
              ifAbsent: () => (elapsed - last) / 1000,
            );
            last = elapsed;
            stage = observed?.syncProgress?.stage.name ?? 'idle';
          }

          observed?.addListener(changed);
          try {
            await action();
          } finally {
            changed();
            observed?.removeListener(changed);
          }
          final result = <String, Object?>{
            'conversations': count,
            'wordsPerConversation': 200,
            'operation': operation,
            'elapsedMs': clock.elapsedMicroseconds / 1000,
            'pullRequests': server.pulls - beforePulls,
            'pushBatches': server.pushSizes.skip(beforePushes).toList(),
            'requestBodyBytes': server.requestBytes - beforeRequest,
            'responseBodyBytes': server.responseBytes - beforeResponse,
            'processRssBytes': ProcessInfo.currentRss,
            'fullSearchBuilds': (observed?.fullSearchBuilds ?? 0) - fullBuilds,
            'incrementalSearchUpdates':
                (observed?.incrementalSearchUpdates ?? 0) - incrementalUpdates,
            'stageMs': stageMs,
          };
          results.add(result);
          // ignore: avoid_print
          print('SYNC_LOAD ${jsonEncode(result)}');
          return result;
        }

        Future<void> recordSize(String operation, int conversations) async {
          var bytes = 0;
          await for (final file in directory.list(recursive: true)) {
            if (file is File) bytes += await file.length();
          }
          results.add({
            'conversations': conversations,
            'operation': operation,
            'bytes': bytes,
          });
        }

        Future<void> verifySearch(LifenizerAppState state) async {
          final found = await state.searchAsync('${count - 1}', maxResults: 10);
          expect(found.map((c) => c.id), ['conversation-${count - 1}']);
        }

        try {
          await measure('seed-encrypted-server', () async {
            for (var i = 0; i < count; i++) {
              await append(i);
            }
          });
          var state = device();
          final initial = await measure(
            'initial-pull-and-persist',
            () => login(state),
          );
          expect(state.conversations, hasLength(count));
          expect(state.syncCursor, count);
          expect(initial['pullRequests'], count ~/ 500 + 1);
          await recordSize('initial-persisted-vault-size', count);
          await measure('search-after-initial-sync', () => verifySearch(state));
          for (var i = 0; i < 101; i++) {
            await append(i, suffix: ' updated');
          }
          final incremental = await measure(
            'incremental-101-updates',
            state.pullSync,
          );
          expect(incremental['pullRequests'], 1);
          expect(state.conversations, hasLength(count));
          for (var i = 0; i < 101; i++) {
            expect(
              state.conversations
                  .firstWhere((c) => c.id == 'conversation-$i')
                  .title,
              'Synthetic discussion $i updated',
            );
          }
          final idle = await measure('no-op-sync', state.pullSync);
          expect(idle['pullRequests'], 1);
          expect(idle['pushBatches'], isEmpty);
          await measure(
            'queue-601-conversations',
            () => state.batchVaultChanges(() async {
              for (var i = 0; i < 601; i++) {
                await state.addManualText(
                  title: 'Uploaded conversation $i',
                  participantNames: '',
                  text: List.generate(8, (j) => _text(i, j)).join(' '),
                );
              }
            }),
          );
          expect(state.pendingSyncCount, 601);
          final upload = await measure(
            'upload-601-and-pull-echo',
            state.pullSync,
          );
          expect(upload['pushBatches'], [100, 100, 100, 100, 100, 100, 1]);
          expect(upload['pullRequests'], 2);
          expect(state.pendingSyncCount, 0);
          expect(state.conversations, hasLength(count + 601));
          await recordSize('after-upload-persisted-vault-size', count + 601);
          await measure(
            'queue-100-edits-same-participant',
            () => state.batchVaultChanges(() async {
              for (var i = 0; i < 100; i++) {
                await state.ensureParticipantIdentity(
                  'Alice',
                  aliases: ['Alias $i'],
                );
              }
            }),
          );
          expect(state.pendingSyncCount, 1);
          final early = await measure(
            'automatic-sync-before-window',
            state.syncQuietly,
          );
          expect(early['pushBatches'], isEmpty);
          now = now.add(const Duration(seconds: 20));
          final coalesced = await measure(
            'automatic-sync-after-20-seconds',
            state.syncQuietly,
          );
          expect(coalesced['pushBatches'], [1]);
          expect(state.participants.single.aliases, hasLength(100));
          expect(state.pendingSyncCount, 0);
          await state.lock();
          state = device();
          await measure(
            'offline-unlock-persisted-vault',
            () => login(state, offline: true),
          );
          expect(state.conversations, hasLength(count + 601));
          expect(state.syncCursor, count + 703);
          expect(state.pendingSyncCount, 0);
          await measure(
            'search-after-offline-unlock',
            () => verifySearch(state),
          );
          final restored = await state.loadConversation('conversation-0');
          expect(restored.title, 'Synthetic discussion 0 updated');
          expect(
            restored.segments.map((s) => s.text).join(' ').split(' '),
            hasLength(200),
          );
          await recordSize('final-persisted-vault-size', count + 601);
        } finally {
          for (final state in devices) {
            state.dispose();
          }
          crypto.lock();
          await store.close();
          await directory.delete(recursive: true);
          final output = Platform.environment['SYNC_LOAD_OUTPUT'];
          if (output != null) {
            await File(output).writeAsString(
              '${const JsonEncoder.withIndent('  ').convert(results)}\n',
            );
          }
        }
      },
      skip: sizes == null ? 'Set SYNC_LOAD_SIZES to opt in.' : false,
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
