import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/widgets/replacement_sentence_recorder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

class _State extends LifenizerAppState {
  bool unlocked = true;
  @override
  bool get isAuthenticated => unlocked;
  void changed() => notifyListeners();
}

class _Recorder extends RecordPlatform {
  final pcm = StreamController<Uint8List>.broadcast(sync: true);
  bool permission = true;
  Completer<void>? startGate;
  RecordConfig? config;
  int starts = 0;
  int stops = 0;
  bool disposed = false;
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
    this.config = config;
    starts++;
    await startGate?.future;
    return pcm.stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
    stops++;
    return null;
  }

  @override
  Future<void> dispose(String recorderId) async {
    disposed = true;
    await pcm.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late RecordPlatform previous;
  late _Recorder recorder;
  late _State state;
  ({Uint8List audio, String text})? result;
  setUp(() {
    previous = RecordPlatform.instance;
    recorder = _Recorder();
    RecordPlatform.instance = recorder;
    state = _State()
      ..session = AuthSession(
        authToken: 'test',
        userId: 'user',
        vaultId: 'vault',
        vaultSalt: 'salt',
      );
    result = null;
  });
  tearDown(() {
    state.dispose();
    RecordPlatform.instance = previous;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await tester.pumpAndSettle();
  }

  Future<void> mount(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await recordReplacementSentence(
                  context,
                  state: state,
                  text: 'A non-private sentence.',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await settle(tester);
  }

  Future<void> record(WidgetTester tester, Uint8List samples) async {
    await tester.tap(find.text('Start recording'));
    await settle(tester);
    recorder.pcm.add(samples);
    await tester.pump();
  }

  testWidgets(
    'explicit capture returns mono PCM WAV with edited prompt, without library draft',
    (tester) async {
      await mount(tester);
      await tester.enterText(
        find.byType(TextField),
        'The corrected word is here.',
      );
      await record(tester, Uint8List.fromList([1, 2, 3, 4]));
      expect(recorder.config!.encoder, AudioEncoder.pcm16bits);
      expect(recorder.config!.sampleRate, 16000);
      expect(recorder.config!.numChannels, 1);
      await tester.tap(find.text('Stop recording'));
      await settle(tester);
      await tester.tap(find.text('Use this recording'));
      await settle(tester);
      expect(result!.text, 'The corrected word is here.');
      expect(ascii.decode(result!.audio.sublist(0, 4)), 'RIFF');
      expect(result!.audio.sublist(44), [1, 2, 3, 4]);
      expect(state.audioDraft, isNull);
      expect(state.conversations, isEmpty);
      expect(state.recording.recording, isFalse);
      expect(recorder.disposed, isTrue);
    },
  );

  testWidgets(
    'PCM cap trims excess and incomplete samples, retake discards completed audio',
    (tester) async {
      await mount(tester);
      await record(tester, Uint8List(16000 * 2 * 120 + 3));
      await settle(tester);
      expect(find.text('Retake'), findsOneWidget);
      await tester.tap(find.text('Retake'));
      await tester.pump();
      final use = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Use this recording'),
      );
      expect(use.onPressed, isNull);
      await record(tester, Uint8List.fromList([5, 6, 7]));
      await tester.tap(find.text('Stop recording'));
      await settle(tester);
      await tester.tap(find.text('Use this recording'));
      await settle(tester);
      expect(result!.audio.sublist(44), [5, 6]);
    },
  );

  testWidgets('automatic two-minute byte cap returns bounded WAV', (
    tester,
  ) async {
    await mount(tester);
    await record(tester, Uint8List(16000 * 2 * 120 + 3));
    await settle(tester);
    await tester.tap(find.text('Use this recording'));
    await settle(tester);
    expect(result!.audio.length, 44 + 16000 * 2 * 120);
  });

  testWidgets('active normal recording prevents microphone conflict', (
    tester,
  ) async {
    state.recording.recording = true;
    await mount(tester);
    expect(
      find.textContaining('Finish your current recording'),
      findsOneWidget,
    );
    await tester.tap(find.text('Start recording'));
    await settle(tester);
    expect(recorder.starts, 0);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    state.recording.recording = false;
  });

  testWidgets('cancel during asynchronous start prevents late capture', (
    tester,
  ) async {
    await mount(tester);
    recorder.startGate = Completer<void>();
    await tester.tap(find.text('Start recording'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    recorder.startGate!.complete();
    await settle(tester);
    expect(result, isNull);
    expect(recorder.disposed, isTrue);
    expect(recorder.stops, greaterThan(0));
    expect(state.audioDraft, isNull);
  });

  for (final reason in ['lock', 'pause', 'identity']) {
    testWidgets('$reason clears and releases capture', (tester) async {
      await mount(tester);
      await record(tester, Uint8List.fromList([1, 2]));
      if (reason == 'lock') {
        state.unlocked = false;
        state.changed();
      } else if (reason == 'identity') {
        state.apiBaseUrl = 'https://other.example.test';
        state.changed();
      } else {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      }
      await settle(tester);
      expect(result, isNull);
      expect(recorder.disposed, isTrue);
      expect(state.audioDraft, isNull);
    });
  }

  testWidgets('permission failure preserves sentence and offers retry', (
    tester,
  ) async {
    await mount(tester);
    recorder.permission = false;
    await tester.enterText(find.byType(TextField), 'Keep my prompt.');
    await tester.tap(find.text('Start recording'));
    await settle(tester);
    expect(find.textContaining('Enable microphone permission'), findsOneWidget);
    expect(find.text('Keep my prompt.'), findsOneWidget);
    recorder.permission = true;
    await record(tester, Uint8List.fromList([1, 2]));
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(result, isNull);
  });
}
