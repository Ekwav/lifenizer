import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/vault_chunk_file_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

const _baseUrl = 'https://vault.example.test';
const _email = 'alice@example.test';
final _key = 'vault:${jsonEncode([_baseUrl, _email])}';

class _Server {
  final envelopes = <Map<String, dynamic>>[];
  bool offline = false;

  Future<http.Response> handle(http.Request request) async {
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
      body = {'cursor': envelopes.length};
    } else if (path == '/api/sync/pull') {
      final since = int.parse(request.url.queryParameters['since']!);
      final items = envelopes
          .where((e) => (e['serverSequence'] as int) > since)
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

/// Fails the n-th write to [failKey] once armed (simulating a crash).
class _FlakyStore extends LocalVaultStore {
  _FlakyStore(super.database);
  String? failKey;
  int failOnWrite = 0;
  int _writes = 0;
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    if (key == failKey && ++_writes == failOnWrite) {
      throw StateError('Simulated crash before the core was written');
    }
    await super.write(key, value);
  }
}

class _LoggingChunks extends FileVaultChunkStore {
  _LoggingChunks(super.root);
  final log = <String>[];
  @override
  Future<void> writeBlob(String key, String name, Map<String, dynamic> r) {
    log.add('write-blob:$name');
    return super.writeBlob(key, name, r);
  }

  @override
  Future<void> deleteBlob(String key, String name) {
    log.add('delete-blob:$name');
    return super.deleteBlob(key, name);
  }

  @override
  Future<void> writeChunks(String key, Map<int, Map<String, dynamic>> r) {
    log.add('write-chunks:${r.keys.join(',')}');
    return super.writeChunks(key, r);
  }
}

Conversation _conversation(int i) => Conversation(
  id: 'thread-$i',
  title: 'Archive thread $i',
  source: 'discord',
  participantIds: const [],
  segments: [ConversationSegment(id: 'm-$i', text: 'Message about topic$i')],
);

void main() {
  late Directory directory;
  late Database database;
  late LocalVaultStore store;
  late _Server server;
  var counter = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chunk-files-');
    database = await databaseFactoryMemory.openDatabase('files-${counter++}');
    store = LocalVaultStore(database);
    server = _Server();
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  LifenizerAppState device({bool files = true}) => LifenizerAppState(
    localStore: store,
    chunkStore: files ? FileVaultChunkStore(directory.path) : null,
    apiFactory: (url) =>
        LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
  );
  Future<LifenizerAppState> unlocked(
    LifenizerAppState state, {
    bool offline = false,
  }) async {
    await state.login(
      baseUrl: _baseUrl,
      email: _email,
      password: 'account password',
      passphrase: 'private vault phrase',
      offline: offline,
    );
    await state.waitForBackgroundSync();
    return state;
  }

  List<File> files() => directory
      .listSync(recursive: true)
      .whereType<File>()
      .toList(growable: false);

  test('file store round-trips, lists and deletes chunks', () async {
    final chunks = FileVaultChunkStore(directory.path);
    await chunks.writeChunks('vault:a', {
      0: {'cipherText': 'QUJD', 'nonce': 'bm9uY2Ux'},
      2: {'cipherText': 'REVGR0g=', 'nonce': 'bm9uY2Uy'},
    });
    expect(await chunks.listChunks('vault:a'), [0, 2]);
    expect(await chunks.readChunk('vault:a', 2), {
      'cipherText': 'REVGR0g=',
      'nonce': 'bm9uY2Uy',
    });
    expect(await chunks.readChunk('vault:a', 1), isNull);
    expect(await chunks.listChunks('vault:b'), isEmpty);
    await chunks.deleteChunks('vault:a', [0]);
    expect(await chunks.listChunks('vault:a'), [2]);
    await chunks.deleteAll('vault:a');
    expect(Directory(chunks.directoryFor('vault:a')).existsSync(), isFalse);

    final crypto = VaultCrypto();
    await crypto.unlock(email: _email, passphrase: 'phrase', vaultSalt: 'salt');
    final payload = await crypto.encryptJson({'conversations': []});
    await chunks.writeChunks('k', {
      0: {'cipherText': payload.cipherText, 'nonce': payload.nonce},
    });
    expect(await chunks.decryptChunk(crypto, 'k', 0, payload.nonce), {
      'conversations': [],
    });
    await expectLater(
      chunks.decryptChunk(crypto, 'k', 0, 'other-nonce'),
      throwsA(anything),
    );
    await expectLater(
      chunks.decryptChunk(crypto, 'k', 1, payload.nonce),
      throwsA(anything),
    );
    crypto.lock();
  });

  test(
    'a failing temp write leaves the old chunk and no partial file',
    () async {
      var fail = false;
      final chunks = FileVaultChunkStore(
        directory.path,
        writeFile: (temp, bytes) async {
          await temp.writeAsBytes(Uint8List.sublistView(bytes, 0, 10));
          if (fail) throw const FileSystemException('No space left on device');
          await temp.writeAsBytes(bytes);
        },
      );
      await chunks.writeChunks('k', {
        0: {'cipherText': 'OLD', 'nonce': 'n1'},
      });
      fail = true;
      await expectLater(
        chunks.writeChunks('k', {
          0: {'cipherText': 'NEW', 'nonce': 'n2'},
        }),
        throwsA(isA<FileSystemException>()),
      );
      expect((await chunks.readChunk('k', 0))!['cipherText'], 'OLD');
      expect(files().map((f) => f.path.split('/').last), ['chunk-0.bin']);
    },
  );

  test(
    'sembast chunks migrate to files and the old records are deleted',
    () async {
      final first = await unlocked(device(files: false));
      server.offline = true;
      first.conversations.addAll([
        for (var i = 0; i < 5; i++) _conversation(i),
      ]);
      await first.saveAudioDraft([1], DateTime.utc(2026));
      expect(await store.read('$_key:chunk:0'), isNotNull);
      expect((await store.read(_key))!['chunkStorage'], 'sembast');
      await first.lock();
      first.dispose();

      final second = await unlocked(device(), offline: true);
      expect(second.error, isNull);
      expect(second.conversations, hasLength(5));
      final core = (await store.read(_key))!;
      expect(core['chunkStorage'], 'files');
      expect(await store.read('$_key:chunk:0'), isNull);
      expect(
        files().map((f) => f.path.split('/').last),
        contains('chunk-0.bin'),
      );
      expect(await store.read('$_key:search-index'), isNotNull);
      expect(await store.read('$_key:search-detail:0'), isNotNull);
      await second.lock();
      second.dispose();

      // Relock: loads from the files.
      final third = await unlocked(device(), offline: true);
      expect(third.conversations.map((c) => c.id).toSet(), {
        for (var i = 0; i < 5; i++) 'thread-$i',
      });
      expect(third.audioDraft, isNotNull);
      await third.lock();
      third.dispose();
    },
  );

  test(
    'crash after phase 1 (chunk write fails) loads the old chunks and keeps the outbox',
    () async {
      var failChunkWrites = false;
      final crashing = LifenizerAppState(
        localStore: store,
        chunkStore: FileVaultChunkStore(
          directory.path,
          writeFile: (temp, bytes) async {
            if (failChunkWrites) throw const FileSystemException('Disk full');
            await temp.writeAsBytes(bytes, flush: true);
          },
        ),
        apiFactory: (url) =>
            LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
      );
      await unlocked(crashing);
      await crashing.addManualText(
        title: 'Synced note',
        participantNames: '',
        text: 'on the server',
      );
      await crashing.pullSync();
      server.offline = true;
      failChunkWrites = true;
      await crashing.addManualText(
        title: 'Unsent note',
        participantNames: '',
        text: 'only in the outbox',
      );
      expect(crashing.error, contains('Disk full'));
      crashing.dispose(); // crash: no lock, no further saving
      final core = (await store.read(_key))!;
      expect(core['pendingChunkNonces'], isNotEmpty);

      final restarted = await unlocked(device(), offline: true);
      expect(restarted.error, isNull, reason: restarted.error);
      expect(restarted.isAuthenticated, isTrue);
      expect(restarted.conversations.map((c) => c.title), ['Synced note']);
      expect(restarted.pendingSyncCount, 1);
      expect(
        (await store.read(_key))!.containsKey('pendingChunkNonces'),
        isFalse,
      );
      server.offline = false;
      await restarted.pullSync();
      expect(restarted.conversations.map((c) => c.title).toSet(), {
        'Synced note',
        'Unsent note',
      });
      await restarted.lock();
      restarted.dispose();
    },
  );

  test(
    'crash after phase 2 (final core fails) accepts the new chunk files without duplicates',
    () async {
      final flaky = _FlakyStore(database);
      final crashing = LifenizerAppState(
        localStore: flaky,
        chunkStore: FileVaultChunkStore(directory.path),
        apiFactory: (url) =>
            LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
      );
      await unlocked(crashing);
      await crashing.addManualText(
        title: 'Synced note',
        participantNames: '',
        text: 'on the server',
      );
      await crashing.pullSync();
      // Phase 1 is the first core write, the final core the second.
      flaky
        ..failKey = _key
        ..failOnWrite = 2;
      await crashing.addManualText(
        title: 'Newer note',
        participantNames: '',
        text: 'saved only in the chunk file',
      );
      expect(crashing.error, contains('Simulated crash'));
      crashing.dispose();

      final restarted = await unlocked(device(), offline: true);
      expect(restarted.error, isNull, reason: restarted.error);
      expect(restarted.conversations.map((c) => c.title).toSet(), {
        'Synced note',
        'Newer note',
      });
      server.offline = false;
      await restarted.pullSync();
      await restarted.waitForBackgroundSync();
      expect(restarted.conversations, hasLength(2));
      expect(restarted.conversations.map((c) => c.id).toSet(), hasLength(2));
      expect(
        server.envelopes.where((e) => e['entityType'] == 'conversation'),
        hasLength(2),
      );
      expect(
        (await store.read(_key))!.containsKey('pendingChunkNonces'),
        isFalse,
      );
      await restarted.lock();
      restarted.dispose();
    },
  );

  group('audio draft payload', () {
    test(
      'details saves never rewrite the payload; it survives relock; discard removes it',
      () async {
        final chunks = _LoggingChunks(directory.path);
        LifenizerAppState make() => LifenizerAppState(
          localStore: store,
          chunkStore: chunks,
          apiFactory: (url) => LifenizerApiClient(
            baseUrl: url,
            client: MockClient(server.handle),
          ),
        );
        final state = await unlocked(make());
        chunks.log.clear();
        await state.saveAudioDraft([1, 2, 3], DateTime.utc(2026, 1, 2));
        expect(chunks.log, ['write-blob:audio-draft']);
        expect(state.audioDraft!['payloadBytes'], 3);
        expect(state.audioDraft!.containsKey('payload'), isFalse);
        expect(jsonEncode(await store.read(_key)), isNot(contains('AQID')));

        chunks.log.clear();
        await state.updateAudioDraftDetails(
          title: 'Standup',
          detailsPrompted: true,
        );
        await state.updateAudioDraftDetails(participantNames: ['Pat']);
        expect(chunks.log, isEmpty, reason: 'only the core was written');
        expect(await state.loadAudioDraftPayload(), [1, 2, 3]);
        await state.lock();
        state.dispose();

        final again = await unlocked(make(), offline: true);
        expect(again.audioDraft!['title'], 'Standup');
        expect(again.audioDraft!['participantNames'], ['Pat']);
        expect(await again.loadAudioDraftPayload(), [1, 2, 3]);
        await again.discardAudioDraft();
        expect(again.audioDraft, isNull);
        expect(
          await FileVaultChunkStore(
            directory.path,
          ).readBlob(_key, 'audio-draft'),
          isNull,
        );
        expect(await again.loadAudioDraftPayload(), isNull);
        await again.lock();
        again.dispose();
      },
    );

    test(
      'a legacy in-core payload loads and migrates to its own record',
      () async {
        final crypto = VaultCrypto();
        await crypto.unlock(
          email: _email,
          passphrase: 'private vault phrase',
          vaultSalt: 'stable-salt',
        );
        final payload = await crypto.encryptJson({
          'session': {
            'authToken': 'private-token',
            'userId': 'user',
            'vaultId': 'vault',
            'vaultSalt': 'stable-salt',
          },
          'cursor': 0,
          'participants': [],
          'conversations': [_conversation(1).toJson()],
          'relations': [],
          'savedSearches': [],
          'pending': [],
          'audioDraft': {
            'payload': base64Encode([7, 8, 9]),
            'recordedAt': '2026-01-02T00:00:00.000Z',
          },
        });
        crypto.lock();
        await store.write(_key, {
          'vaultSalt': 'stable-salt',
          'cipherText': payload.cipherText,
          'nonce': payload.nonce,
        });
        final state = await unlocked(device(), offline: true);
        expect(state.error, isNull, reason: state.error);
        expect(await state.loadAudioDraftPayload(), [7, 8, 9]);
        expect(state.audioDraft!['payloadBytes'], 3);
        expect(
          await FileVaultChunkStore(
            directory.path,
          ).readBlob(_key, 'audio-draft'),
          isNotNull,
        );
        await state.lock();
        state.dispose();
        final again = await unlocked(device(), offline: true);
        expect(await again.loadAudioDraftPayload(), [7, 8, 9]);
        expect(again.conversations.single.id, 'thread-1');
        await again.lock();
        again.dispose();
      },
    );

    test('damaged-vault recovery keeps the draft and its payload', () async {
      final first = await unlocked(device());
      await first.addManualText(
        title: 'Note',
        participantNames: '',
        text: 'to be re-downloaded',
      );
      await first.pullSync();
      await first.saveAudioDraft([4, 5, 6], DateTime.utc(2026, 1, 2));
      await first.lock();
      first.dispose();
      await File(FileVaultChunkStore(directory.path).pathFor(_key, 0)).delete();
      final broken = await unlocked(device(), offline: true);
      expect(broken.error, contains('incomplete'));
      final recovered = await unlocked(device());
      expect(recovered.error, isNull, reason: recovered.error);
      expect(await recovered.loadAudioDraftPayload(), [4, 5, 6]);
      expect(recovered.conversations.map((c) => c.title), ['Note']);
      await recovered.lock();
      recovered.dispose();
    });
  });

  for (final damage in ['deleted', 'corrupted nonce']) {
    test('$damage chunk file takes the damaged-vault recovery path', () async {
      final first = await unlocked(device());
      await first.addManualText(
        title: 'Synced note',
        participantNames: '',
        text: 'on the server',
      );
      await first.pullSync();
      server.offline = true;
      await first.addManualText(
        title: 'Unsent note',
        participantNames: '',
        text: 'only in the outbox',
      );
      await first.lock();
      first.dispose();

      final chunks = FileVaultChunkStore(directory.path);
      expect(
        files().where((f) => f.path.endsWith('chunk-0.bin')),
        hasLength(1),
      );
      if (damage == 'deleted') {
        await File(chunks.pathFor(_key, 0)).delete();
      } else {
        final record = (await chunks.readChunk(_key, 0))!;
        await chunks.writeChunks(_key, {
          0: {...record, 'nonce': 'AAAAAAAAAAAAAAAA'},
        });
      }
      final broken = await unlocked(device(), offline: true);
      expect(broken.isAuthenticated, isFalse);
      expect(broken.error, contains('incomplete'));
      expect(files(), isEmpty, reason: 'chunk directory removed');

      server.offline = false;
      final recovered = await unlocked(device());
      await recovered.pullSync();
      expect(recovered.error, isNull, reason: recovered.error);
      expect(recovered.pendingSyncCount, 0);
      expect(recovered.conversations.map((c) => c.title).toSet(), {
        'Synced note',
        'Unsent note',
      });
      expect(
        files().map((f) => f.path.split('/').last),
        contains('chunk-0.bin'),
      );
      expect(await store.read('$_key:search-index'), isNotNull);
      expect(await store.read('$_key:search-detail:0'), isNotNull);
      await recovered.lock();
      recovered.dispose();
    });
  }
}
