import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('imported conversations use real historical timestamps', () {
    // Regression test for a bug where Conversation.startedAt/endedAt
    // defaulted to DateTime.now() for every import, because they were
    // never populated from the imported segments' real per-message
    // timestamps (which the backend does provide, e.g. actual WhatsApp/
    // email dates). That made date-range search useless for anything
    // except conversations imported seconds ago. The fix derives
    // startedAt/endedAt from the min/max of the segments' createdAt values
    // when the backend supplies them.
    test('startedAt/endedAt reflect the earliest/latest segment timestamp, '
        'not the time of import', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/imports/whatsapp') {
          return http.Response(
            jsonEncode({
              'source': 'whatsapp',
              'plaintextCompute': true,
              'message': 'Normalized 2 messages.',
              'participants': <dynamic>[],
              'conversations': [
                {
                  'title': 'Old export',
                  'source': 'whatsapp',
                  'participantNames': <String>[],
                  'segments': [
                    {
                      'text': 'first message',
                      'offsetMs': 0,
                      'createdAt': '2019-05-01T10:00:00.000Z',
                    },
                    {
                      'text': 'second message',
                      'offsetMs': 1000,
                      'createdAt': '2019-05-01T10:05:00.000Z',
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
        LifenizerApiClient(baseUrl: 'http://127.0.0.1:5075', client: client),
      );

      final before = DateTime.now().toUtc();
      await state.importSource(source: 'whatsapp', text: 'ignored');

      expect(state.error, isNull);
      expect(state.conversations, hasLength(1));
      final imported = state.conversations.single;

      expect(imported.startedAt, DateTime.parse('2019-05-01T10:00:00.000Z'));
      expect(imported.endedAt, DateTime.parse('2019-05-01T10:05:00.000Z'));
      // Sanity check the bug this guards against: without the fix these
      // would be ~"now", not a multi-year-old historical date.
      expect(imported.startedAt.isBefore(before), isTrue);
      expect(before.difference(imported.startedAt).inDays, greaterThan(365));
    });

    test(
      'falls back to "now" when the backend supplies no segment timestamps '
      '(e.g. audio without detected dates), matching prior behavior',
      () async {
        final client = MockClient((request) async {
          if (request.url.path == '/api/imports/manual-text') {
            return http.Response(
              jsonEncode({
                'source': 'manual-text',
                'plaintextCompute': true,
                'message': 'Normalized 1 message.',
                'participants': <dynamic>[],
                'conversations': [
                  {
                    'title': 'No dates',
                    'source': 'manual-text',
                    'participantNames': <String>[],
                    'segments': [
                      {'text': 'just text', 'offsetMs': 0},
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
          LifenizerApiClient(baseUrl: 'http://127.0.0.1:5075', client: client),
        );

        final before = DateTime.now().toUtc();
        await state.importSource(source: 'manual-text', text: 'ignored');
        final after = DateTime.now().toUtc();

        final imported = state.conversations.single;
        expect(
          imported.startedAt.isAfter(
            before.subtract(const Duration(seconds: 1)),
          ),
          isTrue,
        );
        expect(
          imported.startedAt.isBefore(after.add(const Duration(seconds: 1))),
          isTrue,
        );
      },
    );
  });
}
