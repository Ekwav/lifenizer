import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/recording_playback.dart';
import 'package:app/services/wav_audio.dart';
import 'package:app/widgets/transcription_correction_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Database extends Fake implements Database {}

class _Store extends LocalVaultStore {
  _Store() : super(_Database());
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String key) async => records[key];
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    records[key] = Map.from(value);
  }
}

class _Fixture {
  final bodies = <String, Map<String, dynamic>>{};
  int noticeRequests = 0;
  late final LifenizerAppState state;
  late final Directory directory;
  final previousPaths = PathProviderPlatform.instance;
  Future<void> dispose() async {
    state.dispose();
    PathProviderPlatform.instance = previousPaths;
    await directory.delete(recursive: true);
  }

  Future<void> open() async {
    directory = await Directory.systemTemp.createTemp('lifenizer-tab-dialog-');
    PathProviderPlatform.instance = _Paths(directory.path);
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.startsWith('/api/auth/')) {
        return http.Response(
          jsonEncode({
            'authToken': 'token',
            'userId': 'owner',
            'vaultId': 'vault',
            'vaultSalt': 'salt',
          }),
          200,
        );
      }
      if (path == '/api/imports/capabilities') return http.Response('[]', 200);
      if (path == '/api/training/tab/notice') {
        noticeRequests++;
        return http.Response(
          jsonEncode({
            'version': 'training-v1',
            'information': List.filled(
              40,
              'Example TAB provider training notice.',
            ).join(' '),
            'terms': 'Only contribute your own recordings.',
            'purposes': [
              {
                'value': 4,
                'title': 'Speech-recognition training',
                'description': 'Train Coflnet recognition.',
              },
            ],
            'privacyUrl': 'https://tab.example.test/privacy',
          }),
          200,
        );
      }
      if (path == '/api/training/tab/consents') {
        bodies[path] = Map<String, dynamic>.from(
          jsonDecode(request.body) as Map,
        );
        return http.Response(
          jsonEncode({
            'id': 'consent-1',
            'purposes': 4,
            'version': 'training-v1',
            'contributorAlias': 'anonymous-test',
          }),
          200,
        );
      }
      if (path == '/api/training/tab/corrections') {
        bodies[path] = Map<String, dynamic>.from(
          jsonDecode(request.body) as Map,
        );
        return http.Response(
          '{"message":"TAB could not complete this request. Your local recording and correction were preserved."}',
          503,
        );
      }
      if (path == '/api/imports/audio/upload') {
        return http.Response(
          jsonEncode({
            'source': 'audio',
            'message': 'Transcribed one sentence.',
            'participants': [],
            'conversations': [
              {
                'source': 'audio',
                'title': 'Memo',
                'participantNames': [],
                'segments': [
                  {
                    'text': 'The wrong sentence.',
                    'offsetMs': 1000,
                    'endMs': 2000,
                  },
                ],
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{"cursor":0,"envelopes":[]}', 200);
    });
    state = LifenizerAppState(
      localStore: _Store(),
      apiFactory: (base) => LifenizerApiClient(baseUrl: base, client: client),
    );
    await state.login(
      baseUrl: 'https://vault.example.test',
      email: 'owner@example.test',
      passphrase: 'a long private vault passphrase',
    );
    final pcm = Uint8List(3 * 32000)
      ..fillRange(0, 32000, 11)
      ..fillRange(32000, 64000, 22)
      ..fillRange(64000, 96000, 33);
    await state.importAudioBytes(bytes: encodeWav(pcm), fileName: 'memo.wav');
    expect(state.error, isNull);
  }
}

class _Engine implements RecordingAudioEngine {
  final played = Completer<void>.sync();
  RecordingAudio? loaded;
  bool disposed = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration get duration => const Duration(seconds: 1);
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> load(RecordingAudio audio) async => loaded = audio;
  @override
  Future<void> play() async => played.complete();
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<void> dispose() async => disposed = true;
}

Future<void> _open(
  WidgetTester tester,
  _Fixture fixture, {
  double height = 844,
  double textScale = 1,
  _Engine? engine,
}) async {
  await tester.binding.setSurfaceSize(Size(390, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(fixture.open);
  addTearDown(fixture.dispose);
  final conversation = fixture.state.conversations.single;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => TranscriptionCorrectionDialog(
                state: fixture.state,
                conversation: conversation,
                segment: conversation.segments.single,
                engineFactory: engine == null ? null : () => engine,
              ),
            ),
            child: const Text('Open correction'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open correction'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: 'editor layout');
}

Future<void> _next(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('corrected-sentence')),
    'The corrected sentence.',
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Next'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: 'privacy layout');
}

final _voice = find.byKey(const Key('correction-own-voice'));
final _terms = find.byKey(const Key('correction-training-consent'));
final _share = find.widgetWithText(FilledButton, 'Share correction');

void main() {
  testWidgets(
    'cancel protects unfinished correction until explicitly discarded',
    (tester) async {
      final f = _Fixture();
      await _open(tester, f);
      final field = find.byKey(const Key('corrected-sentence'));
      await tester.enterText(field, 'My unfinished correction.');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard correction?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'My unfinished correction.',
      );
      expect(find.byType(TranscriptionCorrectionDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(TranscriptionCorrectionDialog), findsNothing);
      expect(f.noticeRequests, 0);
      expect(f.bodies, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('keyboard leaves correction and Next usable on a phone', (
    tester,
  ) async {
    final f = _Fixture();
    await _open(tester, f);
    addTearDown(tester.view.resetViewInsets);
    final field = find.byKey(const Key('corrected-sentence'));
    await tester.enterText(field, 'The corrected sentence.');
    expect(tester.testTextInput.isVisible, isTrue);
    tester.view.viewInsets = FakeViewPadding(
      bottom: 300 * tester.view.devicePixelRatio,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    final next = find.widgetWithText(FilledButton, 'Next');
    for (final control in [field, next]) {
      expect(control.hitTestable(), findsOneWidget);
      expect(tester.getRect(control).top, greaterThanOrEqualTo(0));
      expect(tester.getRect(control).bottom, lessThanOrEqualTo(544));
    }
    expect(tester.widget<FilledButton>(next).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.text('Share for training'), findsOneWidget);
    for (final control in [_voice, _terms, _share]) {
      expect(control.hitTestable(), findsOneWidget);
      expect(tester.getRect(control).bottom, lessThanOrEqualTo(844));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'editing stays local and replay contains only the selected sentence',
    (tester) async {
      final f = _Fixture();
      final engine = _Engine();
      await _open(tester, f, engine: engine);
      expect(f.noticeRequests, 0);
      expect(find.text('Original sentence'), findsOneWidget);
      expect(
        find.widgetWithText(SelectableText, 'The wrong sentence.'),
        findsOneWidget,
      );
      expect(find.textContaining('Example TAB provider'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
            .onPressed,
        isNull,
      );
      await tester.runAsync(() async {
        tester
            .widget<IconButton>(find.byKey(const Key('recording-play-pause')))
            .onPressed!();
        await engine.played.future.timeout(const Duration(seconds: 10));
      });
      await tester.pump();
      expect(engine.loaded!.bytes.length, 32044);
      expect(engine.loaded!.bytes.skip(44), everyElement(22));
      expect(engine.loaded!.fileName, 'sentence.wav');
      expect(f.bodies, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(engine.disposed, isTrue);
    },
  );

  for (final (height, scale) in [(780.0, 1.0), (844.0, 1.0), (780.0, 1.3)]) {
    testWidgets(
      'privacy controls fit a 390 x $height phone at text scale $scale',
      (tester) async {
        final f = _Fixture();
        await _open(tester, f, height: height, textScale: scale);
        await _next(tester);
        expect(f.noticeRequests, 1);
        expect(find.text('Share for training'), findsOneWidget);
        expect(find.textContaining('Example TAB provider'), findsNothing);
        expect(find.text('Only contribute your own recordings.'), findsNothing);
        for (final control in [
          _voice,
          _terms,
          _share,
          find.text('Privacy notice'),
        ]) {
          final rect = tester.getRect(control);
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(height));
          expect(control.hitTestable(), findsOneWidget);
        }
        expect(tester.widget<CheckboxListTile>(_voice).value, isFalse);
        expect(tester.widget<CheckboxListTile>(_terms).value, isFalse);
        expect(tester.widget<FilledButton>(_share).onPressed, isNull);
        await tester.tap(find.text('Full notice & terms'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'full notice layout');
        expect(find.text('TAB training notice'), findsOneWidget);
        expect(find.textContaining('Example TAB provider'), findsOneWidget);
        expect(
          find.text('Only contribute your own recordings.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Example TAB provider'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'explicit consent and edits survive failure and returning to the editor',
    (tester) async {
      final f = _Fixture();
      await _open(tester, f);
      await _next(tester);
      await tester.tap(_voice);
      await tester.pump();
      expect(tester.widget<FilledButton>(_share).onPressed, isNull);
      await tester.tap(_terms);
      await tester.pump();
      expect(tester.widget<FilledButton>(_share).onPressed, isNotNull);
      await tester.runAsync(() async {
        tester.widget<FilledButton>(_share).onPressed!();
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return f.state.busy;
        }).timeout(const Duration(seconds: 10));
      });
      await tester.pumpAndSettle();
      expect(find.byType(TranscriptionCorrectionDialog), findsOneWidget);
      expect(
        find.textContaining('TAB could not complete this request'),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(_share).onPressed, isNotNull);
      expect(f.bodies['/api/training/tab/consents']!['acceptTerms'], isTrue);
      final sent = f.bodies['/api/training/tab/corrections']!;
      expect(sent['correctedText'], 'The corrected sentence.');
      final clip = base64Decode(sent['payloadBase64'] as String);
      expect(clip.length, 32044);
      expect(clip.skip(44), everyElement(22));
      expect(
        f.state.conversations.single.segments.single.text,
        'The wrong sentence.',
      );

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Original sentence'), findsOneWidget);
      expect(
        find.widgetWithText(SelectableText, 'The wrong sentence.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('corrected-sentence')))
            .controller!
            .text,
        'The corrected sentence.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Next'));
      await tester.pumpAndSettle();
      // A saved consent receipt never prechecks either per-contribution choice.
      expect(tester.widget<CheckboxListTile>(_voice).value, isFalse);
      expect(tester.widget<CheckboxListTile>(_terms).value, isFalse);
      expect(tester.widget<FilledButton>(_share).onPressed, isNull);
      await tester.tap(_terms);
      await tester.pump();
      expect(tester.widget<FilledButton>(_share).onPressed, isNull);
      await tester.tap(_voice);
      await tester.pump();
      expect(tester.widget<FilledButton>(_share).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
