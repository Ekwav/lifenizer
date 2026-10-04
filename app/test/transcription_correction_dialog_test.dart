import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/local_vault_store.dart';
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
        return http.Response(
          jsonEncode({
            'version': 'training-v1',
            'information': 'Example TAB provider training notice.',
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
      if (path == '/api/imports/audio') {
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
    await state.importAudioBytes(
      bytes: encodeWav(Uint8List(3 * 32000)),
      fileName: 'memo.wav',
    );
    expect(state.error, isNull);
  }
}

void main() {
  testWidgets(
    'training requires explicit consent and keeps correction after provider failure',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final f = _Fixture();
      await tester.runAsync(f.open);
      addTearDown(f.dispose);
      final conversation = f.state.conversations.single;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TranscriptionCorrectionDialog(
              state: f.state,
              conversation: conversation,
              segment: conversation.segments.single,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final submit = find.widgetWithText(FilledButton, 'Submit correction');
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      expect(
        find.text('Example TAB provider training notice.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'The corrected sentence.');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final voice = find.widgetWithText(
        CheckboxListTile,
        'This is my own voice and this sentence contains no confidential information.',
      );
      final terms = find.widgetWithText(
        CheckboxListTile,
        'I accept the current TAB notice and consent to Coflnet speech-recognition training for my contributions.',
      );
      expect(tester.widget<CheckboxListTile>(voice).value, isFalse);
      expect(tester.widget<CheckboxListTile>(terms).value, isFalse);
      await tester.ensureVisible(voice);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: voice, matching: find.byType(Checkbox)),
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.ensureVisible(terms);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: terms, matching: find.byType(Checkbox)),
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.runAsync(() async {
        tester.widget<FilledButton>(submit).onPressed!();
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return f.state.busy;
        }).timeout(const Duration(seconds: 10));
      });
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'The corrected sentence.',
      );
      expect(find.byType(TranscriptionCorrectionDialog), findsOneWidget);
      expect(
        find.textContaining('TAB could not complete this request'),
        findsOneWidget,
      );
      expect(f.bodies['/api/training/tab/consents']!['acceptTerms'], isTrue);
      final sent = f.bodies['/api/training/tab/corrections']!;
      expect(sent['correctedText'], 'The corrected sentence.');
      expect(base64Decode(sent['payloadBase64'] as String).length, 32000 + 44);
      expect(conversation.segments.single.text, 'The wrong sentence.');
    },
  );
}
