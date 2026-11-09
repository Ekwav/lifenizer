import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/widgets/microphone_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:record/record.dart';
import 'package:sembast/sembast.dart';

class _Recorder extends RecordPlatform {
  final pcm = StreamController<Uint8List>.broadcast(sync: true);
  final disposed = Completer<void>();
  bool permission = true;
  Completer<void>? startGate;
  Completer<void>? stopGate;
  int starts = 0;
  int stops = 0;
  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();
  @override
  Future<void> create(String recorderId) async {}
  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      permission;
  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    starts++;
    await startGate?.future;
    return pcm.stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
    stops++;
    await stopGate?.future;
    await pcm.close();
    return null;
  }

  @override
  Future<void> dispose(String recorderId) async {
    if (!pcm.isClosed) await pcm.close();
    disposed.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Database extends Fake implements Database {}

class _MemoryStore extends LocalVaultStore {
  _MemoryStore() : super(_Database());
  final records = <String, Map<String, dynamic>>{};
  bool failWrites = false;
  @override
  Future<void> deleteMany(Iterable<String> keys) async {
    keys.forEach(records.remove);
  }

  @override
  Future<Map<String, dynamic>?> read(String key) async => records[key];
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    if (failWrites) throw StateError('Disk full');
    records[key] = Map<String, dynamic>.from(value);
  }
}

const _uploadPath = '/api/imports/audio/upload';

/// Holds audio uploads open until their abort trigger fires, like a server
/// still transcribing a long recording.
class _HangingAudioClient extends http.BaseClient {
  _HangingAudioClient(this._inner);
  final http.Client _inner;
  final uploading = Completer<void>();
  final aborted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path != _uploadPath) return _inner.send(request);
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    if (trigger == null) throw StateError('Audio upload is not abortable.');
    uploading.complete();
    await trigger;
    aborted.complete();
    throw http.RequestAbortedException(request.url);
  }

  @override
  void close() => _inner.close();
}

class _Vault {
  _Vault(this.store, this.client, this.state);
  final _MemoryStore store;
  final _HangingAudioClient client;
  final LifenizerAppState state;
  static const key =
      'vault:["https://vault.example.test","alice@example.test"]';
  static Future<_Vault> open() async {
    final store = _MemoryStore();
    final client = _HangingAudioClient(
      MockClient((request) async {
        if (request.url.path.startsWith('/api/auth/')) {
          return http.Response(
            jsonEncode({
              'authToken': 'token',
              'userId': 'user',
              'vaultId': 'vault',
              'vaultSalt': 'salt',
            }),
            200,
          );
        }
        if (request.url.path == '/api/imports/capabilities') {
          return http.Response('[]', 200);
        }
        return http.Response('{"cursor":0,"envelopes":[]}', 200);
      }),
    );
    final state = LifenizerAppState(
      localStore: store,
      apiFactory: (url) => LifenizerApiClient(baseUrl: url, client: client),
    );
    final vault = _Vault(store, client, state);
    await vault.unlock();
    return vault;
  }

  Future<void> unlock({bool offline = false}) => state.login(
    baseUrl: 'https://vault.example.test',
    email: 'alice@example.test',
    password: 'account-password',
    passphrase: 'private-vault-passphrase',
    offline: offline,
  );
  void close() {
    state.dispose();
    client.close();
  }
}

void main() {
  late RecordPlatform previous;
  late _Recorder recorder;
  setUp(() {
    previous = RecordPlatform.instance;
    recorder = _Recorder();
    RecordPlatform.instance = recorder;
  });
  tearDown(() {
    RecordPlatform.instance = previous;
  });

  Future<_Vault> mount(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final vault = (await tester.runAsync(_Vault.open))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: vault.state,
            builder: (context, child) => MicrophonePanel(state: vault.state),
          ),
        ),
      ),
    );
    return vault;
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.text('Start microphone recording'));
    await tester.pump();
  }

  final samples = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
  Future<void> verifyDraft(WidgetTester tester, _Vault vault) async {
    final draft = vault.state.audioDraft!;
    final wav = (await tester.runAsync(vault.state.loadAudioDraftPayload))!;
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
    expect(wav.sublist(44), samples);
    expect(DateTime.parse(draft['recordedAt'] as String).isUtc, isTrue);
    final raw = jsonEncode(await vault.store.read(_Vault.key));
    expect(raw, isNot(contains(base64Encode(wav))));
    expect(raw, isNot(contains('private-vault-passphrase')));
    expect(raw, isNot(contains('audioDraft')));
  }

  Future<void> finish(WidgetTester tester, Future<void> operation) async {
    var completed = false;
    operation.then((_) => completed = true);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!completed && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(
      completed,
      isTrue,
      reason: 'Recording lifecycle operation did not complete',
    );
  }

  Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(condition(), isTrue, reason: 'Condition not reached in time');
  }

  Future<void> remove(WidgetTester tester, _Vault vault) async {
    await tester.pumpWidget(const SizedBox());
    await finish(tester, vault.state.recording.stop());
    vault.close();
    await finish(tester, recorder.disposed.future);
  }

  testWidgets(
    'stop saves every PCM sample in an encrypted WAV draft',
    (tester) async {
      final vault = await mount(tester);
      await start(tester);
      expect(find.textContaining('Recording ·'), findsOneWidget);
      recorder.pcm.add(samples);
      await tester.pump();
      await tester.tap(find.text('Stop and save recording'));
      await tester.pump();
      await finish(tester, vault.state.stopRecording!());
      await tester.pump();
      await verifyDraft(tester, vault);
      expect(
        find.text(
          'Recording saved encrypted on this device. Ready to transcribe.',
        ),
        findsOneWidget,
      );
      expect(recorder.stops, 1);
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'recording can stop while an unrelated operation is busy',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final vault = await mount(tester);
      vault.state.addListener(() {
        vault.state.audioDraft?['detailsPrompted'] = true;
      });
      await start(tester);
      recorder.pcm.add(samples);
      vault.state.busy = true;
      vault.state.reportError('Import in progress');
      await tester.pump();
      final stop = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Stop and save recording'),
      );
      expect(stop.onPressed, isNotNull);
      await tester.tap(find.text('Stop and save recording'));
      await finish(tester, vault.state.recording.stop());
      vault.state.audioDraft!['detailsPrompted'] = true;
      await tester.pump();
      await verifyDraft(tester, vault);
      vault.state.busy = false;
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'discard asks first and cannot discard a replacement recording',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final vault = await mount(tester);
      vault.state.addListener(() {
        vault.state.audioDraft?['detailsPrompted'] = true;
      });
      await start(tester);
      recorder.pcm.add(samples);
      await finish(tester, vault.state.recording.stop());
      vault.state.audioDraft!['detailsPrompted'] = true;
      await tester.pump();
      await tester.ensureVisible(find.text('Discard recording'));
      await tester.tap(find.text('Discard recording'));
      await tester.pumpAndSettle();
      expect(find.text('Discard recording?'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(vault.state.audioDraft, isNotNull);
      await tester.tap(find.text('Discard recording'));
      await tester.pumpAndSettle();
      final replacement = {...vault.state.audioDraft!, 'title': 'Replacement'};
      vault.state.audioDraft = replacement;
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(vault.state.audioDraft, same(replacement));
      final discardButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Discard recording'),
      );
      final discard = (discardButton.onPressed! as Future<void> Function())();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await finish(tester, discard);
      expect(vault.state.audioDraft, isNull);
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'desktop navigation saves the draft while app state retains the recorder',
    (tester) async {
      final vault = await mount(tester);
      await start(tester);
      recorder.pcm.add(samples);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await finish(tester, vault.state.recording.stop());
      await verifyDraft(tester, vault);
      expect(recorder.disposed.isCompleted, isFalse);
      expect(vault.state.stopRecording, isNotNull);
      vault.close();
      await finish(tester, recorder.disposed.future);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'locking waits for an in-progress stop and restores its saved draft offline',
    (tester) async {
      final vault = await mount(tester);
      await start(tester);
      recorder.pcm.add(samples);
      await tester.pump();
      recorder.stopGate = Completer<void>();
      await tester.tap(find.text('Stop and save recording'));
      await tester.pump();
      final locking = vault.state.lock();
      await tester.pump();
      expect(vault.state.isAuthenticated, isTrue);
      expect(vault.state.busy, isTrue);
      recorder.stopGate!.complete();
      await finish(tester, locking);
      expect(vault.state.isAuthenticated, isFalse);
      expect(vault.state.audioDraft, isNull);
      await finish(tester, vault.unlock(offline: true));
      await verifyDraft(tester, vault);
      expect(recorder.stops, 1);
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'disk-full stop preserves the recording until lock can save it',
    (tester) async {
      final vault = await mount(tester);
      await start(tester);
      recorder.pcm.add(samples);
      await tester.pump();
      vault.store.failWrites = true;
      await finish(tester, vault.state.lock());
      expect(vault.state.isAuthenticated, isTrue);
      expect(vault.state.error, contains('Disk full'));
      expect((await vault.state.loadAudioDraftPayload())!.sublist(44), samples);
      vault.store.failWrites = false;
      await finish(tester, vault.state.lock());
      expect(vault.state.isAuthenticated, isFalse);
      await finish(tester, vault.unlock(offline: true));
      await verifyDraft(tester, vault);
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'denied microphone permission explains why recording is unavailable',
    (tester) async {
      final vault = await mount(tester);
      recorder.permission = false;
      await start(tester);
      expect(
        find.textContaining('Microphone permission was denied'),
        findsOneWidget,
      );
      expect(recorder.starts, 0);
      expect(vault.state.audioDraft, isNull);
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'hidden desktop window or browser tab saves recording',
    (tester) async {
      final vault = await mount(tester);
      await start(tester);
      recorder.pcm.add(samples);
      await tester.pump();
      final saved = Completer<void>();
      void onSaved() {
        if (vault.state.audioDraft != null && !saved.isCompleted) {
          saved.complete();
        }
      }

      vault.state.addListener(onSaved);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await finish(tester, saved.future);
      vault.state.removeListener(onSaved);
      expect(recorder.stops, 1);
      await verifyDraft(tester, vault);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'background pause saves the active recording',
    (tester) async {
      final vault = await mount(tester);
      await start(tester);
      recorder.pcm.add(samples);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await finish(tester, vault.state.stopRecording!());
      await tester.pump();
      await verifyDraft(tester, vault);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'background pause during startup does not leave a live recorder',
    (tester) async {
      final vault = await mount(tester);
      recorder.startGate = Completer<void>();
      await start(tester);
      expect(recorder.starts, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      recorder.startGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(recorder.stops, 1);
      expect(find.textContaining('Recording ·'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'cancel aborts a running transcription and keeps the draft',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final vault = await mount(tester);
      vault.state.addListener(() {
        vault.state.audioDraft?['detailsPrompted'] = true;
      });
      await start(tester);
      recorder.pcm.add(samples);
      await finish(tester, vault.state.recording.stop());
      vault.state.audioDraft!['detailsPrompted'] = true;
      await tester.pump();
      expect(find.byKey(const Key('cancel-transcription')), findsNothing);
      await tester.ensureVisible(find.text('Send to Whisper and transcribe'));
      await tester.tap(find.text('Send to Whisper and transcribe'));
      await waitFor(tester, () => vault.client.uploading.isCompleted);
      await tester.pump();
      expect(vault.state.busy, isTrue);
      final cancel = find.byKey(const Key('cancel-transcription'));
      expect(cancel, findsOneWidget);
      expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await waitFor(tester, () => !vault.state.busy);
      await tester.pump();
      expect(vault.client.aborted.isCompleted, isTrue);
      expect(vault.state.error, isNull);
      expect(vault.state.status, 'Transcription cancelled.');
      expect(vault.state.audioDraft, isNotNull);
      expect(vault.state.conversations, isEmpty);
      expect(cancel, findsNothing);
      await verifyDraft(tester, vault);
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'locking cancels a running transcription and keeps the draft',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final vault = await mount(tester);
      vault.state.addListener(() {
        vault.state.audioDraft?['detailsPrompted'] = true;
      });
      await start(tester);
      recorder.pcm.add(samples);
      await finish(tester, vault.state.recording.stop());
      vault.state.audioDraft!['detailsPrompted'] = true;
      await tester.pump();
      await tester.ensureVisible(find.text('Send to Whisper and transcribe'));
      await tester.tap(find.text('Send to Whisper and transcribe'));
      await waitFor(tester, () => vault.client.uploading.isCompleted);

      await finish(tester, vault.state.lock());

      expect(vault.client.aborted.isCompleted, isTrue);
      expect(vault.state.isAuthenticated, isFalse);
      await finish(tester, vault.unlock(offline: true));
      await tester.pump();
      expect(vault.state.audioDraft, isNotNull);
      expect(vault.state.conversations, isEmpty);
      await verifyDraft(tester, vault);
      await remove(tester, vault);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
