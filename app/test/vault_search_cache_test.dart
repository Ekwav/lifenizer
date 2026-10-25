import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/search_index_worker_io.dart' as native;
import 'package:app/services/sync_progress.dart';
import 'package:app/services/vault_chunks.dart';
import 'package:app/services/vault_worker_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

class _Store extends LocalVaultStore {
  _Store(super.database);
  final detailReads = <String>[];
  final postingReads = <String>[];
  final postingWrites = <String>{};
  Completer<void>? postingGate;
  bool corruptPostings = false;
  Completer<void>? bodyGate;
  Completer<void>? bodyReadStarted;
  Completer<void>? gate;
  bool corruptDetails = false;
  bool failCoreWrites = false;
  String? corruptCatalog;
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    if (key.contains(':search-posting:')) postingWrites.add(key);
    if (failCoreWrites && value['format'] == 2) {
      throw StateError('Injected core write failure');
    }
    await super.write(key, value);
  }

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    if (key.endsWith(':search-catalog:0') && corruptCatalog != null) {
      final result = await super.read(key);
      return switch (corruptCatalog) {
        'missing' => null,
        'nonce' => {...result!, 'nonce': 'wrong-nonce'},
        _ => {...result!, 'cipherText': 'invalid encrypted catalog'},
      };
    }
    if (key.contains(':chunk:') && bodyGate != null) {
      if (bodyReadStarted?.isCompleted == false) bodyReadStarted!.complete();
      await bodyGate!.future;
    }
    if (key.contains(':search-posting:')) {
      postingReads.add(key);
      final result = await super.read(key);
      await postingGate?.future;
      return corruptPostings && result != null
          ? {...result, 'cipherText': 'invalid encrypted postings'}
          : result;
    }
    if (!key.contains(':search-detail:')) return super.read(key);
    detailReads.add(key);
    final result = await super.read(key);
    await gate?.future;
    return corruptDetails && result != null
        ? {...result, 'cipherText': 'invalid encrypted details'}
        : result;
  }
}

void main() {
  var sequence = 0;
  late Database database;
  late _Store store;
  late int postingBucketCount;
  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    final body = path.startsWith('/api/auth/')
        ? {
            'authToken': 'token',
            'userId': 'user',
            'vaultId': 'vault',
            'vaultSalt': 'salt',
          }
        : path == '/api/imports/capabilities'
        ? []
        : path == '/api/sync/push'
        ? {
            'cursor': 0,
            'accepted': (jsonDecode(request.body)['envelopes'] as List).length,
          }
        : path == '/api/sync/pull'
        ? {'cursor': 0, 'envelopes': []}
        : {};
    return http.Response(jsonEncode(body), 200);
  }

  Future<LifenizerAppState> open({bool offline = true}) async {
    final state = LifenizerAppState(
      localStore: store,
      apiFactory: (url) =>
          LifenizerApiClient(baseUrl: url, client: MockClient(handle)),
    );
    await state.login(
      baseUrl: 'https://search-cache.test',
      email: 'person@test.invalid',
      password: 'password',
      passphrase: 'vault passphrase',
      offline: offline,
    );
    await state.waitForBackgroundSync();
    return state;
  }

  Future<void> until(LifenizerAppState state, bool Function() predicate) async {
    final done = Completer<void>();
    void check() {
      if (predicate() && !done.isCompleted) done.complete();
    }

    state.addListener(check);
    check();
    try {
      await done.future.timeout(const Duration(seconds: 30));
    } finally {
      state.removeListener(check);
    }
  }

  Future<void> primePostings(LifenizerAppState state) async {
    expect(state.search('zebralantern'), isEmpty);
    await until(state, () => !state.searchDetailsLoading);
    expect(store.detailReads, isEmpty);
  }

  Future<void> seed({int count = 256}) async {
    database = await databaseFactoryMemory.openDatabase(
      'search-cache-regression-${sequence++}',
    );
    store = _Store(database);
    final original = await open(offline: false);
    original.conversations.addAll(
      List.generate(
        count,
        (i) => Conversation(
          id: 'thread-$i',
          title: 'Thread $i',
          source: 'discord',
          participantIds: const [],
          segments: [
            ConversationSegment(
              id: 'segment-$i',
              text: i == 7
                  ? 'zebralantern repeated repeated'
                  : 'different content $i',
            ),
          ],
        ),
      ),
    );
    await original.lock();
    original.dispose();
    store.detailReads.clear();
    store.postingReads.clear();
    postingBucketCount = store.postingWrites.length;
  }

  setUp(seed);
  tearDown(() => database.close());

  test(
    'broad cold searches batch notifications across queued cache waves',
    () async {
      await database.close();
      await seed(count: 1024);
      final restored = await open();
      var notifications = 0;
      void renderSearch() {
        notifications++;
        restored.search('discord', maxResults: 8);
      }

      restored.addListener(renderSearch);
      final results = await restored.searchAsync('discord', maxResults: 8);
      expect(results, hasLength(8));
      expect(postingBucketCount, greaterThan(vaultWorkerCount()));
      expect(store.detailReads, hasLength(postingBucketCount));
      expect(store.detailReads.toSet(), hasLength(postingBucketCount));
      expect(store.postingReads, hasLength(1));
      expect(
        notifications,
        2,
        reason: 'one posting batch and one scoring batch',
      );
      final loadedNotifications = notifications;
      expect(
        (await restored.searchAsync('discord', maxResults: 8)).map((c) => c.id),
        results.map((c) => c.id),
      );
      expect(
        notifications,
        loadedNotifications,
        reason: 'cached queries must not notify again',
      );
      expect(store.detailReads, hasLength(postingBucketCount));
      expect(restored.conversations.every((c) => !c.isLoaded), isTrue);
      restored.removeListener(renderSearch);
      await restored.lock();
      restored.dispose();
    },
  );

  for (final corruption in ['missing', 'nonce', 'cipherText']) {
    test(
      '$corruption catalog shard rebuilds without losing unsent changes',
      () async {
        final original = await open();
        await original.addManualText(
          title: 'Unsent note',
          participantNames: '',
          text: 'private unsent text',
        );
        final pending = original.pendingSyncCount;
        expect(pending, greaterThan(0));
        await original.lock();
        original.dispose();
        store.corruptCatalog = corruption;
        final restored = await open();
        expect(restored.error, isNull);
        expect(restored.conversations, hasLength(257));
        expect(restored.pendingSyncCount, pending);
        expect(restored.fullSearchBuilds, greaterThan(0));
        expect(
          (await restored.searchAsync('zebralantern')).single.id,
          'thread-7',
        );
        expect(
          restored.conversations.any(
            (conversation) => conversation.title == 'Unsent note',
          ),
          isTrue,
        );
        store.corruptCatalog = null;
        await restored.lock();
        restored.dispose();
      },
    );
  }

  test(
    'version 3 catalog opens lazily and migrates to authenticated shards',
    () async {
      final records = stringMapStoreFactory.store('vaults');
      final all = await records.find(database);
      final root = all.singleWhere((record) => record.value['format'] == 2);
      final key = root.key;
      final crypto = VaultCrypto();
      addTearDown(crypto.lock);
      await crypto.unlock(
        email: 'person@test.invalid',
        passphrase: 'vault passphrase',
        vaultSalt: 'salt',
      );
      final manifestRecord = (await store.read('$key:search-index'))!;
      final manifest = await crypto.decryptJson(
        cipherText: manifestRecord['cipherText'] as String,
        nonce: manifestRecord['nonce'] as String,
      );
      final shards = [
        for (var n = 0; n < (manifest['catalogNonces'] as List).length; n++)
          (await store.read('$key:search-catalog:$n'))!,
      ];
      final index = await native.decryptSearchCatalogShards(crypto, shards);
      final legacy = await crypto.encryptJson({
        'gzip': base64Encode(
          gzip.encode(
            utf8.encode(
              jsonEncode(
                index.toJson(includeDetails: false, includePostings: false),
              ),
            ),
          ),
        ),
        'cacheVersion': 3,
        'detailNonces': manifest['detailNonces'],
        'postingNonces': manifest['postingNonces'],
      });
      final core = await crypto.decryptJson(
        cipherText: root.value['cipherText'] as String,
        nonce: root.value['nonce'] as String,
      );
      core['searchIndexNonce'] = legacy.nonce;
      final sealedCore = await crypto.encryptJson(core);
      await store.write('$key:search-index', {
        'cipherText': legacy.cipherText,
        'nonce': legacy.nonce,
      });
      await store.write(key, {
        ...root.value,
        'cipherText': sealedCore.cipherText,
        'nonce': sealedCore.nonce,
      });
      final restored = await open();
      expect(restored.fullSearchBuilds, 0);
      expect(
        restored.conversations.every((conversation) => !conversation.isLoaded),
        isTrue,
      );
      final migratedRecord = (await store.read('$key:search-index'))!;
      expect(migratedRecord['cacheVersion'], 4);
      final migrated = await crypto.decryptJson(
        cipherText: migratedRecord['cipherText'] as String,
        nonce: migratedRecord['nonce'] as String,
      );
      expect(migrated['cacheVersion'], 4);
      expect(migrated['catalogNonces'], isNotEmpty);
      expect(
        (await restored.searchAsync('zebralantern')).single.id,
        'thread-7',
      );
      await restored.lock();
      restored.dispose();
    },
  );

  test(
    'duplicate queries share detail reads and lock does not wait for them',
    () async {
      final restored = await open();
      store.gate = Completer<void>();
      await primePostings(restored);
      expect(store.postingReads, hasLength(1));
      expect(
        store.postingReads.single,
        endsWith(
          ':search-posting:${vaultChunkFor('zebralantern', postingBucketCount)}',
        ),
      );
      expect(restored.search('zebralantern').single.id, 'thread-7');
      expect(restored.search('zebralantern').single.id, 'thread-7');
      expect(store.detailReads, hasLength(1));
      expect(restored.searchDetailsLoading, isTrue);
      await restored.lock().timeout(const Duration(seconds: 10));
      expect(restored.isAuthenticated, isFalse);
      expect(restored.searchDetailsLoading, isFalse);
      store.gate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(restored.fullSearchBuilds, 0);
      expect(restored.syncError, isNull);
      restored.dispose();
    },
  );

  test(
    'corrupt details rebuild from original encrypted conversations',
    () async {
      final restored = await open();
      await primePostings(restored);
      store.corruptDetails = true;
      final rebuilt = until(
        restored,
        () =>
            restored.fullSearchBuilds > 0 &&
            restored.syncProgress?.stage == SyncStage.complete,
      );
      expect(restored.search('zebralantern').single.id, 'thread-7');
      await rebuilt;
      expect(
        restored.conversations.every((conversation) => conversation.isLoaded),
        isTrue,
      );
      expect(restored.search('zebralantern').single.id, 'thread-7');
      expect(restored.error, isNull);
      store.corruptDetails = false;
      await restored.lock();
      restored.dispose();
    },
  );

  test(
    'dirty save hydrates scoring while unrelated bodies remain lazy',
    () async {
      final restored = await open();
      expect(
        restored.conversations.every((conversation) => !conversation.isLoaded),
        isTrue,
      );
      await restored.addManualText(
        title: 'New note',
        participantNames: '',
        text: 'newly added text',
      );
      expect(restored.error, isNull);
      expect(store.detailReads.toSet(), hasLength(4));
      expect(store.postingReads.toSet(), hasLength(postingBucketCount));
      expect(
        restored.conversations.any((conversation) => !conversation.isLoaded),
        isTrue,
      );
      await restored.lock();
      restored.dispose();
      final reopened = await open();
      expect(reopened.conversations, hasLength(257));
      expect(
        (await reopened.searchAsync('zebralantern', maxResults: 1)).single.id,
        'thread-7',
      );
      expect(reopened.search('zebralantern').single.id, 'thread-7');
      await reopened.lock();
      reopened.dispose();
    },
  );

  test('uncommitted disk catalog falls back to last saved originals', () async {
    final restored = await open();
    store.failCoreWrites = true;
    await restored.addManualText(
      title: 'Uncommitted note',
      participantNames: '',
      text: 'not durably saved',
    );
    expect(restored.error, contains('Injected core write failure'));
    restored.dispose(); // Exit after a failed save without retrying.
    store.failCoreWrites = false;
    final reopened = await open();
    expect(reopened.error, isNull);
    expect(reopened.conversations, hasLength(256));
    expect(reopened.search('zebralantern').single.id, 'thread-7');
    expect(reopened.fullSearchBuilds, greaterThan(0));
    await reopened.lock();
    reopened.dispose();
  });

  test(
    'cold posting queries share one bucket read and lock never waits',
    () async {
      final restored = await open();
      expect(store.postingReads, isEmpty);
      expect(store.detailReads, isEmpty);
      store.postingGate = Completer<void>();
      expect(restored.search('zebralantern'), isEmpty);
      expect(restored.search('zebralantern'), isEmpty);
      expect(store.postingReads, hasLength(1));
      expect(
        store.postingReads.single,
        endsWith(
          ':search-posting:${vaultChunkFor('zebralantern', postingBucketCount)}',
        ),
      );
      expect(store.detailReads, isEmpty);
      expect(restored.searchDetailsLoading, isTrue);
      await restored.lock().timeout(const Duration(seconds: 10));
      expect(restored.isAuthenticated, isFalse);
      expect(restored.searchDetailsLoading, isFalse);
      store.postingGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(restored.fullSearchBuilds, 0);
      expect(restored.syncError, isNull);
      restored.dispose();
    },
  );

  test(
    'async cold search waits for postings and scoring without loading bodies',
    () async {
      final restored = await open();
      final results = await Future.wait([
        restored.searchAsync('zebralantern', maxResults: 1),
        restored.searchAsync('zebralantern', maxResults: 1),
      ]);
      expect(results.map((matches) => matches.single.id), [
        'thread-7',
        'thread-7',
      ]);
      expect(store.postingReads, hasLength(1));
      expect(store.detailReads, hasLength(1));
      expect(
        restored.conversations.every((conversation) => !conversation.isLoaded),
        isTrue,
      );
      await restored.lock();
      restored.dispose();
    },
  );

  test(
    'corrupt postings rebuild from original encrypted conversations',
    () async {
      final restored = await open();
      store.corruptPostings = true;
      final rebuilt = until(
        restored,
        () =>
            restored.fullSearchBuilds > 0 &&
            restored.syncProgress?.stage == SyncStage.complete,
      );
      expect(restored.search('zebralantern'), isEmpty);
      final asyncMatches = restored.searchAsync('zebralantern');
      await rebuilt;
      expect((await asyncMatches).map((conversation) => conversation.id), [
        'thread-7',
      ]);
      expect(restored.search('zebralantern').single.id, 'thread-7');
      expect(
        restored.conversations.every((conversation) => conversation.isLoaded),
        isTrue,
      );
      expect(restored.error, isNull);
      store.corruptPostings = false;
      await restored.lock();
      restored.dispose();
    },
  );

  test(
    'new async search waits for an already running corrupt-cache rebuild',
    () async {
      final restored = await open();
      store.corruptPostings = true;
      store.bodyGate = Completer<void>();
      store.bodyReadStarted = Completer<void>();
      expect(restored.search('zebralantern'), isEmpty);
      await store.bodyReadStarted!.future.timeout(const Duration(seconds: 10));
      expect(restored.searchDetailsLoading, isFalse);
      var returned = false;
      final lookup = restored.searchAsync('zebralantern').then((matches) {
        returned = true;
        return matches;
      });
      await Future<void>.delayed(Duration.zero);
      final premature = returned;
      store.bodyGate!.complete();
      final matches = await lookup;
      await until(
        restored,
        () =>
            restored.fullSearchBuilds > 0 &&
            restored.syncProgress?.stage == SyncStage.complete,
      );
      expect(
        premature,
        isFalse,
        reason: 'one-shot callers must await the active recovery build',
      );
      expect(matches.map((conversation) => conversation.id), ['thread-7']);
      store.corruptPostings = false;
      await restored.lock();
      restored.dispose();
    },
  );
}
