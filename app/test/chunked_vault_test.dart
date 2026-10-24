import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/sync_progress.dart';
import 'package:app/services/vault_chunk_store_sembast.dart';
import 'package:app/services/vault_chunks.dart';
import 'package:app/services/vault_worker_web.dart'
    if (dart.library.io) 'package:app/services/vault_worker_io.dart';
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
  bool failPull = false;
  Completer<void>? pullGate;

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
      await pullGate?.future;
      if (failPull) throw http.ClientException('Pull failed');
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

/// Records every key written (writeMany falls back to write per record).
class _RecordingStore extends LocalVaultStore {
  _RecordingStore(super.database);
  final written = <String>[];
  final readKeys = <String>[];
  Completer<void>? detailReads;
  @override
  Future<Map<String, dynamic>?> read(String key) async {
    readKeys.add(key);
    if (key.contains(':search-detail:')) await detailReads?.future;
    return super.read(key);
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    written.add(key);
    await super.write(key, value);
  }
}

class _TrackedChunks extends SembastVaultChunkStore {
  _TrackedChunks(super.store);
  final decrypted = <int>[];

  @override
  Future<Map<String, dynamic>> decryptChunk(
    VaultCrypto crypto,
    String key,
    int n,
    String expectedNonce, {
    Iterable<String> alternateNonces = const [],
    bool background = true,
  }) {
    decrypted.add(n);
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

Conversation _conversation(int i, {int messages = 2}) => Conversation(
  id: 'thread-$i',
  title: 'Archive thread $i',
  source: 'discord',
  participantIds: const [],
  startedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
  endedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
  segments: [
    for (var j = 0; j < messages; j++)
      ConversationSegment(
        id: 'message-$i-$j',
        text: 'Message $j about topic$i',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
  ],
);

void main() {
  var counter = 0;
  final timeout = const Timeout(Duration(minutes: 2));
  late _Server server;
  late Database database;
  late _RecordingStore store;

  setUp(() async {
    server = _Server();
    database = await databaseFactoryMemory.openDatabase('chunks-${counter++}');
    store = _RecordingStore(database);
  });
  tearDown(() async {
    LifenizerAppState.synchronousIndexLimit = 1000;
    await database.close();
  });

  LifenizerAppState device({
    _TrackedChunks? chunks,
    DateTime Function()? syncClock,
  }) => LifenizerAppState(
    localStore: store,
    syncClock: syncClock,
    chunkStore: chunks,
    apiFactory: (url) =>
        LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
  );
  Future<LifenizerAppState> unlocked({
    bool offline = false,
    LifenizerAppState? state,
  }) async {
    state ??= device();
    await state.login(
      baseUrl: _baseUrl,
      email: _email,
      password: 'account password',
      passphrase: 'private vault phrase',
      offline: offline,
    );
    return state;
  }

  test('stable bucket hash is deterministic and spreads ids', () {
    expect(stableStringHash('thread-1'), stableStringHash('thread-1'));
    expect(stableStringHash(''), 0x811c9dc5);
    expect(stableStringHash('a'), 0xe40c292c); // FNV-1a("a") for code unit 97
    final buckets = {
      for (var i = 0; i < 1000; i++) vaultChunkFor('conversation-$i', 8),
    };
    expect(buckets, hasLength(8));
    expect(vaultChunkCountFor(10), 1);
    expect(vaultChunkCountFor(1000), 4);
    expect(vaultChunkCountFor(10833), 43);
    expect(vaultChunkCountFor(1000000), 128);
  });

  test(
    'startup skips postings and scoring; queries load only matching buckets',
    () async {
      final original = await unlocked();
      original.conversations.addAll(List.generate(512, _conversation));
      original.conversations[7].segments.add(
        ConversationSegment(id: 'unique', text: 'zebralantern'),
      );
      await original.lock();
      original.dispose();
      store.readKeys.clear();
      store.detailReads = Completer<void>();
      final chunks = _TrackedChunks(store);
      final restored = await unlocked(
        state: device(chunks: chunks),
        offline: true,
      );
      await restored.waitForBackgroundSync();
      expect(
        store.readKeys.where((key) => key.contains(':search-detail:')),
        isEmpty,
      );
      expect(chunks.decrypted, isEmpty);
      expect(
        store.readKeys.where((key) => key.contains(':search-posting:')),
        isEmpty,
      );
      expect(restored.search('zebralantern'), isEmpty);
      final postingsReady = Completer<void>();
      restored.addListener(() {
        if (!restored.searchDetailsLoading && !postingsReady.isCompleted) {
          postingsReady.complete();
        }
      });
      await postingsReady.future;
      expect(restored.search('zebralantern').map((c) => c.id), ['thread-7']);
      expect(restored.searchDetailsLoading, isTrue);
      final settled = Completer<void>();
      restored.addListener(() {
        if (!restored.searchDetailsLoading && !settled.isCompleted) {
          settled.complete();
        }
      });
      store.detailReads!.complete();
      await settled.future;
      expect(
        store.readKeys.where((key) => key.contains(':search-detail:')),
        hasLength(1),
      );
      expect(
        store.readKeys.where((key) => key.contains(':search-posting:')),
        hasLength(1),
      );
      expect(
        chunks.decrypted,
        isEmpty,
        reason: 'ranking reads only its prepared bucket',
      );
      expect(restored.search('zebralantern').single.id, 'thread-7');
      await restored.lock();
      restored.dispose();
    },
    timeout: timeout,
  );

  test(
    'legacy v1 blob loads and the first save converts it to v2 chunks',
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
        'conversations': [
          for (var i = 0; i < 3; i++) _conversation(i).toJson(),
        ],
        'relations': [],
        'savedSearches': [],
        'pending': [],
      });
      await store.write(_key, {
        'vaultSalt': 'stable-salt',
        'cipherText': payload.cipherText,
        'nonce': payload.nonce,
      });
      store.written.clear();
      final state = await unlocked(offline: true);
      await state.waitForBackgroundSync();
      expect(state.error, isNull);
      expect(state.conversations.map((c) => c.id).toSet(), {
        'thread-0',
        'thread-1',
        'thread-2',
      });
      final core = (await store.read(_key))!;
      expect(core['format'], 2);
      expect(core['chunkCount'], 1);
      expect(store.written, contains('$_key:chunk:0'));
      final plain = await crypto.decryptJson(
        cipherText: core['cipherText'] as String,
        nonce: core['nonce'] as String,
      );
      expect(plain.containsKey('conversations'), isFalse);
      expect(plain['conversationBuckets']['conversations'], [3]);
      await state.lock();
      state.dispose();
      crypto.lock();
    },
    timeout: timeout,
  );

  test(
    'partial saves rewrite only dirty chunks; audio drafts rewrite only the core',
    () async {
      final state = await unlocked();
      await state.waitForBackgroundSync();
      server.offline = true;
      state.conversations.addAll([
        for (var i = 0; i < 600; i++) _conversation(i),
      ]);
      // Outgrowing the first layout re-buckets with a full rewrite.
      await state.saveAudioDraft([1, 2, 3], DateTime.utc(2026, 1, 2));
      var core = (await store.read(_key))!;
      expect(core['chunkCount'], 4);
      for (var n = 0; n < 4; n++) {
        expect(await store.read('$_key:chunk:$n'), isNotNull);
      }
      final nonces = List<String>.from(core['chunkNonces'] as List);

      store.written.clear();
      await state.addManualText(
        title: 'One more',
        participantNames: '',
        text: 'a single new conversation',
      );
      final fresh = state.conversations.last;
      final bucket = vaultChunkFor(fresh.id, 4);
      expect(store.written.toSet(), {
        _key,
        '$_key:chunk:$bucket',
        '$_key:search-index',
        for (var n = 0; n < vaultWorkerCount(); n++) '$_key:search-catalog:$n',
        for (var n = 0; n < (state.conversations.length / 64).ceil(); n++)
          '$_key:search-detail:$n',
        for (var n = 0; n < (state.conversations.length / 64).ceil(); n++)
          '$_key:search-posting:$n',
      });
      core = (await store.read(_key))!;
      final after = List<String>.from(core['chunkNonces'] as List);
      for (var n = 0; n < 4; n++) {
        expect(after[n] == nonces[n], n != bucket, reason: 'chunk $n');
      }

      store.written.clear();
      await state.saveAudioDraft([4, 5], DateTime.utc(2026, 1, 3));
      // The audio goes to its own record; no conversation chunk is touched.
      expect(store.written, ['$_key:audio-draft', _key]);
      store.written.clear();
      await state.discardAudioDraft();
      expect(store.written, [_key]);
      expect(state.conversations, hasLength(601));
      await state.lock();
      state.dispose();
    },
    timeout: timeout,
  );

  test(
    'cached search restores immediately and bodies load only on demand',
    () async {
      final state = await unlocked();
      await state.waitForBackgroundSync();
      server.offline = true;
      state.conversations.addAll([
        for (var i = 0; i < 900; i++) _conversation(i, messages: 3),
      ]);
      await state.saveAudioDraft([9], DateTime.utc(2026, 1, 2));
      final expected = {
        for (final c in state.conversations) c.id: jsonEncode(c.toJson()),
      };
      await state.lock();
      state.dispose();

      final chunks = _TrackedChunks(store);
      final restored = device(chunks: chunks);
      final stages = <SyncStage>[];
      restored.addListener(() {
        if (restored.syncProgress case final value?) stages.add(value.stage);
      });
      await unlocked(offline: true, state: restored);
      await restored.waitForBackgroundSync();
      expect(restored.error, isNull);
      expect(restored.searchIndexPreparing, isFalse);
      expect(restored.fullSearchBuilds, 0);
      expect(restored.conversations.every((c) => !c.isLoaded), isTrue);
      expect((await restored.searchAsync('topic42')).first.id, 'thread-42');
      expect(
        chunks.decrypted,
        isEmpty,
        reason: 'cached startup/search must not decrypt conversation bodies',
      );
      expect(restored.conversations.every((c) => !c.isLoaded), isTrue);
      await restored.loadConversation('thread-42');
      expect(chunks.decrypted, [vaultChunkFor('thread-42', 4)]);
      expect(
        restored.conversations.where((c) => c.isLoaded).length,
        lessThan(900),
      );
      for (final id in restored.conversations.map((c) => c.id).toList()) {
        await restored.loadConversation(id);
      }
      expect({
        for (final c in restored.conversations) c.id: jsonEncode(c.toJson()),
      }, expected);
      expect(stages, contains(SyncStage.decryptingLocal));
      expect(await restored.loadAudioDraftPayload(), [9]);
      await restored.lock();
      restored.dispose();
    },
    timeout: timeout,
  );

  test(
    'saving a new conversation hydrates only its dirty bucket and preserves lazy neighbors',
    () async {
      final first = await unlocked();
      await first.waitForBackgroundSync();
      server.offline = true;
      first.conversations.addAll([
        for (var i = 0; i < 600; i++) _conversation(i, messages: 3),
      ]);
      await first.saveAudioDraft([1], DateTime.utc(2026, 1, 2));
      final expected = {
        for (final c in first.conversations) c.id: jsonEncode(c.toJson()),
      };
      await first.lock();
      first.dispose();

      final chunks = _TrackedChunks(store);
      final restored = await unlocked(
        offline: true,
        state: device(chunks: chunks),
      );
      await restored.waitForBackgroundSync();
      expect(chunks.decrypted, isEmpty);
      store.written.clear();
      await restored.addManualText(
        title: 'New note',
        participantNames: '',
        text: 'new content',
      );
      final fresh = restored.conversations.firstWhere(
        (c) => c.title == 'New note',
      );
      final bucket = vaultChunkFor(fresh.id, 4);
      expected[fresh.id] = jsonEncode(fresh.toJson());
      expect(chunks.decrypted, [bucket]);
      expect(restored.conversations.where((c) => !c.isLoaded), isNotEmpty);
      expect(store.written.where((key) => key.contains(':chunk:')).toSet(), {
        '$_key:chunk:$bucket',
      });
      await restored.lock();
      restored.dispose();

      final again = await unlocked(offline: true);
      await again.waitForBackgroundSync();
      for (final id in again.conversations.map((c) => c.id).toList()) {
        await again.loadConversation(id);
      }
      expect({
        for (final c in again.conversations) c.id: jsonEncode(c.toJson()),
      }, expected);
      await again.lock();
      again.dispose();
    },
    timeout: timeout,
  );

  for (final damage in ['missing', 'corrupt']) {
    test(
      '$damage search cache falls back to authenticated bodies without losing data',
      () async {
        final first = await unlocked();
        await first.waitForBackgroundSync();
        server.offline = true;
        first.conversations.addAll([
          for (var i = 0; i < 12; i++) _conversation(i),
        ]);
        await first.saveAudioDraft([1], DateTime.utc(2026, 1, 2));
        final expected = {
          for (final c in first.conversations) c.id: jsonEncode(c.toJson()),
        };
        await first.lock();
        first.dispose();
        final cacheKey = '$_key:search-index';
        if (damage == 'missing') {
          await stringMapStoreFactory
              .store('vaults')
              .record(cacheKey)
              .delete(database);
        } else {
          final cache = (await store.read(cacheKey))!;
          await store.write(cacheKey, {...cache, 'cipherText': 'corrupt'});
        }
        final chunks = _TrackedChunks(store);
        final restored = await unlocked(
          offline: true,
          state: device(chunks: chunks),
        );
        await restored.waitForBackgroundSync();
        expect(restored.error, isNull);
        expect(restored.isAuthenticated, isTrue);
        expect(chunks.decrypted, [0]);
        expect(restored.fullSearchBuilds, greaterThan(0));
        expect(restored.search('topic7').first.id, 'thread-7');
        expect({
          for (final c in restored.conversations) c.id: jsonEncode(c.toJson()),
        }, expected);
        expect(
          await store.read(cacheKey),
          isNotNull,
          reason: 'disposable cache is rebuilt',
        );
        await restored.lock();
        restored.dispose();
      },
      timeout: timeout,
    );
  }

  for (final damage in ['missing chunk', 'nonce mismatch']) {
    test(
      '$damage reports an incomplete vault, keeps the outbox and recovers online',
      () async {
        final state = await unlocked();
        await state.waitForBackgroundSync();
        await state.addManualText(
          title: 'Synced note',
          participantNames: '',
          text: 'already on the server',
        );
        await state.pullSync();
        server.offline = true;
        await state.addManualText(
          title: 'Unsent note',
          participantNames: '',
          text: 'only in the encrypted outbox',
        );
        expect(state.pendingSyncCount, 1);
        await state.lock();
        state.dispose();

        final chunkKey = '$_key:chunk:0';
        if (damage == 'missing chunk') {
          await stringMapStoreFactory
              .store('vaults')
              .record(chunkKey)
              .delete(database);
        } else {
          final record = (await store.read(chunkKey))!;
          await store.write(chunkKey, {...record, 'nonce': 'AAAAAAAAAAAAAAAA'});
        }

        final broken = device();
        await unlocked(offline: true, state: broken);
        expect(broken.isAuthenticated, isFalse);
        expect(broken.error, contains('incomplete'));
        expect(broken.error, contains('online'));
        expect(broken.conversations, isEmpty);

        server.offline = false;
        final recovered = await unlocked(state: device());
        await recovered.waitForBackgroundSync();
        await recovered.pullSync();
        expect(recovered.error, isNull, reason: recovered.error);
        expect(recovered.isAuthenticated, isTrue);
        expect(recovered.pendingSyncCount, 0);
        expect(recovered.conversations.map((c) => c.title).toSet(), {
          'Synced note',
          'Unsent note',
        });
        expect(
          server.envelopes.where((e) => e['entityType'] == 'conversation'),
          hasLength(2),
          reason: 'the unsent outbox entry was uploaded, not lost',
        );
        await recovered.lock();
        recovered.dispose();
      },
      timeout: timeout,
    );
  }

  test(
    'cached unlock opens the UI before sync completes and failures become syncError',
    () async {
      final first = await unlocked();
      await first.waitForBackgroundSync();
      await first.addManualText(
        title: 'Cached note',
        participantNames: '',
        text: 'visible immediately',
      );
      await first.lock();
      first.dispose();

      server.pullGate = Completer<void>();
      final state = device();
      final login = unlocked(state: state);
      var authenticatedWhileSyncing = false;
      state.addListener(() {
        if (state.isAuthenticated && server.pullGate?.isCompleted == false) {
          authenticatedWhileSyncing = true;
        }
      });
      await login;
      expect(state.isAuthenticated, isTrue);
      expect(authenticatedWhileSyncing, isTrue);
      expect(state.status, contains('syncing in background'));
      expect(state.conversations.single.title, 'Cached note');
      expect(state.syncProgress?.active, isTrue);
      expect(state.error, isNull);

      server.failPull = true;
      server.pullGate!.complete();
      await state.waitForBackgroundSync();
      expect(state.isAuthenticated, isTrue);
      expect(state.error, isNull);
      expect(state.syncError, contains('Sync paused'));
      expect(state.syncProgress?.stage, SyncStage.failed);
      await state.lock();
      state.dispose();
    },
    timeout: timeout,
  );

  test(
    'lock during the background unlock sync waits for it and preserves data',
    () async {
      var now = DateTime.utc(2026);
      final first = await unlocked(state: device(syncClock: () => now));
      await first.waitForBackgroundSync();
      server.offline = true;
      await first.addManualText(
        title: 'Offline note',
        participantNames: '',
        text: 'must survive lock',
      );
      expect(first.pendingSyncCount, 1);
      await first.lock();
      first.dispose();

      server.offline = false;
      now = now.add(const Duration(seconds: 20));
      server.pullGate = Completer<void>();
      final state = device(syncClock: () => now);
      await unlocked(state: state);
      expect(state.isAuthenticated, isTrue);
      var locked = false;
      final locking = state.lock().then((_) => locked = true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(locked, isFalse, reason: 'lock waits for the in-flight sync');
      expect(state.busy, isTrue);
      server.failPull = true;
      server.pullGate!.complete();
      await locking;
      expect(state.isAuthenticated, isFalse);
      state.dispose();

      server.offline = true;
      final again = await unlocked(offline: true, state: device());
      await again.waitForBackgroundSync();
      expect(again.error, isNull);
      expect(again.conversations.single.title, 'Offline note');
      // The background sync pushed the outbox before its pull failed, and lock
      // saved that state: the note is on the server and still stored locally.
      expect(again.pendingSyncCount, 0);
      expect(
        server.envelopes.where((e) => e['entityType'] == 'conversation'),
        hasLength(1),
      );
      await again.lock();
      again.dispose();
    },
    timeout: timeout,
  );

  test(
    'cached index searches full text before background sync completes',
    () async {
      final first = await unlocked();
      await first.waitForBackgroundSync();
      await first.addManualText(
        title: 'Garden plans',
        participantNames: '',
        text: 'plant tomatoes and basil',
      );
      await first.addManualText(
        title: 'Taxes',
        participantNames: '',
        text: 'file the return',
      );
      await first.lock();
      first.dispose();

      LifenizerAppState.synchronousIndexLimit = 0;
      server.pullGate = Completer<void>();
      final state = device();
      await unlocked(state: state);
      expect(state.searchIndexPreparing, isFalse);
      final linear = await state.searchAsync('tomatoes basil');
      expect(linear.map((c) => c.title), ['Garden plans']);
      expect((await state.searchAsync('GARDEN')).map((c) => c.title), [
        'Garden plans',
      ]);
      expect(state.search('nothing here'), isEmpty);
      expect(state.fullSearchBuilds, 0);

      server.pullGate!.complete();
      await state.waitForBackgroundSync();
      expect(state.searchIndexPreparing, isFalse);
      expect(state.fullSearchBuilds, 0);
      expect(state.search('tomatoes').map((c) => c.title), ['Garden plans']);
      await state.lock();
      state.dispose();
    },
    timeout: timeout,
  );

  test(
    'a few changes after the full build update the index incrementally',
    () async {
      final state = await unlocked();
      await state.waitForBackgroundSync();
      await state.addManualText(
        title: 'Baseline',
        participantNames: '',
        text: 'first conversation',
      );
      state.search('first');
      final builds = state.fullSearchBuilds;
      await state.addManualText(
        title: 'Newcomer',
        participantNames: '',
        text: 'brand new recording about zebras',
      );
      await state.waitForBackgroundSync();
      expect(state.search('zebras').map((c) => c.title), ['Newcomer']);
      expect(state.fullSearchBuilds, builds, reason: 'no full rebuild');
      expect(state.incrementalSearchUpdates, greaterThan(0));
      final live = state.conversations.firstWhere((c) => c.title == 'Newcomer');
      expect(identical(state.search('zebras').single, live), isTrue);
      await state.lock();
      state.dispose();
    },
    timeout: timeout,
  );

  group('ConversationSearchIndex incremental updates', () {
    final people = {'p': 'Pat Example'};
    Conversation conv(String id, String title, String text) => Conversation(
      id: id,
      title: title,
      source: 'email',
      participantIds: ['p'],
      segments: [ConversationSegment(id: '$id-s', text: text)],
    );

    test('upsert and remove match a full rebuild', () {
      final a = conv('a', 'Invoice March', 'invoice payment received');
      final b = conv('b', 'Train trip', 'berlin station meeting');
      final c = conv('c', 'Garden', 'tomatoes and invoice garden');
      final index = ConversationSearchIndex.build(
        conversations: [a, b],
        participantById: people,
        relationTextByConversation: const {},
      );
      index.upsert(
        c,
        participantById: people,
        relationTextByConversation: const {},
      );
      final b2 = conv('b', 'Train trip', 'berlin invoice station');
      index.upsert(
        b2,
        participantById: people,
        relationTextByConversation: const {},
      );
      index.remove('a');
      final expected = ConversationSearchIndex.build(
        conversations: [b2, c],
        participantById: people,
        relationTextByConversation: const {},
      );
      expect(index.invertedIndex, expected.invertedIndex);
      expect(index.idf, expected.idf);
      expect(index.averageLength, expected.averageLength);
      expect(index.documents.keys.toSet(), expected.documents.keys.toSet());
      expect(identical(index.documents['c']!.conversation, c), isTrue);
      for (final query in ['invoice', 'berlin', 'garden tomatoes', 'pat']) {
        final tokens = ConversationSearchIndex.tokenize(query);
        List<String> top(ConversationSearchIndex i) {
          final ids = i.lookupCandidates(tokens).toList()
            ..sort((x, y) {
              double score(String id) =>
                  i.lexicalScore(i.documents[id]!, query, tokens) +
                  i.vectorScore(i.documents[id]!, tokens);
              final byScore = score(y).compareTo(score(x));
              return byScore != 0 ? byScore : x.compareTo(y);
            });
          return ids;
        }

        expect(top(index), top(expected), reason: query);
      }
    });
  });
}
