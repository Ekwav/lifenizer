import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/discord_bot_import_service.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/search_source_groups.dart';
import 'package:app/services/sync_progress.dart';
import 'package:app/services/vault_chunk_file_store.dart';
import 'package:app/services/vault_database_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

const _url = 'https://disk-vault.test';
const _email = 'person@example.test';
const _salt = 'synthetic-disk-vault-salt';
final _vaultKey = 'vault:${jsonEncode([_url, _email])}';
final _deviceKey = List<int>.generate(32, (i) => i);
final _date = DateTime.utc(2026, 10, 28);

Conversation _conversation(
  int i, {
  bool updated = false,
  String source = 'manual-text',
}) => Conversation(
  id: 'conversation-$i',
  title: 'Discussion $i',
  source: source,
  participantIds: const [],
  startedAt: _date,
  endedAt: _date,
  segments: List.generate(
    8,
    (j) => ConversationSegment(
      id: 'segment-$i-$j',
      text: List.generate(
        25,
        (word) => word == 0 && j == 0
            ? updated
                  ? 'replacementword'
                  : i == 7
                  ? 'zebralantern'
                  : 'bodyword$i'
            : 'archive',
      ).join(' '),
      createdAt: _date,
    ),
  ),
);

class _ProgressChunks extends FileVaultChunkStore {
  _ProgressChunks(super.root, this.onDecrypt);
  final void Function() onDecrypt;

  @override
  Future<Map<String, dynamic>> decryptChunk(
    VaultCrypto crypto,
    String key,
    int n,
    String expectedNonce, {
    Iterable<String> alternateNonces = const [],
    bool background = true,
  }) {
    onDecrypt();
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

class _Fixture {
  late Directory directory;
  late LocalVaultStore store;
  final crypto = VaultCrypto()..unlockDeviceKey(_deviceKey);
  final devices = <LifenizerAppState>[];
  final envelopes = <Map<String, dynamic>>[];
  final pushSizes = <int>[];
  int requests = 0;
  int pulls = 0;
  bool offline = false;
  bool nativeSearch = true;
  String? growthFailure;
  Map<String, dynamic>? stagedCore;
  Completer<void>? draftWriteStarted;
  Completer<void>? draftWriteGate;
  bool failNextCoreWrite = false;

  Future<void> initialize() async {
    directory = await Directory.systemTemp.createTemp('disk-vault-search-');
    final request = await openVaultDatabaseWorker(
      '${directory.path}/vault.sqlite',
      useSqlite: true,
    );
    store = LocalVaultStore.remote((operation, key, value) async {
      if (operation == 'sqlitePath' && !nativeSearch) return null;
      if (operation == 'write' && key == _vaultKey) {
        if (failNextCoreWrite) {
          failNextCoreWrite = false;
          throw StateError('Injected core write failure');
        }
        if (value!['pendingChunkGeneration'] != null) stagedCore = {...value};
        if (growthFailure == 'core' &&
            stagedCore != null &&
            value['pendingChunkGeneration'] == null &&
            value['chunkGeneration'] != stagedCore!['chunkGeneration']) {
          throw StateError('Injected growth core failure');
        }
      }
      return request(operation, key, value);
    });
  }

  Future<void> append(
    int i, {
    bool updated = false,
    String source = 'manual-text',
    Map<String, dynamic> fields = const {},
  }) async {
    final sealed = await crypto.encryptJson({
      ..._conversation(i, updated: updated, source: source).toJson(),
      ...fields,
    });
    _append(
      SyncEnvelope(
        id: 'remote-$i-${updated ? 2 : 1}',
        deviceId: 'remote-device',
        entityType: 'conversation',
        entityId: 'conversation-$i',
        operation: 'upsert',
        revision: updated ? 2 : 1,
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

  Future<http.Response> _handle(http.Request request) async {
    requests++;
    if (offline) throw StateError('Offline unlock must not contact the server');
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
          _append(Map<String, dynamic>.from(envelope as Map));
        }
        body = {'cursor': envelopes.length};
      case '/api/sync/pull':
        pulls++;
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

  Future<LifenizerAppState> open({bool offline = false}) async {
    final state = LifenizerAppState(
      localStore: store,
      syncClock: () => _date,
      chunkStore: FileVaultChunkStore(
        '${directory.path}/chunks',
        writeFile: (temp, bytes) async {
          if (temp.path.endsWith('/audio-draft.bin.tmp') &&
              draftWriteGate != null) {
            if (!draftWriteStarted!.isCompleted) draftWriteStarted!.complete();
            await draftWriteGate!.future;
          }
          if (growthFailure == 'chunk' && stagedCore != null) {
            throw StateError('Injected growth chunk failure');
          }
          await temp.writeAsBytes(bytes, flush: true);
        },
      ),
      apiFactory: (url) =>
          LifenizerApiClient(baseUrl: url, client: MockClient(_handle)),
    );
    devices.add(state);
    await state.login(
      baseUrl: _url,
      email: _email,
      password: 'synthetic-password',
      passphrase: 'synthetic-passphrase',
      deviceVaultKey: base64Encode(_deviceKey),
      deviceVaultSalt: _salt,
      offline: offline,
    );
    await state.waitForBackgroundSync();
    expect(state.error, isNull);
    expect(state.syncError, isNull);
    return state;
  }

  Future<void> seed(int count) async {
    for (var i = 0; i < count; i++) {
      await append(i);
    }
  }

  Future<File> indexFile() async =>
      (await directory.list().toList()).whereType<File>().singleWhere(
        (file) => RegExp(r'\.search-[0-9a-f]+$').hasMatch(file.path),
      );

  Future<Map<String, dynamic>> core() async {
    final record = (await store.read(_vaultKey))!;
    return crypto.decryptJson(
      cipherText: record['cipherText'] as String,
      nonce: record['nonce'] as String,
    );
  }

  Future<void> close() async {
    for (final state in devices) {
      state.dispose();
    }
    crypto.lock();
    await store.close();
    await directory.delete(recursive: true);
  }
}

Future<void> _expectBodySearch(LifenizerAppState state) async {
  expect((await state.searchAsync('zebralantern')).map((c) => c.id), [
    'conversation-7',
  ]);
  expect(state.conversations.every((c) => !c.isLoaded), isTrue);
}

void main() {
  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture();
    await fixture.initialize();
  });
  tearDown(() => fixture.close());

  for (final count in [1000, 1001]) {
    test(
      '$count remote conversations use native disk search and lazy bodies',
      () async {
        await fixture.seed(count);
        var state = await fixture.open();
        expect(state.conversations, hasLength(count));
        expect(state.syncCursor, count);
        expect(fixture.pulls, 3);
        expect(state.insights.totalSegments, count * 8);
        expect(await (await fixture.indexFile()).length(), greaterThan(0));
        expect(
          (await fixture.store.read(
            '$_vaultKey:search-index',
          ))!['cacheVersion'],
          5,
        );
        await _expectBodySearch(state);
        expect(
          await state.searchAsync('archive', maxResults: 1000000),
          hasLength(100),
        );
        final first = state.search('bodyword42', maxResults: 1);
        expect(first, isEmpty);
        final notified = Completer<void>();
        void render() {
          if (state.search('bodyword42', maxResults: 1).isNotEmpty &&
              !notified.isCompleted) {
            notified.complete();
          }
        }

        state.addListener(render);
        try {
          await notified.future.timeout(const Duration(seconds: 10));
        } finally {
          state.removeListener(render);
        }
        expect(
          state.search('bodyword42', maxResults: 1).single.id,
          'conversation-42',
        );
        final loaded = await state.loadConversation('conversation-7');
        expect(loaded.isLoaded, isTrue);
        expect(
          loaded.segments.expand((s) => s.text.split(' ')),
          hasLength(200),
        );
        expect(state.conversations.every((c) => !c.isLoaded), isTrue);
        await state.lock();
        expect(state.isAuthenticated, isFalse);
        expect(state.conversations, isEmpty);
        expect(state.search('archive'), isEmpty);
        fixture.offline = true;
        final pulls = fixture.pulls;
        state = await fixture.open(offline: true);
        expect(fixture.pulls, pulls);
        expect(state.conversations, hasLength(count));
        expect(state.insights.totalSegments, count * 8);
        expect(state.fullSearchBuilds, 0);
        await _expectBodySearch(state);
        final buckets = (await fixture.core())['conversationBuckets'] as Map;
        expect(
          (buckets['conversations'] as List).cast<int>().reduce(
            (a, b) => a + b,
          ),
          count,
        );
        expect(
          (buckets['messages'] as List).cast<int>().reduce((a, b) => a + b),
          count * 8,
        );
        await state.lock();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'reopened 999-item vault preserves old and new bodies at native threshold',
    () async {
      await fixture.seed(999);
      final original = await fixture.open();
      await original.lock();
      fixture.offline = true;
      final state = await fixture.open(offline: true);
      expect(state.conversations.every((c) => !c.isLoaded), isTrue);
      await state.addManualText(
        title: 'Threshold note',
        participantNames: '',
        text: 'thresholdprivatemarker',
      );
      expect(state.error, isNull);
      expect(state.conversations, hasLength(1000));
      expect(state.pendingSyncCount, 1);
      await _expectBodySearch(state);
      expect(
        (await state.searchAsync('thresholdprivatemarker')).single.title,
        'Threshold note',
      );
      final body = await state.loadConversation('conversation-7');
      expect(body.segments.first.text, contains('zebralantern'));
      await state.lock();
      final reopened = await fixture.open(offline: true);
      expect(reopened.conversations, hasLength(1000));
      expect(reopened.pendingSyncCount, 1);
      await _expectBodySearch(reopened);
      expect(
        (await reopened.searchAsync('thresholdprivatemarker')).single.title,
        'Threshold note',
      );
      await reopened.lock();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'incremental sync and batched local edits preserve unloaded bodies',
    () async {
      await fixture.seed(1000);
      final state = await fixture.open();
      final builds = state.fullSearchBuilds;
      await fixture.append(7, updated: true);
      await fixture.append(1000);
      await state.pullSync();
      expect(state.error, isNull);
      expect(state.syncError, isNull);
      expect(state.conversations, hasLength(1001));
      expect(state.fullSearchBuilds, builds);
      expect(state.incrementalSearchUpdates, greaterThan(0));
      expect(await state.searchAsync('zebralantern'), isEmpty);
      expect(
        (await state.searchAsync('replacementword')).single.id,
        'conversation-7',
      );
      expect(
        (await state.searchAsync('bodyword1000', maxResults: 1)).single.id,
        'conversation-1000',
      );
      await state.batchVaultChanges(() async {
        for (var i = 0; i < 101; i++) {
          await state.addManualText(
            title: 'Local note $i',
            participantNames: '',
            text: 'localbatchmarker archive $i',
          );
        }
      });
      expect(state.pendingSyncCount, 101);
      await state.pullSync();
      expect(fixture.pushSizes, [100, 1]);
      expect(state.pendingSyncCount, 0);
      expect(state.conversations, hasLength(1102));
      expect(
        await state.searchAsync('localbatchmarker', maxResults: 1000000),
        hasLength(100),
      );
      expect(state.conversations.every((c) => !c.isLoaded), isTrue);
      await state.lock();
      fixture.offline = true;
      final reopened = await fixture.open(offline: true);
      expect(reopened.conversations, hasLength(1102));
      expect(reopened.pendingSyncCount, 0);
      expect(
        (await reopened.searchAsync('replacementword')).single.id,
        'conversation-7',
      );
      await reopened.lock();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'missing disk cache restores chunks with continuous progress',
    () async {
      await fixture.seed(1000);
      final original = await fixture.open();
      await original.lock();
      final saved = (await fixture.store.read(_vaultKey))!;
      final chunks = saved['chunkCount'] as int;
      expect(chunks, greaterThan(1));
      await (await fixture.indexFile()).delete();
      fixture.offline = true;
      final progress = <SyncProgress>[];
      late final LifenizerAppState restored;
      restored = LifenizerAppState(
        localStore: fixture.store,
        chunkStore: _ProgressChunks(
          '${fixture.directory.path}/chunks',
          () => progress.add(restored.syncProgress!),
        ),
        apiFactory: (url) => LifenizerApiClient(
          baseUrl: url,
          client: MockClient(fixture._handle),
        ),
      );
      fixture.devices.add(restored);
      final stages = <SyncStage>[];
      restored.addListener(() {
        if (restored.syncProgress case final value?) stages.add(value.stage);
      });
      await restored.login(
        baseUrl: _url,
        email: _email,
        password: 'synthetic-password',
        passphrase: 'synthetic-passphrase',
        deviceVaultKey: base64Encode(_deviceKey),
        deviceVaultSalt: _salt,
        offline: true,
      );
      await restored.waitForBackgroundSync();
      expect(restored.error, isNull);
      expect(restored.syncError, isNull);
      expect(
        stages.skipWhile((stage) => stage != SyncStage.restoring),
        isNot(contains(SyncStage.decryptingLocal)),
      );
      expect(progress, hasLength(chunks));
      expect(progress.first.completed, 0);
      expect(progress.first.stageClock, isNotNull);
      for (var i = 0; i < progress.length; i++) {
        expect(progress[i].stage, SyncStage.restoring);
        expect(progress[i].total, 8000);
        expect(progress[i].stageClock, same(progress.first.stageClock));
        if (i > 0) {
          expect(progress[i].completed, greaterThan(progress[i - 1].completed));
        }
      }
      expect(restored.conversations, hasLength(1000));
      expect(restored.syncCursor, 1000);
      await _expectBodySearch(restored);
      await restored.lock();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final corruption in ['invalid file', 'uncommitted index']) {
    test(
      '$corruption rebuilds the disposable index from canonical chunks',
      () async {
        await fixture.seed(1000);
        final state = await fixture.open();
        await state.addManualText(
          title: 'Unsent note',
          participantNames: '',
          text: 'unsentprivatemarker',
        );
        expect(state.pendingSyncCount, 1);
        await state.lock();
        final file = await fixture.indexFile();
        final disk = await DiskSearchIndex.open(
          path: file.path,
          vaultKey: _deviceKey,
        );
        if (corruption == 'uncommitted index') {
          // Simulate an index commit followed by a crash before the core commit.
          await disk.upsert(
            [_conversation(7, updated: true)],
            participantById: const {},
            relationTextByConversation: const {},
          );
          await disk.writeMetadata('snapshotNonce', 'uncommitted-search-nonce');
        }
        await disk.close();
        if (corruption == 'invalid file') {
          await file.writeAsString('damaged disposable cache', flush: true);
        }
        fixture.offline = true;
        final reopened = await fixture.open(offline: true);
        expect(reopened.conversations, hasLength(1001));
        expect(reopened.syncCursor, 1000);
        expect(reopened.insights.totalSegments, 8001);
        expect(reopened.pendingSyncCount, 1);
        await _expectBodySearch(reopened);
        expect(await reopened.searchAsync('replacementword'), isEmpty);
        expect(
          (await reopened.searchAsync('unsentprivatemarker')).single.title,
          'Unsent note',
        );
        await reopened.lock();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  for (final table in ['docpages', 'rankdocuments']) {
    test(
      '$table preparation failure rebuilds offline without losing the queued edit',
      () async {
        await fixture.seed(1000);
        final original = await fixture.open();
        await original.addManualText(
          title: 'Unsent note',
          participantNames: '',
          text: 'unsentmigrationmarker',
        );
        final edited = (await original.searchAsync(
          'unsentmigrationmarker',
        )).single;
        final expectedBody = (await original.loadConversation(
          edited.id,
        )).toJson();
        expect(original.pendingSyncCount, 1);
        await original.lock();
        final core = await fixture.core();
        expect(core['searchIndexNonce'], isNotNull);
        final pending = core['pending'] as List;
        expect(pending, hasLength(1));
        final file = await fixture.indexFile();
        final disk = await DiskSearchIndex.open(
          path: file.path,
          vaultKey: _deviceKey,
        );
        try {
          // Keep the acknowledgement valid so unlock prepares the cached index.
          expect(await disk.count, 1001);
          expect(
            await disk.readMetadata('snapshotNonce'),
            core['searchIndexNonce'],
          );
          expect(await disk.readMetadata('_rankingVersion'), isNotNull);
        } finally {
          await disk.close();
        }
        final database = sql.sqlite3.open(file.path);
        try {
          if (table == 'docpages') {
            database.execute(
              "DELETE FROM metadata WHERE key = '_rankingVersion'",
            );
          }
          database.execute(
            'UPDATE $table SET payload = zeroblob(29) WHERE id = 0',
          );
          expect(database.updatedRows, 1);
        } finally {
          database.close();
        }

        fixture.offline = true;
        final requests = fixture.requests;
        final reopened = await fixture.open(offline: true);
        expect(reopened.conversations, hasLength(1001));
        expect(reopened.syncCursor, 1000);
        expect(reopened.pendingSyncCount, 1);
        expect((await fixture.core())['pending'], pending);
        await _expectBodySearch(reopened);
        expect(
          (await reopened.searchAsync('unsentmigrationmarker')).single.id,
          edited.id,
        );
        expect(
          (await reopened.loadConversation(edited.id)).toJson(),
          expectedBody,
        );
        expect(reopened.searchError, isNull);
        expect(fixture.requests, requests);
        await reopened.lock();
        expect((await fixture.core())['pending'], pending);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'legacy v4 cache migrates to disk search using canonical chunks',
    () async {
      fixture.nativeSearch = false;
      await fixture.seed(1000);
      final original = await fixture.open();
      await original.lock();
      expect(
        (await fixture.store.read('$_vaultKey:search-index'))!['cacheVersion'],
        4,
      );
      fixture.nativeSearch = true;
      fixture.offline = true;
      final migrated = await fixture.open(offline: true);
      expect(migrated.conversations, hasLength(1000));
      expect(migrated.syncCursor, 1000);
      await _expectBodySearch(migrated);
      expect(
        (await fixture.store.read('$_vaultKey:search-index'))!['cacheVersion'],
        5,
      );
      final lookup = migrated.searchAsync('archive', maxResults: 100);
      await migrated.lock().timeout(const Duration(seconds: 10));
      await lookup;
      expect(migrated.search('archive'), isEmpty);
      expect(migrated.searchDetailsLoading, isFalse);
      expect(migrated.conversations, isEmpty);
      expect(migrated.syncError, isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final table in ['bodypages', 'scoretiles']) {
    test(
      '$table corruption preserves canonical bodies and queued edits on retry',
      () async {
        await fixture.seed(1000);
        final original = await fixture.open();
        await original.addManualText(
          title: 'Unsent note',
          participantNames: '',
          text: 'unsentprivatemarker',
        );
        await original.lock();
        final file = await fixture.indexFile();
        final database = sql.sqlite3.open(file.path);
        try {
          database.execute(
            'UPDATE $table SET payload = zeroblob(29) WHERE id = 0',
          );
        } finally {
          database.close();
        }
        fixture.offline = true;
        final reopened = await fixture.open(offline: true);
        expect(reopened.conversations, hasLength(1001));
        expect(reopened.conversations.every((c) => !c.isLoaded), isTrue);
        expect(reopened.fullSearchBuilds, 0);
        if (table == 'scoretiles') {
          expect(await reopened.searchAsync('zebralantern'), isEmpty);
          expect(reopened.searchError, isNotNull);
        }
        final body = await reopened.loadConversation('conversation-7');
        expect(body.segments.expand((s) => s.text.split(' ')), hasLength(200));
        expect(body.segments.first.text, contains('zebralantern'));
        expect(reopened.searchError, isNotNull);
        final reloaded = await reopened.loadConversation('conversation-7');
        expect(reloaded.toJson(), body.toJson());
        expect(reopened.conversations.every((c) => !c.isLoaded), isTrue);
        await reopened.addManualText(
          title: 'Queued after corruption',
          participantNames: '',
          text: 'queuedrecoverymarker',
        );
        expect(reopened.pendingSyncCount, 2);
        await reopened.retrySearch();
        expect(reopened.error, isNull);
        expect(reopened.searchError, isNull);
        expect(reopened.pendingSyncCount, 2);
        expect(reopened.conversations, hasLength(1002));
        await _expectBodySearch(reopened);
        expect(
          (await reopened.searchAsync('unsentprivatemarker')).single.title,
          'Unsent note',
        );
        expect(
          (await reopened.searchAsync('queuedrecoverymarker')).single.title,
          'Queued after corruption',
        );
        await reopened.lock();
        final persisted = await fixture.open(offline: true);
        expect(persisted.pendingSyncCount, 2);
        expect(persisted.conversations, hasLength(1002));
        expect(
          (await persisted.searchAsync('queuedrecoverymarker')).single.title,
          'Queued after corruption',
        );
        await persisted.lock();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'async continuation searches retain the resolved topic across renders',
    () async {
      await fixture.seed(1000);
      final state = await fixture.open();
      expect(
        (await state.searchAsync('zebralantern')).single.id,
        'conversation-7',
      );
      final followUp = await state
          .searchAsync('same as before archive')
          .timeout(const Duration(seconds: 10));
      expect(followUp.map((c) => c.id), ['conversation-7']);
      for (var render = 0; render < 3; render++) {
        expect(state.search('same as before archive').map((c) => c.id), [
          'conversation-7',
        ]);
        expect(
          (await state.searchAsync('same as before archive')).map((c) => c.id),
          ['conversation-7'],
        );
      }
      expect((await state.searchAsync('replacementword')), isEmpty);
      await state.lock();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final failure in ['chunk', 'core']) {
    test(
      'growth $failure failure preserves the old chunk generation and outbox',
      () async {
        await fixture.seed(1000);
        final state = await fixture.open();
        await state.addManualText(
          title: 'Unsent note',
          participantNames: '',
          text: 'unsentprivatemarker',
        );
        for (var i = 1000; i < 3999; i++) {
          await fixture.append(i);
        }
        fixture.growthFailure = failure;
        await state.syncQuietly();
        expect(state.syncError, contains('Injected growth $failure failure'));
        expect(fixture.pushSizes, isEmpty);
        final staged = fixture.stagedCore!;
        expect(staged['chunkCount'], 4);
        expect(
          staged['chunkGeneration'],
          isNot(staged['pendingChunkGeneration']),
        );
        final old = await fixture.core();
        final oldCount =
            ((old['conversationBuckets'] as Map)['conversations'] as List)
                .cast<int>()
                .reduce((a, b) => a + b);
        expect(oldCount, 3501);
        final chunks = FileVaultChunkStore('${fixture.directory.path}/chunks');
        final oldKey = staged['chunkGeneration'] == null
            ? _vaultKey
            : '$_vaultKey:chunks:${staged['chunkGeneration']}';
        for (var n = 0; n < 4; n++) {
          expect(
            await chunks.chunkNonce(oldKey, n),
            (staged['chunkNonces'] as List)[n],
          );
        }
        state.dispose(); // Crash without retrying the failed publication.
        fixture.devices.remove(state);
        fixture.growthFailure = null;
        fixture.offline = true;
        final reopened = await fixture.open(offline: true);
        expect(reopened.conversations, hasLength(oldCount));
        expect(reopened.syncCursor, old['cursor']);
        expect(reopened.pendingSyncCount, 1);
        await _expectBodySearch(reopened);
        expect(
          (await reopened.searchAsync('unsentprivatemarker')).single.title,
          'Unsent note',
        );
        expect(
          await chunks.listChunks(
            '$_vaultKey:chunks:${staged['pendingChunkGeneration']}',
          ),
          isEmpty,
        );
        await reopened.lock();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'native mixed-source group filters preserve counts across offline unlock',
    () async {
      const sources = [
        'youtube-transcript',
        'browser-history',
        'scanned-pdf',
        'photo',
        'email',
        'imap',
        'discord',
        'slack',
        'manual-text',
        'live-recording',
      ];
      for (var i = 0; i < 1000; i++) {
        await fixture.append(
          i,
          source: i < 900 ? 'manual-text' : sources[i % sources.length],
        );
      }
      var state = await fixture.open();
      Future<List<Conversation>> filtered(
        String source, {
        bool includeConsumed = true,
      }) async {
        final ready = Completer<void>();
        void changed() {
          if (!state.searchDetailsLoading && !ready.isCompleted) {
            ready.complete();
          }
        }

        state.addListener(changed);
        try {
          state.search(
            'archive',
            source: source,
            includeConsumed: includeConsumed,
          );
          changed();
          await ready.future.timeout(const Duration(seconds: 10));
          return state.search(
            'archive',
            source: source,
            includeConsumed: includeConsumed,
          );
        } finally {
          state.removeListener(changed);
        }
      }

      for (final group in SearchSourceGroup.values) {
        final found = await filtered(sourceGroupFilter(group));
        expect(found, hasLength(group == SearchSourceGroup.other ? 100 : 20));
        expect(found.every((c) => groupForSource(c.source) == group), isTrue);
        expect(state.searchError, isNull);
      }
      expect(await filtered('imap'), hasLength(10));
      expect(await filtered('group:consumed', includeConsumed: false), isEmpty);
      expect(state.conversations.every((c) => !c.isLoaded), isTrue);
      await state.lock();
      fixture.offline = true;
      state = await fixture.open(offline: true);
      expect(state.conversations, hasLength(1000));
      expect(await filtered('group:email'), hasLength(20));
      expect(await filtered('discord'), hasLength(10));
      expect(state.conversations.every((c) => !c.isLoaded), isTrue);
      await state.lock();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'native partial thread sync retains history and pending local metadata',
    () async {
      await fixture.seed(1000);
      var state = await fixture.open();
      Future<void> importMessage(
        String title,
        int channelType,
        String id,
        String text,
      ) async {
        expect(
          await state.importDiscordBotBatch(
            normalizeDiscordBotMessages(
              {
                'id': '123',
                'guild_id': '456',
                'name': title,
                'type': channelType,
              },
              [
                {
                  'id': id,
                  'author': {'id': '8', 'username': 'Alice'},
                  'content': text,
                  'timestamp': '2026-10-28T12:00:00Z',
                },
              ],
            ),
          ),
          isTrue,
        );
      }

      await importMessage('Original channel', 0, '101', 'historytopic');
      await state.pullSync();
      expect(state.pendingSyncCount, 0);
      final id = state.conversations
          .singleWhere((c) => c.sourceThreadId == 'discord:123')
          .id;
      final original = fixture.envelopes.singleWhere(
        (envelope) =>
            envelope['entityType'] == 'conversation' &&
            envelope['entityId'] == id,
      );
      final remote = await fixture.crypto.decryptJson(
        cipherText: original['cipherText'] as String,
        nonce: original['nonce'] as String,
      );
      expect(
        state.conversations.singleWhere((c) => c.id == id).isLoaded,
        isFalse,
      );
      await importMessage('Updated local channel', 1, '102', 'localtopic');
      final pushes = fixture.pushSizes.length;
      final sealed = await fixture.crypto.encryptJson({
        ...remote,
        'segments': [
          {
            ...Map<String, dynamic>.from(
              (remote['segments'] as List).single as Map,
            ),
            'id': 'remote-message-103',
            'sourceMessageId': '103',
            'text': 'remotetopic',
          },
        ],
      });
      fixture._append({
        ...original,
        'id': 'remote-partial-thread',
        'cipherText': sealed.cipherText,
        'nonce': sealed.nonce,
      });
      await state.syncQuietly();
      expect(state.syncError, isNull);
      expect(fixture.pushSizes, hasLength(pushes));
      expect(state.conversations, hasLength(1001));
      expect(state.conversations.every((c) => !c.isLoaded), isTrue);
      Future<void> verify() async {
        final merged = await state.loadConversation(id);
        expect(merged.title, 'Updated local channel');
        expect(merged.metadata['channelType'], '1');
        expect(merged.sourceThreadId, remote['sourceThreadId']);
        expect(
          merged.segments.map((s) => s.sourceMessageId),
          unorderedEquals(['101', '102', '103']),
        );
        for (final topic in ['historytopic', 'localtopic', 'remotetopic']) {
          expect((await state.searchAsync(topic)).map((c) => c.id), [id]);
        }
        final pending = ((await fixture.core())['pending'] as List).cast<Map>();
        final queued = pending.singleWhere(
          (e) => e['entityType'] == 'conversation' && e['entityId'] == id,
        );
        final payload = await fixture.crypto.decryptJson(
          cipherText: queued['cipherText'] as String,
          nonce: queued['nonce'] as String,
        );
        expect(payload['title'], 'Updated local channel');
        expect((payload['metadata'] as Map)['channelType'], '1');
        expect(
          (payload['segments'] as List).cast<Map>().map(
            (s) => s['sourceMessageId'],
          ),
          unorderedEquals(['101', '102', '103']),
        );
      }

      await verify();
      final pending = state.pendingSyncCount;
      expect(pending, greaterThan(0));
      await state.lock();
      fixture.offline = true;
      state = await fixture.open(offline: true);
      expect(state.pendingSyncCount, pending);
      await verify();
      expect(state.conversations.every((c) => !c.isLoaded), isTrue);
      await state.lock();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'native facet cache refreshes same-count edits, additions, and unlock',
    () async {
      await fixture.seed(1000);
      var state = await fixture.open();
      expect(state.availableSources, ['manual-text']);
      expect(state.allTags, isEmpty);
      expect(state.availableLocations, isEmpty);
      await fixture.append(
        7,
        updated: true,
        source: 'email',
        fields: {
          'tags': ['Edited'],
          'location': {'town': 'Berlin', 'venue': 'Studio'},
        },
      );
      await state.pullSync();
      expect(state.conversations, hasLength(1000));
      expect(state.availableSources, ['email', 'manual-text']);
      expect(state.allTags, ['Edited']);
      expect(state.locationFilterOptions.towns, ['Berlin']);
      expect(state.locationFilterOptions.places, ['Berlin Studio']);
      final locations = state.availableLocations;
      await state.searchAsync('archive');
      expect(identical(state.availableLocations, locations), isTrue);
      await fixture.append(
        1000,
        source: 'discord',
        fields: {
          'tags': ['New'],
        },
      );
      await state.pullSync();
      expect(state.availableSources, ['discord', 'email', 'manual-text']);
      expect(state.allTags, ['Edited', 'New']);
      await state.lock();
      expect(state.availableSources, isEmpty);
      expect(state.allTags, isEmpty);
      expect(state.availableLocations, isEmpty);
      fixture.offline = true;
      state = await fixture.open(offline: true);
      expect(state.availableSources, ['discord', 'email', 'manual-text']);
      expect(state.allTags, ['Edited', 'New']);
      expect(state.locationFilterOptions.towns, ['Berlin']);
      expect(state.locationFilterOptions.places, ['Berlin Studio']);
      await state.lock();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'failed retired-layout cleanup retries without deleting active chunks or audio',
    () async {
      await fixture.seed(1000);
      final original = await fixture.open();
      await original.addManualText(
        title: 'Unsent note',
        participantNames: '',
        text: 'unsentprivatemarker',
      );
      original
          .dispose(); // Restart from the committed core without another save.
      fixture.devices.remove(original);
      final saved = (await fixture.store.read(_vaultKey))!;
      final chunks = FileVaultChunkStore('${fixture.directory.path}/chunks');
      const retiredGeneration = 'retired-test';
      final retiredKey = '$_vaultKey:chunks:$retiredGeneration';
      final sealed = await fixture.crypto.encryptJson({'conversations': []});
      final record = {'cipherText': sealed.cipherText, 'nonce': sealed.nonce};
      await chunks.writeChunks(retiredKey, {0: record});
      await chunks.writeBlob(_vaultKey, 'audio-draft', record);
      final activeKey = saved['chunkGeneration'] == null
          ? _vaultKey
          : '$_vaultKey:chunks:${saved['chunkGeneration']}';
      final activeNonces = List<String>.from(saved['chunkNonces'] as List);
      final retired = {
        'generation': retiredGeneration,
        'count': 1,
        'storage': 'files',
      };
      await fixture.store.write(_vaultKey, {
        ...saved,
        'obsoleteChunkLayouts': [
          retired,
          {
            'generation': saved['chunkGeneration'],
            'count': saved['chunkCount'],
            'storage': 'files',
          },
        ],
      });
      final retiredDirectory = chunks.directoryFor(retiredKey);
      LifenizerAppState? reopened;
      try {
        expect(
          (await Process.run('chmod', ['500', retiredDirectory])).exitCode,
          0,
        );
        fixture.offline = true;
        reopened = await fixture.open(offline: true);
        expect(reopened.pendingSyncCount, 1);
        await _expectBodySearch(reopened);
        final body = await reopened.loadConversation('conversation-7');
        expect(body.segments.expand((s) => s.text.split(' ')), hasLength(200));
        expect(
          (await reopened.searchAsync('unsentprivatemarker')).single.title,
          'Unsent note',
        );
        final retained = (await fixture.store.read(_vaultKey))!;
        expect(retained['obsoleteChunkLayouts'], [retired]);
        expect(retained['cipherText'], saved['cipherText']);
        expect(retained['nonce'], saved['nonce']);
        expect(await chunks.listChunks(retiredKey), [0]);
        for (var n = 0; n < activeNonces.length; n++) {
          expect(await chunks.chunkNonce(activeKey, n), activeNonces[n]);
        }
        expect(await chunks.readBlob(_vaultKey, 'audio-draft'), record);
      } finally {
        expect(
          (await Process.run('chmod', ['700', retiredDirectory])).exitCode,
          0,
        );
      }
      await reopened.lock();
      expect(await chunks.listChunks(retiredKey), isEmpty);
      expect(
        (await fixture.store.read(_vaultKey))!['obsoleteChunkLayouts'],
        isNull,
      );
      for (var n = 0; n < activeNonces.length; n++) {
        expect(await chunks.chunkNonce(activeKey, n), activeNonces[n]);
      }
      expect(await chunks.readBlob(_vaultKey, 'audio-draft'), record);
      final verified = await fixture.open(offline: true);
      expect(verified.pendingSyncCount, 1);
      await _expectBodySearch(verified);
      await verified.lock();
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'concurrent save persists resident edits before their index update',
    () async {
      await fixture.seed(1000);
      final state = await fixture.open();
      Future<bool> importMessage(String title, String id, String text) =>
          state.importDiscordBotBatch(
            normalizeDiscordBotMessages(
              {'id': '123', 'guild_id': '456', 'name': title, 'type': 0},
              [
                {
                  'id': id,
                  'author': {'id': '8', 'username': 'Alice'},
                  'content': text,
                  'timestamp': '2026-10-28T12:00:00Z',
                },
              ],
            ),
          );
      expect(
        await importMessage('Original thread', '101', 'originaltopic'),
        isTrue,
      );
      await state.pullSync();
      final id = state.conversations
          .singleWhere((c) => c.sourceThreadId == 'discord:123')
          .id;
      fixture.draftWriteStarted = Completer<void>();
      fixture.draftWriteGate = Completer<void>();
      final firstSave = state.saveAudioDraft([1, 2, 3, 4], _date);
      await fixture.draftWriteStarted!.future.timeout(
        const Duration(seconds: 10),
      );
      final applied = Completer<void>();
      final finishEdit = Completer<void>();
      final secondSave = state.batchVaultChanges(() async {
        expect(
          await importMessage('Latest thread', '102', 'newesttopic'),
          isTrue,
        );
        applied.complete();
        await finishEdit.future;
      });
      try {
        await applied.future.timeout(const Duration(seconds: 10));
        final latest = state.conversations.singleWhere((c) => c.id == id);
        expect(latest.isLoaded, isTrue);
        expect(latest.segments, hasLength(2));
        fixture.draftWriteGate!.complete();
        await firstSave;
        finishEdit.complete();
        await secondSave;
      } finally {
        if (!fixture.draftWriteGate!.isCompleted) {
          fixture.draftWriteGate!.complete();
        }
        if (!finishEdit.isCompleted) finishEdit.complete();
        await Future.wait([firstSave, secondSave]);
      }
      expect(state.error, isNull);
      expect((await state.searchAsync('newesttopic')).single.id, id);
      state.dispose();
      fixture.devices.remove(state);
      final disk = await DiskSearchIndex.open(
        path: (await fixture.indexFile()).path,
        vaultKey: _deviceKey,
      );
      await disk.writeMetadata('snapshotNonce', 'verify-canonical-chunk');
      await disk.close();
      fixture.offline = true;
      final reopened = await fixture.open(offline: true);
      final restored = await reopened.loadConversation(id);
      expect(restored.title, 'Latest thread');
      expect(
        restored.segments.map((s) => s.sourceMessageId),
        unorderedEquals(['101', '102']),
      );
      expect((await reopened.searchAsync('originaltopic')).single.id, id);
      expect((await reopened.searchAsync('newesttopic')).single.id, id);
      expect(await reopened.loadAudioDraftPayload(), [1, 2, 3, 4]);
      expect(reopened.pendingSyncCount, greaterThan(0));
      await reopened.lock();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'failed lock allows the canceled query to run again',
    () async {
      await fixture.seed(1000);
      final state = await fixture.open();
      final lookup = state.searchAsync('archive');
      state.stopRecording = () async {
        await lookup;
      };
      fixture.failNextCoreWrite = true;
      await state.lock();
      expect(await lookup, isEmpty);
      expect(state.isAuthenticated, isTrue);
      expect(state.error, contains('Injected core write failure'));
      expect(await state.searchAsync('archive'), hasLength(100));
      state.stopRecording = null;
      await state.lock();
      expect(state.isAuthenticated, isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
