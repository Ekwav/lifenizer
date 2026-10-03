import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/widgets/microphone_panel.dart';
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
  Future<Map<String, dynamic>?> read(String key) async => records[key];
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    if (failWrites) throw StateError('Disk full');
    records[key] = Map<String, dynamic>.from(value);
  }
}

class _Vault {
  _Vault(this.store, this.client, this.state);
  final _MemoryStore store;
  final MockClient client;
  final LifenizerAppState state;
  static const key =
      'vault:["https://vault.example.test","alice@example.test"]';
  static Future<_Vault> open() async {
    final store = _MemoryStore();
    final client = MockClient((request) async {
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
    });
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
  tearDown(() => RecordPlatform.instance = previous);

  Future<_Vault> mount(WidgetTester tester) async {
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
  Future<void> verifyDraft(_Vault vault) async {
    final draft = vault.state.audioDraft!;
    final wav = base64Decode(draft['payload'] as String);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
    expect(wav.sublist(44), samples);
    expect(DateTime.parse(draft['recordedAt'] as String).isUtc, isTrue);
    final raw = jsonEncode(await vault.store.read(_Vault.key));
    expect(raw, isNot(contains(draft['payload'] as String)));
    expect(raw, isNot(contains('private-vault-passphrase')));
    expect(raw, isNot(contains('audioDraft')));
  }

  Future<void> finish(WidgetTester tester, Future<void> operation) async {
    var completed = false;
    operation.then((_) => completed = true);
    for (var i = 0; i < 100 && !completed; i++) {
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

  Future<void> remove(WidgetTester tester, _Vault vault) async {
    await tester.pumpWidget(const SizedBox());
    await finish(tester, recorder.disposed.future);
    vault.close();
  }

  testWidgets('stop saves every PCM sample in an encrypted WAV draft', (
    tester,
  ) async {
    final vault = await mount(tester);
    await start(tester);
    expect(find.textContaining('Recording ·'), findsOneWidget);
    recorder.pcm.add(samples);
    await tester.pump();
    await tester.tap(find.text('Stop and save recording'));
    await tester.pump();
    await finish(tester, vault.state.stopRecording!());
    await tester.pump();
    await verifyDraft(vault);
    expect(
      find.text(
        'Recording saved encrypted on this device. Ready to transcribe.',
      ),
      findsOneWidget,
    );
    expect(recorder.stops, 1);
    await remove(tester, vault);
  });

  testWidgets(
    'navigation disposes recorder after preserving the captured draft',
    (tester) async {
      final vault = await mount(tester);
      await start(tester);
      recorder.pcm.add(samples);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await finish(tester, recorder.disposed.future);
      await verifyDraft(vault);
      expect(vault.state.stopRecording, isNull);
      vault.close();
    },
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
      await verifyDraft(vault);
      expect(recorder.stops, 1);
      await remove(tester, vault);
    },
  );

  testWidgets('disk-full stop preserves the recording until lock can save it', (
    tester,
  ) async {
    final vault = await mount(tester);
    await start(tester);
    recorder.pcm.add(samples);
    await tester.pump();
    vault.store.failWrites = true;
    await finish(tester, vault.state.lock());
    expect(vault.state.isAuthenticated, isTrue);
    expect(vault.state.error, contains('Disk full'));
    expect(
      base64Decode(vault.state.audioDraft!['payload'] as String).sublist(44),
      samples,
    );
    vault.store.failWrites = false;
    await finish(tester, vault.state.lock());
    expect(vault.state.isAuthenticated, isFalse);
    await finish(tester, vault.unlock(offline: true));
    await verifyDraft(vault);
    await remove(tester, vault);
  });

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
  );

  testWidgets('background pause saves the active recording', (tester) async {
    final vault = await mount(tester);
    await start(tester);
    recorder.pcm.add(samples);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await finish(tester, vault.state.stopRecording!());
    await tester.pump();
    await verifyDraft(vault);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await remove(tester, vault);
  });

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
  );
}
