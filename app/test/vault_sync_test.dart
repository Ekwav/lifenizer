import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/sync_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

class _Server {
  String authToken = 'private-token';
  final envelopes = <Map<String, dynamic>>[];
  final requests = <http.Request>[];
  bool offline = false;
  bool losePushResponse = false;
  int pulls = 0;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (offline) throw http.ClientException('Offline');
    final path = request.url.path;
    Object body;
    if (path.startsWith('/api/auth/')) {
      body = {
        'authToken': authToken,
        'userId': 'user',
        'vaultId': 'vault',
        'vaultSalt': 'stable-salt',
      };
    } else if (path == '/api/imports/capabilities') {
      body = [];
    } else if (path == '/api/sync/push') {
      for (final raw in jsonDecode(request.body)['envelopes'] as List) {
        final value = Map<String, dynamic>.from(raw);
        if (!envelopes.any((e) => e['id'] == value['id'])) {
          envelopes.add({...value, 'serverSequence': envelopes.length + 1});
        }
      }
      if (losePushResponse) throw http.ClientException('Response lost');
      body = {'cursor': envelopes.length};
    } else if (path == '/api/sync/pull') {
      pulls++;
      final since = int.parse(request.url.queryParameters['since']!);
      final items = envelopes
          .where((e) => (e['serverSequence'] as int) > since)
          .take(500)
          .toList();
      body = {
        'cursor': items.isEmpty ? since : items.last['serverSequence'],
        'envelopes': items,
      };
    } else {
      return http.Response('not found', 404);
    }
    return http.Response(jsonEncode(body), 200);
  }
}

void main() {
  var counter = 0;
  Future<LocalVaultStore> store() async => LocalVaultStore(
    await databaseFactoryMemory.openDatabase('sync-${counter++}'),
  );
  LifenizerAppState device(_Server server, LocalVaultStore store) =>
      LifenizerAppState(
        localStore: store,
        apiFactory: (url) =>
            LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
      );
  Future<void> login(
    LifenizerAppState state, {
    bool offline = false,
    String phrase = 'private vault phrase',
  }) => state.login(
    baseUrl: 'https://vault.example.test',
    email: 'alice@example.test',
    password: 'account password',
    passphrase: phrase,
    offline: offline,
  );

  test(
    'idle cached login keeps ciphertext unchanged and renews the offline session with an encrypted sidecar',
    () async {
      final server = _Server();
      final disk = await store();
      addTearDown(disk.close);
      final initial = device(server, disk);
      addTearDown(initial.dispose);
      await login(initial);
      await initial.addManualText(
        title: 'Saved note',
        participantNames: '',
        text: 'Retain this content',
      );
      await initial.lock();
      final key =
          'vault:${jsonEncode(['https://vault.example.test', 'alice@example.test'])}';
      final before = (await disk.read(key))!;
      server.authToken = 'fresh-private-session';
      final renewed = device(server, disk);
      addTearDown(renewed.dispose);
      final stages = <SyncStage>[];
      renewed.addListener(() {
        if (renewed.syncProgress case final value?) stages.add(value.stage);
      });
      await login(renewed);
      expect(renewed.error, isNull);
      expect(await disk.read(key), before);
      expect(
        stages,
        containsAll([
          SyncStage.readingLocal,
          SyncStage.derivingKey,
          SyncStage.decryptingLocal,
          SyncStage.restoring,
          SyncStage.indexing,
        ]),
      );
      final sidecar = (await disk.read('$key:session'))!;
      expect(sidecar['snapshotNonce'], before['nonce']);
      expect(jsonEncode(sidecar), isNot(contains('fresh-private-session')));
      server.offline = true;
      final offline = device(server, disk);
      addTearDown(offline.dispose);
      await login(offline, offline: true);
      expect(offline.error, isNull);
      expect(offline.session!.authToken, 'fresh-private-session');
      expect(
        offline.conversations.single.segments.single.text,
        'Retain this content',
      );
      expect(await disk.read(key), before);

      await disk.write('$key:session', {
        ...sidecar,
        'cipherText': 'corrupted optional session',
      });
      final fallback = device(server, disk);
      addTearDown(fallback.dispose);
      await login(fallback, offline: true);
      expect(fallback.error, isNull);
      expect(fallback.session!.authToken, 'private-token');
      expect(
        fallback.conversations.single.segments.single.text,
        'Retain this content',
      );
      await disk.write('$key:session', sidecar);

      await renewed.updatePairedSession(
        AuthSession(
          authToken: 'newest-private-session',
          userId: renewed.session!.userId,
          vaultId: renewed.session!.vaultId,
          vaultSalt: renewed.session!.vaultSalt,
        ),
      );
      expect((await disk.read(key))!['nonce'], isNot(sidecar['snapshotNonce']));
      final latest = device(server, disk);
      addTearDown(latest.dispose);
      await login(latest, offline: true);
      expect(latest.error, isNull);
      expect(latest.session!.authToken, 'newest-private-session');
    },
  );

  test(
    'cached restore yields between message chunks and persists genuine participant repairs',
    () async {
      final server = _Server();
      final disk = await store();
      addTearDown(disk.close);
      final crypto = VaultCrypto();
      addTearDown(crypto.lock);
      await crypto.unlock(
        email: 'alice@example.test',
        passphrase: 'private vault phrase',
        vaultSalt: 'stable-salt',
      );
      final time = DateTime.utc(2026, 10, 4);
      final conversation = Conversation(
        id: 'cached-thread',
        title: 'Archived messages',
        source: 'discord',
        participantIds: ['old-person'],
        sourceThreadId: 'discord:123',
        sourceUrl: 'https://discord.com/channels/1/123',
        metadata: {'channel': 'Archive'},
        tags: ['archive'],
        artifactNames: ['attachment.pdf'],
        isFavorite: true,
        importFingerprint: 'receipt',
        startedAt: time,
        endedAt: time,
        segments: List.generate(
          2000,
          (index) => ConversationSegment(
            id: 'message-$index',
            text: 'Archived message $index',
            sourceMessageId: '$index',
            participantId: 'old-person',
            createdAt: time,
            offsetMs: index,
            attachmentUrls: ['https://example.test/file-$index.pdf'],
          ),
        ),
      );
      final payload = await crypto.encryptJson({
        'session': {
          'authToken': 'private-token',
          'userId': 'user',
          'vaultId': 'vault',
          'vaultSalt': 'stable-salt',
        },
        'cursor': 0,
        'participants': [
          Participant(
            id: 'old-person',
            displayName: 'Old identity',
            mergedInto: 'person',
          ).toJson(),
          Participant(id: 'person', displayName: 'Connected person').toJson(),
        ],
        'conversations': [conversation.toJson()],
        'relations': [],
        'savedSearches': [],
        'pending': [],
      });
      final key =
          'vault:${jsonEncode(['https://vault.example.test', 'alice@example.test'])}';
      await disk.write(key, {
        'vaultSalt': 'stable-salt',
        'cipherText': payload.cipherText,
        'nonce': payload.nonce,
      });
      final state = device(server, disk);
      addTearDown(state.dispose);
      final counts = <int>[];
      int? conversationsAtFirstYield;
      var observedYield = false;
      state.addListener(() {
        if (state.syncProgress case final value?) {
          if (value.stage == SyncStage.restoring && value.total == 2000) {
            counts.add(value.completed);
          }
          if (value.stage == SyncStage.restoring &&
              value.total == 2000 &&
              !observedYield) {
            observedYield = true;
            unawaited(
              Future<void>.delayed(Duration.zero, () {
                conversationsAtFirstYield = state.conversations.length;
              }),
            );
          }
        }
      });
      await login(state, offline: true);
      expect(state.error, isNull);
      expect(counts, containsAll([0, 2000]));
      expect(
        conversationsAtFirstYield,
        0,
        reason:
            'The event loop must run before the single large conversation is fully restored.',
      );
      final restored = state.conversations.single;
      expect(restored.segments, hasLength(2000));
      expect(restored.participantIds, ['person']);
      expect(restored.segments.last.participantId, 'person');
      expect(
        restored.segments.last.attachmentUrls,
        conversation.segments.last.attachmentUrls,
      );
      expect(restored.segments.last.offsetMs, 1999);
      expect(restored.metadata, conversation.metadata);
      expect(restored.sourceUrl, conversation.sourceUrl);
      expect(restored.isFavorite, isTrue);
      expect(restored.importFingerprint, conversation.importFingerprint);
      final persisted = (await disk.read(key))!;
      expect(persisted['nonce'], isNot(payload.nonce));
      final saved = await crypto.decryptJson(
        cipherText: persisted['cipherText'] as String,
        nonce: persisted['nonce'] as String,
      );
      expect((saved['conversations'] as List).single['participantIds'], [
        'person',
      ]);
    },
  );

  test(
    'initial sync exposes stages and counts, retries failure, and clears on lock',
    () async {
      final server = _Server();
      final sourceDisk = await store();
      final targetDisk = await store();
      addTearDown(sourceDisk.close);
      addTearDown(targetDisk.close);
      final source = device(server, sourceDisk);
      final target = device(server, targetDisk);
      addTearDown(source.dispose);
      addTearDown(target.dispose);
      await login(source);
      await source.addManualText(
        title: 'Remote note',
        participantNames: '',
        text: 'encrypted content',
      );
      final stages = <SyncStage>[];
      target.addListener(() {
        if (target.syncProgress case final value?) {
          stages.add(value.stage);
        }
      });
      await login(target);
      expect(target.error, isNull);
      expect(
        stages,
        containsAll([
          SyncStage.downloading,
          SyncStage.decrypting,
          SyncStage.applying,
          SyncStage.saving,
          SyncStage.indexing,
          SyncStage.complete,
        ]),
      );
      expect(target.syncProgress!.downloaded, server.envelopes.length);
      expect(target.syncProgress!.active, isFalse);
      server.offline = true;
      await target.syncQuietly();
      expect(target.syncProgress!.stage, SyncStage.failed);
      expect(target.syncProgress!.active, isFalse);
      expect(target.syncError, isNotNull);
      server.offline = false;
      await target.pullSync();
      expect(target.syncProgress!.stage, SyncStage.complete);
      expect(target.syncError, isNull);
      await target.lock();
      expect(target.syncProgress, isNull);
    },
  );

  test(
    'registration forwards an invitation without persisting it in the vault or settings',
    () async {
      final server = _Server();
      final disk = await store();
      final state = device(server, disk);
      const invitation = 'synthetic-unique-invitation';
      await state.login(
        baseUrl: 'https://vault.example.test',
        email: 'alice@example.test',
        password: 'account password',
        passphrase: 'private vault phrase',
        register: true,
        registrationToken: invitation,
      );
      expect(state.error, isNull);
      final request = server.requests.singleWhere(
        (r) => r.url.path == '/api/auth/register',
      );
      expect(jsonDecode(request.body)['registrationToken'], invitation);
      final encrypted = (await disk.read(
        'vault:${jsonEncode(['https://vault.example.test', 'alice@example.test'])}',
      ))!;
      final crypto = VaultCrypto();
      await crypto.unlock(
        email: 'alice@example.test',
        passphrase: 'private vault phrase',
        vaultSalt: 'stable-salt',
      );
      final snapshot = await crypto.decryptJson(
        cipherText: encrypted['cipherText'] as String,
        nonce: encrypted['nonce'] as String,
      );
      expect(jsonEncode(snapshot), isNot(contains(invitation)));
      expect(
        jsonEncode(await disk.read('settings')),
        isNot(contains(invitation)),
      );
      crypto.lock();
      await state.lock();
      await disk.close();
    },
  );

  test('push cannot skip unseen writes by another device', () async {
    final server = _Server();
    final first = device(server, await store());
    final second = device(server, await store());
    await login(first);
    await login(second);
    await second.addManualText(
      title: 'Remote',
      participantNames: '',
      text: 'Remote conversation',
    );
    await first.addManualText(
      title: 'Local',
      participantNames: '',
      text: 'Local conversation',
    );
    expect(
      first.conversations.map((e) => e.title),
      containsAll(['Local', 'Remote']),
    );
    await second.pullSync();
    expect(
      second.conversations.map((e) => e.title),
      containsAll(['Local', 'Remote']),
    );
    expect(first.syncCursor, server.envelopes.length);
  });

  test(
    'idle polling leaves the encrypted snapshot untouched but saves new remote data',
    () async {
      final server = _Server();
      final disk = await store();
      addTearDown(disk.close);
      final state = device(server, disk);
      addTearDown(state.dispose);
      await login(state);
      final key =
          'vault:${jsonEncode(['https://vault.example.test', 'alice@example.test'])}';
      final before = await disk.read(key);
      await state.syncQuietly();
      await state.pullSync();
      expect(await disk.read(key), before);
      final otherDisk = await store();
      addTearDown(otherDisk.close);
      final other = device(server, otherDisk);
      addTearDown(other.dispose);
      await login(other);
      await other.addManualText(
        title: 'New remote item',
        participantNames: '',
        text: 'Remote update',
      );
      await state.syncQuietly();
      expect(await disk.read(key), isNot(before));
      final restored = device(server, disk);
      addTearDown(restored.dispose);
      await login(restored, offline: true);
      expect(restored.conversations.single.title, 'New remote item');
    },
  );

  test('bulk edits use bounded pushes and survive offline restart', () async {
    final server = _Server();
    final disk = await store();
    var state = device(server, disk);
    await login(state);
    server.offline = true;
    await state.batchVaultChanges(() async {
      for (var i = 0; i < 205; i++) {
        await state.ensureParticipants('Person $i');
      }
      expect(server.envelopes, isEmpty);
    });
    expect(state.pendingSyncCount, 205);
    await state.lock();
    state.dispose();
    state = device(server, disk);
    await login(state, offline: true);
    expect(state.participants, hasLength(205));
    expect(state.pendingSyncCount, 205);
    server.offline = false;
    server.requests.clear();
    await state.pullSync();
    expect(state.error, isNull);
    expect(state.pendingSyncCount, 0);
    final pushes = server.requests.where((r) => r.url.path == '/api/sync/push');
    expect(
      pushes.map((r) => (jsonDecode(r.body)['envelopes'] as List).length),
      [100, 100, 5],
    );
    expect(server.envelopes, hasLength(205));
    expect(jsonEncode(server.envelopes), isNot(contains('Person 204')));
    await state.lock();
    state.dispose();
    await disk.close();
  });

  test('nested import failure still saves completed edits', () async {
    final server = _Server();
    final disk = await store();
    final state = device(server, disk);
    await login(state);
    await expectLater(
      state.batchVaultChanges(() async {
        await state.batchVaultChanges(
          () => state.ensureParticipants('Preserved'),
        );
        throw const FormatException('Damaged next archive entry');
      }),
      throwsFormatException,
    );
    expect(server.envelopes, hasLength(1));
    expect(state.pendingSyncCount, 0);
    await state.lock();
    await login(state, offline: true);
    expect(state.participants.single.displayName, 'Preserved');
    await state.lock();
    state.dispose();
    await disk.close();
  });

  test(
    'offline outbox survives restart encrypted; lost push responses retry once',
    () async {
      final server = _Server();
      final disk = await store();
      var state = device(server, disk);
      await login(state);
      server.offline = true;
      await state.addManualText(
        title: 'Secret meeting',
        participantNames: '',
        text: 'Cobalt pineapple',
      );
      expect(state.pendingSyncCount, 1);
      final raw = jsonEncode(
        await disk.read(
          'vault:${jsonEncode(['https://vault.example.test', 'alice@example.test'])}',
        ),
      );
      for (final secret in [
        'Secret meeting',
        'Cobalt pineapple',
        'private-token',
        'private vault phrase',
        'account password',
      ]) {
        expect(raw, isNot(contains(secret)));
      }
      await state.lock();
      expect(state.search('pineapple'), isEmpty);
      expect(state.session, isNull);
      state = device(server, disk);
      await login(state, offline: true);
      expect(state.isAuthenticated, isTrue);
      expect(state.search('pineapple').single.title, 'Secret meeting');
      expect(state.pendingSyncCount, 1);
      server.offline = false;
      server.losePushResponse = true;
      await state.syncQuietly();
      expect(state.pendingSyncCount, 1);
      expect(server.envelopes, hasLength(1));
      server.losePushResponse = false;
      await state.syncQuietly();
      expect(state.pendingSyncCount, 0);
      expect(server.envelopes, hasLength(1));
    },
  );

  test(
    'wrong passphrase keeps vault locked and preserves the local snapshot',
    () async {
      final server = _Server();
      final disk = await store();
      final state = device(server, disk);
      await login(state);
      await state.addManualText(
        title: 'Original',
        participantNames: '',
        text: 'preserve me',
      );
      await state.lock();
      await login(state, phrase: 'wrong phrase');
      expect(state.error, isNotNull);
      expect(state.isAuthenticated, isFalse);
      expect(state.conversations, isEmpty);
      await login(state, offline: true);
      expect(state.search('preserve').single.title, 'Original');
      expect(
        server.requests
            .where((r) => r.url.path.startsWith('/api/auth/'))
            .map((r) => r.body)
            .join(),
        isNot(contains('private vault phrase')),
      );
    },
  );

  test(
    'pull drains pages and microphone draft survives offline unlock',
    () async {
      final server = _Server();
      final disk = await store();
      final state = device(server, disk);
      await login(state);
      await state.addManualText(
        title: 'Paged',
        participantNames: '',
        text: 'archive',
      );
      final source = server.envelopes.single;
      for (var i = 1; i < 501; i++) {
        server.envelopes.add({
          ...source,
          'id': 'envelope-$i',
          'serverSequence': i + 1,
        });
      }
      final other = device(server, await store());
      final before = server.pulls;
      await login(other);
      expect(other.syncCursor, 501);
      expect(server.pulls - before, 2);
      await state.saveAudioDraft([1, 2, 3], DateTime.utc(2026, 10, 3));
      await state.lock();
      await login(state, offline: true);
      expect(state.audioDraft?['payload'], base64Encode([1, 2, 3]));
      await state.discardAudioDraft();
      await state.lock();
      await login(state, offline: true);
      expect(state.audioDraft, isNull);
    },
  );
}
