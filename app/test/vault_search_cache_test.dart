import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/sync_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

class _Store extends LocalVaultStore {
  _Store(super.database);
  final detailReads = <String>[];
  Completer<void>? gate;
  bool corruptDetails = false;
  bool failCoreWrites = false;
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    if (failCoreWrites && value['format'] == 2) {
      throw StateError('Injected core write failure');
    }
    await super.write(key, value);
  }

  @override
  Future<Map<String, dynamic>?> read(String key) async {
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

  setUp(() async {
    database = await databaseFactoryMemory.openDatabase(
      'search-cache-regression-${sequence++}',
    );
    store = _Store(database);
    final original = await open(offline: false);
    original.conversations.addAll(
      List.generate(
        256,
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
  });
  tearDown(() => database.close());

  test(
    'duplicate queries share detail reads and lock does not wait for them',
    () async {
      final restored = await open();
      store.gate = Completer<void>();
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
      expect(
        restored.conversations.any((conversation) => !conversation.isLoaded),
        isTrue,
      );
      await restored.lock();
      restored.dispose();
      final reopened = await open();
      expect(reopened.conversations, hasLength(257));
      expect(reopened.search('zebralantern').single.id, 'thread-7');
      await until(reopened, () => !reopened.searchDetailsLoading);
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
}
