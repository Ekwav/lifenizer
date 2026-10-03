import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('LifenizerAppState.importAudioBytes', () {
    test(
      'sends bytes+filename to /api/imports/audio and the transcribed '
      'conversation ends up searchable by a word from the transcript',
      () async {
        http.Request? captured;
        final client = MockClient((request) async {
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
                    'title': 'Voice memo',
                    'source': 'audio',
                    'participantNames': <String>[],
                    'segments': [
                      {
                        'text': 'remember to water the plants tomorrow',
                        'offsetMs': 0,
                      },
                    ],
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/api/sync/push') {
            return http.Response(jsonEncode({'cursor': 1}), 200);
          }
          return http.Response('not found', 404);
        });

        final state = LifenizerAppState();
        await state.debugAuthenticateForTesting(
          LifenizerApiClient(
            baseUrl: 'http://127.0.0.1:5075',
            authToken: 'test-token',
            client: client,
          ),
        );

        final audioBytes = [1, 2, 3, 4, 5];
        await state.importAudioBytes(
          bytes: audioBytes,
          fileName: 'memo.m4a',
          title: 'Reminder memo',
          language: 'en',
        );

        expect(state.error, isNull);
        expect(captured, isNotNull);
        expect(captured!.url.path, '/api/imports/audio');

        final body = jsonDecode(captured!.body) as Map<String, dynamic>;
        expect(body['payloadBase64'], base64Encode(audioBytes));
        expect(body['originalFileName'], 'memo.m4a');
        expect(body['mimeType'], 'audio/mp4');
        expect(body['title'], 'Reminder memo');
        expect(body['metadata'], {'language': 'en'});

        final results = state.search('plants');
        expect(results, hasLength(1));
        expect(results.first.title, 'Voice memo');
        expect(results.first.source, 'audio');
      },
    );

    test(
      'recordedAt is sent as UTC ISO 8601 metadata and, once the backend '
      'anchors segment createdAt to it, the resulting conversation is found '
      'by a date-range search covering that day but not one covering only '
      'today',
      () async {
        http.Request? captured;
        // recordedAt is a fixed date well in the past relative to "today" in
        // any conceivable test run, so a "today" range can never accidentally
        // include it.
        final recordedAt = DateTime.utc(2025, 10, 14, 18, 5);
        final client = MockClient((request) async {
          if (request.url.path == '/api/imports/audio') {
            captured = request;
            // Mirrors what the backend now returns once metadata.recordedAt
            // is honored: each segment's createdAt is recordedAt + offsetMs.
            return http.Response(
              jsonEncode({
                'source': 'audio',
                'plaintextCompute': false,
                'message': 'Transcribed 2 segments.',
                'participants': <dynamic>[],
                'conversations': [
                  {
                    'title': 'Old voice memo',
                    'source': 'audio',
                    'participantNames': <String>[],
                    'segments': [
                      {
                        'text': 'first recorded segment',
                        'offsetMs': 0,
                        'createdAt': recordedAt.toIso8601String(),
                      },
                      {
                        'text': 'second recorded segment',
                        'offsetMs': 2500,
                        'createdAt': recordedAt
                            .add(const Duration(milliseconds: 2500))
                            .toIso8601String(),
                      },
                    ],
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/api/sync/push') {
            return http.Response(jsonEncode({'cursor': 1}), 200);
          }
          return http.Response('not found', 404);
        });

        final state = LifenizerAppState();
        await state.debugAuthenticateForTesting(
          LifenizerApiClient(
            baseUrl: 'http://127.0.0.1:5075',
            authToken: 'test-token',
            client: client,
          ),
        );

        await state.importAudioBytes(
          bytes: [1, 2, 3, 4, 5],
          fileName: 'old-memo.m4a',
          title: 'Old voice memo',
          recordedAt: recordedAt,
        );

        expect(state.error, isNull);
        expect(captured, isNotNull);
        final body = jsonDecode(captured!.body) as Map<String, dynamic>;
        expect(body['metadata'], {'recordedAt': '2025-10-14T18:05:00.000Z'});

        expect(state.conversations, hasLength(1));
        final conversation = state.conversations.single;
        expect(conversation.startedAt, recordedAt);

        // A range covering the recorded day finds the conversation. `from`/
        // `to` are calendar dates in the *local* timezone (see
        // SearchCriteria.normalizedFrom/normalizedTo), so the range is
        // derived from recordedAt's local calendar day rather than a
        // hardcoded UTC date, keeping this test timezone-independent.
        final recordedLocalDay = recordedAt.toLocal();
        final coveringRecordedDay = state.search(
          '',
          from: DateTime(
            recordedLocalDay.year,
            recordedLocalDay.month,
            recordedLocalDay.day,
          ),
          to: DateTime(
            recordedLocalDay.year,
            recordedLocalDay.month,
            recordedLocalDay.day,
          ),
        );
        expect(
          coveringRecordedDay.map((c) => c.id),
          contains(conversation.id),
        );

        // A range covering only "today" does not, because startedAt was
        // anchored to recordedAt rather than import time.
        final today = DateTime.now();
        final coveringToday = state.search(
          '',
          from: DateTime(today.year, today.month, today.day),
          to: DateTime(today.year, today.month, today.day),
        );
        expect(coveringToday.map((c) => c.id), isNot(contains(conversation.id)));
      },
    );

    test('is a no-op for empty bytes (no picked file)', () async {
      final client = MockClient((request) async {
        fail('should not make a network call for empty bytes');
      });
      final state = LifenizerAppState();
      await state.debugAuthenticateForTesting(
        LifenizerApiClient(baseUrl: 'http://127.0.0.1:5075', client: client),
      );

      await state.importAudioBytes(bytes: const [], fileName: 'empty.wav');

      expect(state.conversations, isEmpty);
    });

    test('surfaces a clear error on failure', () async {
      final client = MockClient((request) async {
        return http.Response('server exploded', 500);
      });
      final state = LifenizerAppState();
      await state.debugAuthenticateForTesting(
        LifenizerApiClient(baseUrl: 'http://127.0.0.1:5075', client: client),
      );

      await state.importAudioBytes(bytes: [1, 2, 3], fileName: 'memo.wav');

      expect(state.error, isNotNull);
      expect(state.busy, isFalse);
    });
  });
}
