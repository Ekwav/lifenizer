import 'dart:async';
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

const _url = 'https://native-participant.test';
const _email = 'person@example.test';
const _salt = 'synthetic-participant-salt';
final _vaultKey = 'vault:${jsonEncode([_url, _email])}';
final _key = List<int>.generate(32, (i) => i);
final _date = DateTime.utc(2026, 10, 28);

class _Server {
  final crypto = VaultCrypto()..unlockDeviceKey(_key);
  final envelopes = <Map<String, dynamic>>[];
  final pushed = <Map<String, dynamic>>[];
  bool offline = false;

  Future<void> append(String type, Map<String, dynamic> json) async {
    final sealed = await crypto.encryptJson(json);
    _append(
      SyncEnvelope(
        id: 'remote-${envelopes.length}',
        deviceId: 'remote-device',
        entityType: type,
        entityId: json['id'] as String,
        operation: 'upsert',
        revision: envelopes.length + 1,
        cipherText: sealed.cipherText,
        nonce: sealed.nonce,
        keyId: sealed.keyId,
        clientCreatedAt: _date,
      ).toJson(),
    );
  }

  void _append(Map<String, dynamic> envelope) {
    if (!envelopes.any((e) => e['id'] == envelope['id'])) {
      envelopes.add({...envelope, 'serverSequence': envelopes.length + 1});
    }
  }

  Future<http.Response> handle(http.Request request) async {
    if (offline) throw StateError('Server is offline');
    final Object body;
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
        for (final value in jsonDecode(request.body)['envelopes'] as List) {
          final envelope = Map<String, dynamic>.from(value as Map);
          pushed.add(envelope);
          _append(envelope);
        }
        body = {'cursor': envelopes.length};
      case '/api/sync/pull':
        final since = int.parse(request.url.queryParameters['since']!);
        final batch = envelopes.skip(since).take(500).toList();
        body = {
          'cursor': batch.isEmpty ? since : batch.last['serverSequence'],
          'envelopes': batch,
        };
      default:
        throw StateError('Unexpected request: ${request.url}');
    }
    return http.Response(jsonEncode(body), 200);
  }

  Future<void> seed() async {
    await append(
      'participant',
      Participant(
        id: 'z-source',
        displayName: 'Oldname',
        identifiers: ['discord:42'],
        aliases: ['Oldalias'],
      ).toJson(),
    );
    await append(
      'participant',
      Participant(
        id: 'a-target',
        displayName: 'Newname',
        identifiers: ['email:person@example.test'],
        aliases: ['Newalias'],
      ).toJson(),
    );
    for (var i = 0; i < 1001; i++) {
      await append(
        'conversation',
        Conversation(
          id: 'conversation-$i',
          title: 'Discussion $i',
          source: 'manual-text',
          participantIds: ['z-source'],
          startedAt: _date,
          endedAt: _date,
          segments: [
            ConversationSegment(
              id: 'segment-$i',
              participantId: 'z-source',
              text: 'uniquebody$i archive',
              createdAt: _date,
            ),
          ],
        ).toJson(),
      );
    }
  }
}

class _TrackedChunks extends FileVaultChunkStore {
  _TrackedChunks(super.root);
  int decryptions = 0;

  @override
  Future<Map<String, dynamic>> decryptChunk(
    VaultCrypto crypto,
    String key,
    int n,
    String expectedNonce, {
    Iterable<String> alternateNonces = const [],
    bool background = true,
  }) {
    decryptions++;
    return super.decryptChunk(
      crypto,
      key,
      n,
      expectedNonce,
      alternateNonces: alternateNonces,
      background: background,
    );
  }
}

class _Device {
  _Device(this.server);
  final _Server server;
  late Directory directory;
  late LocalVaultStore store;
  late _TrackedChunks chunks;
  final states = <LifenizerAppState>[];

  Future<void> initialize() async {
    directory = await Directory.systemTemp.createTemp('native-merge-');
    chunks = _TrackedChunks('${directory.path}/chunks');
    store = LocalVaultStore.remote(
      await openVaultDatabaseWorker(
        '${directory.path}/vault.sqlite',
        useSqlite: true,
      ),
    );
  }

  Future<LifenizerAppState> open({bool offline = false}) async {
    final state = LifenizerAppState(
      localStore: store,
      syncClock: () => _date,
      chunkStore: chunks,
      apiFactory: (url) =>
          LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
    );
    states.add(state);
    await state.login(
      baseUrl: _url,
      email: _email,
      password: 'synthetic-password',
      passphrase: 'synthetic-passphrase',
      deviceVaultKey: base64Encode(_key),
      deviceVaultSalt: _salt,
      offline: offline,
    );
    await state.waitForBackgroundSync();
    expect(state.error, isNull);
    expect(state.syncError, isNull);
    expect(state.conversations, hasLength(1001));
    return state;
  }

  Future<List<dynamic>> chunkNonces() async =>
      List.of((await store.read(_vaultKey))!['chunkNonces'] as List);

  Future<List<Map<String, dynamic>>> pending() async {
    final record = (await store.read(_vaultKey))!;
    final core = await server.crypto.decryptJson(
      cipherText: record['cipherText'] as String,
      nonce: record['nonce'] as String,
    );
    return (core['pending'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> close() async {
    for (final state in states) {
      state.dispose();
    }
    await store.close();
    await directory.delete(recursive: true);
  }
}

Future<void> _expectCanonical(LifenizerAppState state) async {
  expect(state.resolveParticipantId('z-source'), 'a-target');
  final person = state.participantById('z-source')!;
  expect(person.id, 'a-target');
  expect(
    person.identifiers,
    containsAll(['discord:42', 'email:person@example.test']),
  );
  expect(person.aliases, containsAll(['Oldname', 'Oldalias', 'Newalias']));
  expect(state.conversations.every((c) => !c.isLoaded), isTrue);
  expect(state.conversations.every((c) => c.segmentCount == 1), isTrue);
  expect(
    state.conversations.every((c) => c.participantIds.single == 'a-target'),
    isTrue,
  );
  for (final query in ['Oldalias', 'Newalias', 'uniquebody7']) {
    expect(await state.searchAsync(query), isNotEmpty);
  }
  final found = Completer<void>();
  void search() {
    final results = state.search('uniquebody7', participantId: 'a-target');
    if (results.any((c) => c.id == 'conversation-7') && !found.isCompleted) {
      found.complete();
    }
  }

  state.addListener(search);
  try {
    search();
    await found.future.timeout(const Duration(seconds: 10));
  } finally {
    state.removeListener(search);
  }
  final body = await state.loadConversation('conversation-7');
  expect(body.participantIds, ['a-target']);
  expect(body.segments.single.participantId, 'a-target');
  expect(body.segments.single.text, 'uniquebody7 archive');
  expect(state.conversations.every((c) => !c.isLoaded), isTrue);
}

void main() {
  late _Server server;
  final devices = <_Device>[];
  setUp(() async {
    server = _Server();
    await server.seed();
  });
  tearDown(() async {
    for (final device in devices) {
      await device.close();
    }
    devices.clear();
    server.crypto.lock();
  });
  Future<_Device> device() async {
    final result = _Device(server);
    devices.add(result);
    await result.initialize();
    return result;
  }

  test(
    'native merge keeps only participant outbox entries across offline reopen and sync',
    () async {
      final first = await device();
      final second = await device();
      var state = await first.open();
      final peer = await second.open();
      final decryptions = first.chunks.decryptions;
      final chunkNonces = await first.chunkNonces();
      server.offline = true;
      await state.mergeParticipants('z-source', 'a-target');
      expect(state.error, isNull);
      expect(state.pendingSyncCount, 2);
      expect(first.chunks.decryptions, decryptions);
      expect(await first.chunkNonces(), chunkNonces);
      final pending = await first.pending();
      expect(pending, hasLength(2));
      expect(pending.map((e) => e['entityType']), everyElement('participant'));
      expect(pending.map((e) => e['entityId']).toSet(), {
        'z-source',
        'a-target',
      });
      await _expectCanonical(state);
      await state.lock();
      state = await first.open(offline: true);
      expect(state.pendingSyncCount, 2);
      await _expectCanonical(state);
      server.offline = false;
      await state.pullSync();
      await peer.pullSync();
      expect(state.pendingSyncCount, 0);
      expect(server.pushed, hasLength(2));
      expect(
        server.pushed.map((e) => e['entityType']),
        everyElement('participant'),
      );
      await _expectCanonical(peer);
      await state.lock();
      await peer.lock();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'native identity coalescence does not enqueue conversation rewrites',
    () async {
      final first = await device();
      final state = await first.open();
      final decryptions = first.chunks.decryptions;
      final chunkNonces = await first.chunkNonces();
      // Introduce a duplicate identity after all conversation bodies are on disk.
      await server.append(
        'participant',
        Participant(
          id: 'a-target',
          displayName: 'Newname',
          identifiers: ['email:person@example.test', 'discord:42'],
          aliases: ['Newalias'],
        ).toJson(),
      );
      await state.pullSync();
      expect(state.error, isNull);
      expect(state.resolveParticipantId('z-source'), 'a-target');
      expect(first.chunks.decryptions, decryptions);
      expect(await first.chunkNonces(), chunkNonces);
      expect(state.conversations.every((c) => !c.isLoaded), isTrue);
      expect(state.pendingSyncCount, lessThanOrEqualTo(2));
      await state.pullSync();
      expect(server.pushed, hasLength(2));
      expect(
        server.pushed.map((e) => e['entityType']),
        everyElement('participant'),
      );
      await _expectCanonical(state);
      await state.lock();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
