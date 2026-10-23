import 'dart:async';
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
  final pushes = <List<Map<String, dynamic>>>[];
  final envelopes = <Map<String, dynamic>>[];
  int pulls = 0;
  bool failPush = false;
  Completer<void>? pushStarted;
  Completer<void>? releasePush;

  Future<http.Response> handle(http.Request request) async {
    Object body;
    switch (request.url.path) {
      case '/api/auth/login':
        body = {
          'authToken': 'private-token',
          'userId': 'user',
          'vaultId': 'vault',
          'vaultSalt': 'stable-salt',
        };
      case '/api/imports/capabilities':
        body = [];
      case '/api/sync/push':
        final batch = (jsonDecode(request.body)['envelopes'] as List)
            .map((value) => Map<String, dynamic>.from(value as Map))
            .toList();
        pushes.add(batch);
        pushStarted?.complete();
        await releasePush?.future;
        if (failPush) throw http.ClientException('Push failed');
        for (final envelope in batch) {
          if (!envelopes.any((item) => item['id'] == envelope['id'])) {
            envelopes.add({
              ...envelope,
              'serverSequence': envelopes.length + 1,
            });
          }
        }
        body = {'cursor': envelopes.length};
      case '/api/sync/pull':
        pulls++;
        final since = int.parse(request.url.queryParameters['since']!);
        body = {
          'cursor': envelopes.length,
          'envelopes': envelopes
              .where((item) => (item['serverSequence'] as int) > since)
              .toList(),
        };
      default:
        return http.Response('not found', 404);
    }
    return http.Response(jsonEncode(body), 200);
  }
}

class _Fixture {
  _Fixture(this.disk);

  final LocalVaultStore disk;
  final server = _Server();
  DateTime now = DateTime.utc(2026, 10, 23);
  final devices = <LifenizerAppState>[];
  static final vaultKey =
      'vault:${jsonEncode(['https://vault.example.test', 'alice@example.test'])}';

  LifenizerAppState device() {
    final state = LifenizerAppState(
      localStore: disk,
      syncClock: () => now,
      apiFactory: (url) =>
          LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
    );
    devices.add(state);
    return state;
  }

  Future<void> login(LifenizerAppState state) async {
    await state.login(
      baseUrl: 'https://vault.example.test',
      email: 'alice@example.test',
      password: 'account password',
      passphrase: 'private vault phrase',
    );
    await state.waitForBackgroundSync();
    expect(state.error, isNull);
    expect(state.isAuthenticated, isTrue);
  }

  Future<Map<String, dynamic>> decrypt(
    LifenizerAppState state,
    Map<String, dynamic> encrypted,
  ) async {
    final crypto = VaultCrypto();
    crypto.unlockDeviceKey(base64Decode(await state.exportDeviceVaultKey()));
    try {
      return await crypto.decryptJson(
        cipherText: encrypted['cipherText'] as String,
        nonce: encrypted['nonce'] as String,
      );
    } finally {
      crypto.lock();
    }
  }

  Future<List<Map<String, dynamic>>> pending(LifenizerAppState state) async {
    final snapshot = await decrypt(state, (await disk.read(vaultKey))!);
    return (snapshot['pending'] as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
  }

  Future<void> close() async {
    for (final device in devices) {
      device.dispose();
    }
    await disk.close();
  }
}

void main() {
  var sequence = 0;
  late _Fixture fixture;
  late LifenizerAppState state;

  setUp(() async {
    fixture = _Fixture(
      LocalVaultStore(
        await databaseFactoryMemory.openDatabase('batching-${sequence++}'),
      ),
    );
    addTearDown(fixture.close);
    state = fixture.device();
    await fixture.login(state);
  });

  test(
    'rapid edits persist encrypted and upload together at 20 seconds',
    () async {
      await state.addManualText(
        title: 'Private note',
        participantNames: 'Alice, Bob',
        text: 'Private content',
      );
      expect(state.pendingSyncCount, 3);
      expect(fixture.server.pushes, isEmpty);
      final pending = await fixture.pending(state);
      expect(pending, hasLength(3));
      expect(
        pending.map((item) => item['clientCreatedAt']),
        everyElement(fixture.now.toIso8601String()),
      );
      final raw = jsonEncode(await fixture.disk.read(_Fixture.vaultKey));
      for (final secret in [
        'Private note',
        'Private content',
        'private-token',
      ]) {
        expect(raw, isNot(contains(secret)));
      }
      final pulls = fixture.server.pulls;
      await state.syncQuietly();
      fixture.now = fixture.now.add(const Duration(seconds: 19));
      await state.syncQuietly();
      expect(fixture.server.pushes, isEmpty);
      expect(fixture.server.pulls, greaterThan(pulls));
      fixture.now = fixture.now.add(const Duration(seconds: 1));
      await state.syncQuietly();
      expect(fixture.server.pushes, hasLength(1));
      expect(fixture.server.pushes.single, hasLength(3));
      expect(state.pendingSyncCount, 0);
      await state.syncQuietly();
      expect(fixture.server.pushes, hasLength(1));
    },
  );

  test(
    'latest edit coalesces with a fresh ID without starving the window',
    () async {
      final person = await state.ensureParticipantIdentity('Alice');
      final original = (await fixture.pending(state)).single;
      for (var i = 1; i <= 4; i++) {
        fixture.now = fixture.now.add(const Duration(seconds: 5));
        await state.ensureParticipantIdentity('Alice', aliases: ['Alias $i']);
        expect(state.pendingSyncCount, 1);
        await state.syncQuietly();
      }
      expect(fixture.server.pushes, hasLength(1));
      final envelope = fixture.server.pushes.single.single;
      expect(envelope['id'], isNot(original['id']));
      expect(envelope['entityId'], person.id);
      final payload = await fixture.decrypt(state, envelope);
      expect(payload['aliases'], containsAll(['Alias 1', 'Alias 4']));
      expect(state.pendingSyncCount, 0);
    },
  );

  test('manual sync uploads a new edit immediately', () async {
    await state.ensureParticipants('Alice');
    expect(fixture.server.pushes, isEmpty);
    await state.pullSync();
    expect(fixture.server.pushes, hasLength(1));
    expect(state.pendingSyncCount, 0);
  });

  test('login restores the persisted batching deadline', () async {
    await state.ensureParticipants('Alice');
    final original = (await fixture.pending(state)).single;
    await state.lock();
    state = fixture.device();
    await fixture.login(state);
    expect(state.pendingSyncCount, 1);
    expect(fixture.server.pushes, isEmpty);
    expect((await fixture.pending(state)).single, original);
    fixture.now = fixture.now.add(const Duration(seconds: 19));
    await state.syncQuietly();
    expect(fixture.server.pushes, isEmpty);
    await state.lock();
    fixture.now = fixture.now.add(const Duration(seconds: 1));
    state = fixture.device();
    await fixture.login(state);
    expect(fixture.server.pushes, hasLength(1));
    expect(fixture.server.pushes.single.single['id'], original['id']);
    expect(state.pendingSyncCount, 0);
  });

  test(
    'failed automatic pushes retain the queue and throttle retries',
    () async {
      await state.ensureParticipants('Alice');
      fixture.now = fixture.now.add(const Duration(seconds: 20));
      fixture.server.failPush = true;
      await state.syncQuietly();
      expect(fixture.server.pushes, hasLength(1));
      expect(state.pendingSyncCount, 1);
      expect(await fixture.pending(state), hasLength(1));
      expect(state.syncError, isNotNull);
      fixture.server.failPush = false;
      await state.syncQuietly();
      fixture.now = fixture.now.add(const Duration(seconds: 19));
      await state.syncQuietly();
      expect(fixture.server.pushes, hasLength(1));
      fixture.now = fixture.now.add(const Duration(seconds: 1));
      await state.syncQuietly();
      expect(fixture.server.pushes, hasLength(2));
      expect(fixture.server.pushes.last, fixture.server.pushes.first);
      expect(state.pendingSyncCount, 0);
      expect(state.syncError, isNull);
    },
  );

  test('inflight ACK preserves a later edit for the next batch', () async {
    await state.ensureParticipantIdentity('Alice');
    final original = (await fixture.pending(state)).single;
    fixture.now = fixture.now.add(const Duration(seconds: 20));
    fixture.server.pushStarted = Completer<void>();
    fixture.server.releasePush = Completer<void>();
    final sync = state.syncQuietly();
    await fixture.server.pushStarted!.future;
    try {
      await state.ensureParticipantIdentity('Alice', aliases: ['Latest alias']);
      final latest = (await fixture.pending(state)).single;
      expect(latest['id'], isNot(original['id']));
      expect(fixture.server.pushes.single.single['id'], original['id']);
    } finally {
      fixture.server.releasePush!.complete();
      await sync;
      fixture.server.pushStarted = null;
      fixture.server.releasePush = null;
    }
    expect(fixture.server.pushes, hasLength(1));
    expect(state.pendingSyncCount, 1);
    expect(state.participants.single.aliases, contains('Latest alias'));
    final latest = (await fixture.pending(state)).single;
    expect(latest['id'], isNot(original['id']));
    await state.syncQuietly();
    expect(fixture.server.pushes, hasLength(1));
    fixture.now = fixture.now.add(const Duration(seconds: 20));
    await state.syncQuietly();
    expect(fixture.server.pushes, hasLength(2));
    expect(fixture.server.pushes.last.single['id'], latest['id']);
    final payload = await fixture.decrypt(
      state,
      fixture.server.pushes.last.single,
    );
    expect(payload['aliases'], contains('Latest alias'));
    expect(state.pendingSyncCount, 0);
  });
}
