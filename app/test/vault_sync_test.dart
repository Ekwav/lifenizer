import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

class _Server {
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
        'authToken': 'private-token',
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
