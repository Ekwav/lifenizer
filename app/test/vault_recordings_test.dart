import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/crypto_service.dart';
import 'package:app/models.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/audio_cache_io.dart' as cache;
import 'package:app/services/recording_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sembast/sembast_memory.dart';

const _base = 'https://recordings.example.test';
const _email = 'audio@example.test';
const _phrase = 'private audio passphrase';
const _salt = 'audio-salt';
final _key = 'vault:${jsonEncode([_base, _email])}';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _RequestStream extends http.BaseClient {
  final events = StreamController<List<int>>();
  final connected = Completer<void>();
  final answered = Completer<Map<String, dynamic>>();
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET') {
      expect(request.headers['authorization'], 'Bearer token');
      if (!connected.isCompleted) connected.complete();
      return http.StreamedResponse(events.stream, 200);
    }
    final bytes = await request.finalize().toBytes();
    if (!answered.isCompleted) {
      answered.complete(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    }
    return http.StreamedResponse(const Stream.empty(), 200);
  }

  @override
  void close() {
    closed = true;
    unawaited(events.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform paths;
  late VaultCrypto crypto;
  late Map<String, Map<String, dynamic>> online;
  late List<String> requests;
  Future<void>? fetchGate;
  Completer<void>? fetching;
  var databases = 0;
  var failRecordingWrites = false;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lifenizer-recordings-');
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    crypto = VaultCrypto();
    await crypto.unlock(email: _email, passphrase: _phrase, vaultSalt: _salt);
    online = {};
    requests = [];
    fetchGate = null;
    fetching = null;
    failRecordingWrites = false;
  });
  tearDown(() async {
    crypto.lock();
    PathProviderPlatform.instance = paths;
    await directory.delete(recursive: true);
  });
  Future<LifenizerAppState> device({String base = _base}) async {
    final database = await databaseFactoryMemory.openDatabase(
      'audio-${databases++}',
    );
    addTearDown(database.close);
    final state = LifenizerAppState(
      localStore: LocalVaultStore(database),
      apiFactory: (url) => LifenizerApiClient(
        baseUrl: url,
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (path.startsWith('/api/auth/')) {
            return http.Response(
              jsonEncode({
                'authToken': 'token',
                'userId': 'user',
                'vaultId': 'vault',
                'vaultSalt': _salt,
              }),
              200,
            );
          }
          if (path == '/api/imports/capabilities') {
            return http.Response('[]', 200);
          }
          if (path == '/api/imports/audio') {
            final input = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'source': 'audio',
                'message': 'Transcribed recording',
                'participants': [],
                'conversations': [
                  {
                    'source': 'audio',
                    'title': input['title'],
                    'participantNames': [],
                    'segments': [
                      {
                        'text': 'Remember the telescope tomorrow',
                        'createdAt': input['metadata']['recordedAt'],
                      },
                    ],
                  },
                ],
              }),
              200,
            );
          }
          if (path == '/api/sync/push') {
            return http.Response('{"cursor":0}', 200);
          }
          if (path == '/api/sync/pull') {
            return http.Response('{"cursor":0,"envelopes":[]}', 200);
          }
          if (path.startsWith('/api/recordings/')) {
            expect(request.headers['authorization'], 'Bearer token');
            final id = path.split('/').last;
            if (failRecordingWrites && request.method != 'GET') {
              return http.Response('offline', 503);
            }
            if (request.method == 'PUT') {
              online[id] = jsonDecode(request.body) as Map<String, dynamic>;
              expect(online[id]!.keys.toSet(), {
                'cipherText',
                'nonce',
                'keyId',
              });
              expect(online[id]!['keyId'], VaultCrypto.keyId);
              expect(request.body, isNot(contains('private-audio')));
              return http.Response('', 200);
            }
            if (request.method == 'DELETE') {
              final existed = online.remove(id) != null;
              return http.Response('', existed ? 204 : 404);
            }
            if (fetching != null && !fetching!.isCompleted) {
              fetching!.complete();
            }
            await fetchGate;
            return http.Response(
              online.containsKey(id) ? jsonEncode(online[id]) : '{}',
              online.containsKey(id) ? 200 : 404,
            );
          }
          return http.Response('not found', 404);
        }),
      ),
    );
    addTearDown(state.dispose);
    await state.login(
      baseUrl: base,
      email: _email,
      password: 'account-password',
      passphrase: _phrase,
    );
    expect(state.error, isNull);
    return state;
  }

  Conversation audio(String id) => Conversation(
    id: id,
    title: 'Voice memo',
    source: 'audio',
    participantIds: [],
    segments: [],
  );
  Future<Map<String, dynamic>> envelope(
    String id, {
    String vault = 'vault',
  }) async {
    final encrypted = await crypto.encryptJson({
      'vaultId': vault,
      'conversationId': id,
      'bytes': base64Encode(utf8.encode('private-audio')),
      'contentType': 'audio/mpeg',
      'fileName': 'memo.mp3',
    });
    return {
      'cipherText': encrypted.cipherText,
      'nonce': encrypted.nonce,
      'keyId': encrypted.keyId,
    };
  }

  test(
    'a draft is retained without transcription, cached encrypted, and online storage stays opt-in',
    () async {
      final state = await device();
      await state.saveAudioDraft([1, 2, 3], DateTime.utc(2026, 10, 1));
      await state.updateAudioDraftDetails(
        title: 'Walk memo',
        participantNames: ['Alice'],
      );
      expect(await state.retainAudioDraft(), true);
      expect(state.audioDraft, isNull);
      final recording = state.conversations.single;
      expect(recording.source, 'audio');
      expect(recording.title, 'Walk memo');
      expect(recording.segments, isEmpty);
      expect(recording.participantIds, hasLength(1));
      expect((await state.loadRecordingAudio(recording.id)).bytes, [1, 2, 3]);
      expect(online, isEmpty);
      expect(requests.where((r) => r.contains('/api/imports/audio')), isEmpty);
      final saved = await cache.readAudioCache('$_key:audio:${recording.id}');
      expect(saved!.keys.toSet(), {'cipherText', 'nonce'});
      await state.setRecordingOnlineSync(recording.id, true);
      expect(online, contains(recording.id));
      expect(state.conversations.single.metadata['recordingSync'], 'true');
      await state.setRecordingOnlineSync(recording.id, false);
      expect(online, isEmpty);
      expect(state.conversations.single.metadata['recordingSync'], 'false');
      await state.setRecordingOnlineSync(recording.id, false);
      expect(state.conversations.single.metadata['recordingSync'], 'false');
    },
  );

  test(
    'online storage intent survives failed requests and unlock, then retries',
    () async {
      final state = await device();
      await state.importPendingRecording(
        [1, 2, 3],
        DateTime.utc(2026),
        'retry',
      );
      final id = state.conversations.single.id;
      failRecordingWrites = true;
      await expectLater(
        state.setRecordingOnlineSync(id, true),
        throwsStateError,
      );
      expect(state.pendingRecordingOnlineSync(id), true);
      expect(state.conversations.single.metadata['recordingSync'], isNull);
      expect(online, isEmpty);
      await state.lock();
      await state.login(
        baseUrl: _base,
        email: _email,
        passphrase: _phrase,
        offline: true,
      );
      await state.waitForBackgroundSync();
      expect(state.pendingRecordingOnlineSync(id), true);
      expect(state.conversations.single.metadata['recordingSync'], isNull);
      failRecordingWrites = false;
      final pushesBefore = requests
          .where((r) => r == 'POST /api/sync/push')
          .length;
      await state.pullSync();
      expect(state.error, isNull);
      // Explicit sync publishes both the capture and confirmed storage state.
      expect(
        requests.where((r) => r == 'POST /api/sync/push').length,
        pushesBefore + 2,
      );
      expect(state.pendingRecordingOnlineSync(id), isNull);
      expect(state.conversations.single.metadata['recordingSync'], 'true');
      expect(online, contains(id));
      failRecordingWrites = true;
      await expectLater(
        state.setRecordingOnlineSync(id, false),
        throwsStateError,
      );
      expect(state.pendingRecordingOnlineSync(id), false);
      expect(state.conversations.single.metadata['recordingSync'], 'true');
      expect((await state.loadRecordingAudio(id)).bytes, [1, 2, 3]);
      await state.syncQuietly();
      expect(state.pendingRecordingOnlineSync(id), false);
      expect(state.syncError, contains('Sync paused'));
      failRecordingWrites = false;
      await state.syncQuietly();
      expect(state.pendingRecordingOnlineSync(id), isNull);
      expect(state.conversations.single.metadata['recordingSync'], 'false');
      expect(state.syncError, isNull);
      expect(online, isEmpty);
      expect((await state.loadRecordingAudio(id)).bytes, [1, 2, 3]);
      await state.lock();
      await state.login(
        baseUrl: _base,
        email: _email,
        passphrase: _phrase,
        offline: true,
      );
      await state.waitForBackgroundSync();
      expect(state.pendingRecordingOnlineSync(id), isNull);
    },
  );

  test(
    'service capture persists once across unlock and preserves a draft',
    () async {
      final state = await device();
      final recordedAt = DateTime.utc(2026, 10, 20);
      await state.saveAudioDraft([9, 8, 7], recordedAt);
      await state.importPendingRecording([1, 2, 3], recordedAt, 'native-1');
      final id = state.conversations.single.id;
      expect(state.search('Voice recording').single.id, id);
      expect(await state.loadAudioDraftPayload(), [9, 8, 7]);
      expect(online, isEmpty);
      expect(requests.where((r) => r.contains('/api/imports/audio')), isEmpty);
      await state.lock();
      expect(state.isAuthenticated, false);
      await expectLater(
        state.importPendingRecording([1, 2, 3], recordedAt, 'native-2'),
        throwsStateError,
      );
      await state.login(
        baseUrl: _base,
        email: _email,
        passphrase: _phrase,
        offline: true,
      );
      await state.waitForBackgroundSync();
      expect(state.error, isNull);
      expect(state.conversations.single.id, id);
      expect((await state.loadRecordingAudio(id)).bytes, [1, 2, 3]);
      await state.importPendingRecording([1, 2, 3], recordedAt, 'native-1');
      expect(state.conversations.single.id, id);
      expect(state.conversations.single.startedAt, recordedAt);
      expect(await state.loadAudioDraftPayload(), [9, 8, 7]);
      state.busy = true;
      await expectLater(
        state.importPendingRecording([1], recordedAt, 'native-2'),
        throwsStateError,
      );
      state.busy = false;
    },
  );

  test(
    'saved capture gains a searchable transcript without duplicating audio',
    () async {
      final state = await device();
      final recordedAt = DateTime.utc(2026, 10, 20);
      await state.importPendingRecording([1, 2, 3], recordedAt, 'native-1');
      final id = state.conversations.single.id;
      await state.transcribeRecording(id);
      expect(state.conversations.single.id, id);
      expect(state.conversations.single.startedAt, recordedAt);
      expect(state.search('telescope').single.id, id);
      expect((await state.loadRecordingAudio(id)).bytes, [1, 2, 3]);
      // A recovery acknowledgement retry must preserve the new transcript.
      await state.importPendingRecording([1, 2, 3], recordedAt, 'native-1');
      expect(state.search('telescope').single.id, id);
      expect(
        requests.where((r) => r.contains('/api/imports/audio')),
        hasLength(1),
      );
      await expectLater(state.transcribeRecording(id), throwsStateError);
    },
  );

  test('empty draft retention keeps the draft and reports failure', () async {
    final state = await device();
    await state.saveAudioDraft([], DateTime.utc(2026));
    expect(await state.retainAudioDraft(), false);
    expect(state.audioDraft, isNotNull);
    expect(state.conversations, isEmpty);
  });

  test(
    'remote encrypted audio works across server URLs and then plays from encrypted local cache',
    () async {
      final state = await device(base: 'https://another-address.example.test');
      state.conversations.add(audio('remote'));
      online['remote'] = await envelope('remote');
      final loaded = await state.loadRecordingAudio('remote');
      expect(loaded.bytes, utf8.encode('private-audio'));
      expect(loaded.contentType, 'audio/mpeg');
      expect(loaded.fileName, 'memo.mp3');
      online.clear();
      expect((await state.loadRecordingAudio('remote')).bytes, loaded.bytes);
      expect(
        requests.where((r) => r == 'GET /api/recordings/remote'),
        hasLength(1),
      );
    },
  );

  test(
    'rejects another vault or conversation and never caches mismatched audio',
    () async {
      final state = await device();
      state.conversations.add(audio('remote'));
      online['remote'] = await envelope('remote', vault: 'other');
      await expectLater(state.loadRecordingAudio('remote'), throwsStateError);
      online['remote'] = await envelope('different');
      await expectLater(state.loadRecordingAudio('remote'), throwsStateError);
      online['remote'] = (await envelope('remote'))..remove('keyId');
      await expectLater(state.loadRecordingAudio('remote'), throwsStateError);
      expect(await cache.readAudioCache('$_key:audio:remote'), isNull);
    },
  );

  test(
    'legacy WAV cache remains playable and live relay serves only local known audio',
    () async {
      final state = await device();
      state.conversations.add(audio('legacy'));
      final encrypted = await crypto.encryptJson({
        'vaultKey': _key,
        'conversationId': 'legacy',
        'bytes': base64Encode([4, 5, 6]),
      });
      await cache.writeAudioCache('$_key:audio:legacy', {
        'cipherText': encrypted.cipherText,
        'nonce': encrypted.nonce,
      });
      final loaded = await state.loadRecordingAudio('legacy');
      expect(loaded.contentType, 'audio/wav');
      expect(loaded.fileName, 'recording.wav');
      expect(await state.encryptedRecordingForRelay('unknown'), isNull);
      final stream = _RequestStream();
      final relay = RecordingRelayService(state, clientFactory: () => stream)
        ..start();
      addTearDown(relay.dispose);
      await stream.connected.future;
      stream.events.add(
        utf8.encode(
          'event: request\ndata: {"requestId":"request","conversationId":"legacy"}\n\n',
        ),
      );
      final sent = await stream.answered.future.timeout(
        const Duration(seconds: 5),
      );
      final value = await crypto.decryptJson(
        cipherText: sent['cipherText'] as String,
        nonce: sent['nonce'] as String,
      );
      expect(value['vaultId'], 'vault');
      expect(value['conversationId'], 'legacy');
      expect(base64Decode(value['bytes'] as String), [4, 5, 6]);
      await state.lock();
      expect(stream.closed, true);
    },
  );

  test(
    'SSE rejects a multi-line event exceeding the total event bound',
    () async {
      final stream = _RequestStream();
      final api = LifenizerApiClient(baseUrl: _base, authToken: 'token');
      final event = api.recordingRequests(stream).first;
      await stream.connected.future;
      stream.events.add(
        utf8.encode(
          'event: request\ndata: ${'a' * 4000}\ndata: ${'b' * 4000}\ndata: ${'c' * 4000}\n\n',
        ),
      );
      await expectLater(event, throwsFormatException);
      stream.close();
    },
  );

  test(
    'locking while a remote download is pending prevents late playback or cache writes',
    () async {
      final state = await device();
      state.conversations.add(audio('remote'));
      online['remote'] = await envelope('remote');
      final gate = Completer<void>();
      fetchGate = gate.future;
      fetching = Completer<void>();
      final pending = state.loadRecordingAudio('remote');
      await fetching!.future;
      await state.lock();
      gate.complete();
      await expectLater(pending, throwsStateError);
      expect(await cache.readAudioCache('$_key:audio:remote'), isNull);
    },
  );
}
