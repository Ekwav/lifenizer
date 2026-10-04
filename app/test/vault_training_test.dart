import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/wav_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sembast/sembast.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'TAB sends only selected audio, updates immutable transcript and stores encrypted receipts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lifenizer-tab-state-',
      );
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(directory.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previousPaths;
        await directory.delete(recursive: true);
      });
      final store = _Store();
      final requests = <String, Map<String, dynamic>>{};
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
        if (path == '/api/imports/capabilities') {
          return http.Response('[]', 200);
        }
        if (path == '/api/imports/audio') {
          return http.Response(
            jsonEncode({
              'source': 'audio',
              'message': 'Transcribed three sentences.',
              'participants': [],
              'conversations': [
                {
                  'source': 'audio',
                  'title': 'Synthetic speech memo',
                  'participantNames': [],
                  'segments': [
                    {
                      'text': 'Before the selected sentence.',
                      'sourceMessageId': 'before',
                      'offsetMs': 0,
                      'endMs': 1000,
                    },
                    {
                      'text': 'The erroneous sentence.',
                      'sourceMessageId': 'selected',
                      'offsetMs': 1000,
                      'endMs': 2000,
                    },
                    {
                      'text': 'After the selected sentence.',
                      'sourceMessageId': 'after',
                      'offsetMs': 2000,
                      'endMs': 3000,
                    },
                  ],
                },
              ],
            }),
            200,
          );
        }
        if (path == '/api/training/tab/consents') {
          requests[path] = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          return http.Response(
            jsonEncode({
              'id': 'consent-test',
              'purposes': 4,
              'version': 'training-v1',
              'contributorAlias': 'anonymous-test',
            }),
            200,
          );
        }
        if (path == '/api/training/tab/corrections') {
          requests[path] = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          return http.Response(
            '{"id":"contribution-test","audioId":"audio-test","status":"submitted_for_validation"}',
            200,
          );
        }
        if (path == '/api/training/tab/consents/consent-test/withdraw') {
          requests[path] = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          return http.Response('{"id":"consent-test","purposes":0}', 200);
        }
        return http.Response('{"cursor":0,"envelopes":[]}', 200);
      });
      final state = LifenizerAppState(
        localStore: store,
        apiFactory: (base) => LifenizerApiClient(baseUrl: base, client: client),
      );
      addTearDown(state.dispose);
      await state.login(
        baseUrl: 'https://vault.example.test',
        email: 'owner@example.test',
        passphrase: 'a long private vault passphrase',
      );
      final pcm = Uint8List(3 * 32000)
        ..fillRange(0, 32000, 0x11)
        ..fillRange(32000, 64000, 0x22)
        ..fillRange(64000, 96000, 0x33);
      final originalAudio = encodeWav(pcm);
      await state.importAudioBytes(
        bytes: originalAudio,
        fileName: 'synthetic.wav',
      );
      expect(state.error, isNull);
      final original = state.conversations.single;
      final selected = original.segments.singleWhere(
        (segment) => segment.sourceMessageId == 'selected',
      );
      final untimed = Conversation.fromJson({
        ...original.toJson(),
        'segments': original.segments
            .map(
              (segment) => {
                ...segment.toJson(),
                if (segment.id == selected.id) 'endMs': null,
                if (segment.sourceMessageId == 'after')
                  'offsetMs': selected.offsetMs,
              },
            )
            .toList(),
      });
      state.conversations[0] = untimed;
      expect(
        await state.submitTranscriptionCorrection(
          conversation: untimed,
          segment: untimed.segments[1],
          correctedText: 'The corrected sunflower sentence.',
          acceptTerms: true,
          consentVersion: 'training-v1',
        ),
        isFalse,
      );
      expect(state.error, contains('no usable audio end timestamp'));
      expect(requests, isEmpty);
      state.conversations[0] = original;
      expect(state.search('erroneous'), hasLength(1));
      expect(
        await state.submitTranscriptionCorrection(
          conversation: original,
          segment: selected,
          correctedText: 'The corrected sunflower sentence.',
          acceptTerms: true,
          consentVersion: 'training-v1',
        ),
        isTrue,
      );
      expect(state.error, isNull);
      final sent = requests['/api/training/tab/corrections']!;
      final clip = base64Decode(sent['payloadBase64'] as String);
      expect(clip.length, 32044);
      expect(clip.sublist(44).every((byte) => byte == 0x22), isTrue);
      expect(clip.sublist(44), isNot(contains(0x11)));
      expect(clip.sublist(44), isNot(contains(0x33)));
      expect(sent['originalText'], selected.text);
      expect(sent['correctedText'], 'The corrected sunflower sentence.');
      expect(sent['consentId'], 'consent-test');
      expect(requests['/api/training/tab/consents']!['acceptTerms'], isTrue);
      final updated = state.conversations.single;
      expect(identical(updated, original), isFalse);
      expect(selected.text, 'The erroneous sentence.');
      final corrected = updated.segments.singleWhere(
        (segment) => segment.id == selected.id,
      );
      expect(corrected.text, 'The corrected sunflower sentence.');
      expect(corrected.offsetMs, 1000);
      expect(corrected.endMs, 2000);
      expect(corrected.sourceMessageId, selected.sourceMessageId);
      expect(
        updated.segments
            .where((segment) => segment.id != selected.id)
            .map((segment) => segment.text),
        ['Before the selected sentence.', 'After the selected sentence.'],
      );
      expect(state.search('sunflower'), hasLength(1));
      expect(state.search('erroneous'), isEmpty);
      final receipt =
          jsonDecode(updated.metadata['tabSubmission:${selected.id}']!) as Map;
      expect(receipt['audioId'], 'audio-test');
      expect(receipt['originalText'], selected.text);
      final consent = (await state.tabTrainingConsent())!;
      final key = consent['contributionKey'] as String;
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(sent['contributionKey'], key);
      expect((consent['receipts'] as List).single['version'], 'training-v1');
      final encryptedConsent = store.records.entries
          .singleWhere((entry) => entry.key.endsWith(':tab-training'))
          .value;
      expect(encryptedConsent.keys, unorderedEquals(['cipherText', 'nonce']));
      expect(jsonEncode(encryptedConsent), isNot(contains(key)));
      expect(
        jsonEncode(store.records),
        isNot(contains('The corrected sunflower sentence.')),
      );
      final cached = await Directory('${directory.path}/audio').list().single;
      final cachedText = await (cached as File).readAsString();
      expect(
        (jsonDecode(cachedText) as Map).keys,
        unorderedEquals(['cipherText', 'nonce']),
      );
      expect(cachedText, isNot(contains(base64Encode(originalAudio))));
      expect(cachedText, isNot(contains('The erroneous sentence.')));
      expect(await state.withdrawTabTrainingConsent(), isTrue);
      expect(
        requests['/api/training/tab/consents/consent-test/withdraw']!['contributionKey'],
        key,
      );
      expect(
        ((await state.tabTrainingConsent())!['receipts'] as List)
            .single['purposes'],
        0,
      );
    },
  );
}
