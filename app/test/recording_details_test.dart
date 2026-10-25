import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/storage_location.dart';
import 'package:app/widgets/microphone_panel.dart';
import 'package:app/widgets/recording_details_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:record/record.dart';
import 'package:sembast/sembast.dart' hide Finder;

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

class _Vault {
  _Vault(this.store, this.client, this.state);
  final _MemoryStore store;
  final MockClient client;
  final LifenizerAppState state;
  static Future<_Vault> open({
    Future<http.Response?> Function(http.Request request)? handler,
  }) async {
    final store = _MemoryStore();
    final client = MockClient((request) async {
      final custom = await handler?.call(request);
      if (custom != null) return custom;
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
    vaultStorageDescriber = () async => '…/share/lifenizer/app_data';
  });
  tearDown(() {
    RecordPlatform.instance = previous;
  });

  Widget app(_Vault vault) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: AnimatedBuilder(
          animation: vault.state,
          builder: (context, child) => MicrophonePanel(state: vault.state),
        ),
      ),
    ),
  );

  Future<_Vault> mount(
    WidgetTester tester, {
    Future<http.Response?> Function(http.Request request)? handler,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final vault = (await tester.runAsync(() => _Vault.open(handler: handler)))!;
    await tester.pumpWidget(app(vault));
    return vault;
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() condition, [
    String label = '',
  ]) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    if (!condition()) {
      fail(
        'condition not reached: ${StackTrace.current.toString().split("\n").skip(1).take(4).join(" | ")}',
      );
    }
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  Future<void> stopRecording(WidgetTester tester, _Vault vault) async {
    await tester.tap(find.text('Start microphone recording'));
    await tester.pump();
    recorder.pcm.add(Uint8List.fromList([0, 1, 2, 3]));
    await tester.pump();
    await tester.tap(find.text('Stop and save recording'));
    await tester.pump();
    await until(tester, () => vault.state.audioDraft != null);
    await until(
      tester,
      () => find.text('Recording saved').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> remove(WidgetTester tester, _Vault vault) async {
    await until(tester, () => !recordingDetailsSheetOpen);
    await tester.pumpWidget(const SizedBox());
    await until(tester, () => !vault.state.recording.recording);
    vault.close();
    if (recorder.starts > 0) {
      await until(tester, () => recorder.disposed.isCompleted);
    }
  }

  Future<void> seedAlice(WidgetTester tester, _Vault vault) async {
    await tester.runAsync(
      () => vault.state.addManualText(
        title: 'Weekly sync',
        participantNames: 'Alice Müller',
        text: 'hello there',
      ),
    );
    expect(vault.state.error, isNull);
  }

  final linux = TargetPlatformVariant.only(TargetPlatform.linux);

  testWidgets('sheet opens after stop with suggestions and storage info', (
    tester,
  ) async {
    final vault = await mount(tester);
    await seedAlice(tester, vault);
    await stopRecording(tester, vault);
    expect(find.text('Recording saved'), findsOneWidget);
    expect(
      find.text("Stored encrypted in this device's Lifenizer vault"),
      findsWidgets,
    );
    expect(find.textContaining('…/share/lifenizer/app_data'), findsWidgets);
    expect(find.text('Weekly sync'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Alice Müller'), findsOneWidget);
    expect(find.text('Transcribe now'), findsOneWidget);
    expect(find.text('Save details'), findsOneWidget);
    await tapVisible(tester, find.text('Save details'));
    await until(
      tester,
      () =>
          vault.state.audioDraft!['detailsPrompted'] == true &&
          !recordingDetailsSheetOpen,
    );
    await tester.pumpAndSettle();
    await remove(tester, vault);
  }, variant: linux);

  testWidgets(
    'details persist in the draft, survive a rebuild and prompt once',
    (tester) async {
      final vault = await mount(tester);
      await seedAlice(tester, vault);
      await stopRecording(tester, vault);
      await tapVisible(tester, find.widgetWithText(ActionChip, 'Alice Müller'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title (optional)'),
        'Standup',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Add person'),
        'Bob,',
      );
      await tester.pump();
      await tapVisible(tester, find.text('Save details'));
      await until(
        tester,
        () =>
            vault.state.audioDraft!['detailsPrompted'] == true &&
            !recordingDetailsSheetOpen,
      );
      await tester.pumpAndSettle();
      expect(vault.state.audioDraft!['title'], 'Standup');
      expect(vault.state.audioDraft!['participantNames'], ['Bob']);
      expect(vault.state.audioDraft!['participantIds'], [
        vault.state.activeParticipants
            .firstWhere((person) => person.displayName == 'Alice Müller')
            .id,
      ]);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(vault));
      await tester.pumpAndSettle();
      expect(find.text('Recording saved'), findsNothing);
      expect(find.text('Title: Standup'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'Bob'), findsOneWidget);
      expect(find.text('Edit details'), findsOneWidget);
      expect(find.textContaining('…/share/lifenizer/app_data'), findsOneWidget);
      await tester.tap(find.text('Edit details'));
      await tester.pumpAndSettle();
      expect(find.text('Recording saved'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'Bob'), findsOneWidget);
      await tapVisible(tester, find.text('Save details'));
      await tester.pumpAndSettle();
      await remove(tester, vault);
    },
    variant: linux,
  );

  testWidgets('a restored draft that was never prompted opens the sheet', (
    tester,
  ) async {
    final vault = await mount(tester);
    await tester.runAsync(
      () => vault.state.saveAudioDraft([0, 0, 0, 0], DateTime.now()),
    );
    await until(
      tester,
      () => find.text('Recording saved').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Recording saved'), findsOneWidget);
    await tapVisible(tester, find.text('Save details'));
    await tester.pumpAndSettle();
    await remove(tester, vault);
  }, variant: linux);

  testWidgets('autocomplete offers existing people and a new person option', (
    tester,
  ) async {
    final vault = await mount(tester);
    await seedAlice(tester, vault);
    await stopRecording(tester, vault);
    await tester.enterText(find.widgetWithText(TextField, 'Add person'), 'mul');
    await tester.pump();
    expect(find.widgetWithText(ListTile, 'Alice Müller'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Add person'), 'Zed');
    await tester.pump();
    expect(find.text('Add "Zed" as new person'), findsOneWidget);
    await tapVisible(tester, find.text('Add "Zed" as new person'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'Zed'), findsOneWidget);
    await tapVisible(tester, find.text('Save details'));
    await tester.pumpAndSettle();
    await remove(tester, vault);
  }, variant: linux);

  testWidgets('transcribe sends the draft details to the import', (
    tester,
  ) async {
    http.Request? captured;
    final vault = await mount(
      tester,
      handler: (request) async {
        if (request.url.path == '/api/imports/audio') {
          captured = request;
          return http.Response(
            jsonEncode({
              'source': 'audio',
              'plaintextCompute': false,
              'message': 'Transcribed 1 segment.',
              'participants': <dynamic>[],
              'conversations': [
                {
                  'title': 'Standup',
                  // Not 'audio', so the test does not write the correction audio cache.
                  'source': 'transcript',
                  'participantNames': ['Bob'],
                  'segments': [
                    {'text': 'hello', 'offsetMs': 0},
                  ],
                },
              ],
            }),
            200,
          );
        }
        return null;
      },
    );
    await stopRecording(tester, vault);
    await tester.enterText(
      find.widgetWithText(TextField, 'Title (optional)'),
      'Standup',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Add person'),
      'Bob, Carol,',
    );
    await tapVisible(tester, find.text('Transcribe now'));
    await tester.pump();
    await until(tester, () => captured != null);
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['title'], 'Standup');
    expect(body['participantNames'], ['Bob', 'Carol']);
    await until(tester, () => vault.state.audioDraft == null);
    await tester.pumpAndSettle();
    await remove(tester, vault);
  }, variant: linux);

  testWidgets('discard asks for confirmation then removes the draft', (
    tester,
  ) async {
    final vault = await mount(tester);
    await stopRecording(tester, vault);
    await tapVisible(
      tester,
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Discard recording'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Discard recording?'), findsOneWidget);
    await tapVisible(tester, find.text('Discard'));
    await until(tester, () => vault.state.audioDraft == null);
    await tester.pumpAndSettle();
    await remove(tester, vault);
  }, variant: linux);

  testWidgets(
    'an open details sheet cannot overwrite a replacement recording',
    (tester) async {
      final vault = await mount(tester);
      await stopRecording(tester, vault);
      await tester.runAsync(() async {
        await vault.state.saveAudioDraft([1, 2, 3], DateTime.utc(2026, 10, 25));
        await vault.state.updateAudioDraftDetails(
          title: 'Replacement recording',
          detailsPrompted: true,
        );
      });
      await tapVisible(tester, find.text('Save details'));
      await until(tester, () => !recordingDetailsSheetOpen);
      expect(vault.state.audioDraft!['title'], 'Replacement recording');
      expect(vault.state.error, contains('recording changed'));
      await remove(tester, vault);
    },
    variant: linux,
  );
}
