import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('LifenizerApiClient timeout handling', () {
    test('importSource with an explicit timeout throws TimeoutException when '
        'the server is slower than the deadline', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response(
          jsonEncode({
            'source': 'audio',
            'plaintextCompute': true,
            'message': 'ok',
            'conversations': <dynamic>[],
            'participants': <dynamic>[],
          }),
          200,
        );
      });
      final api = LifenizerApiClient(
        baseUrl: 'http://example.test',
        client: client,
      );

      await expectLater(
        api.importSource(
          'audio',
          ImportSourceRequest(text: 'x'),
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('importSource without a timeout is exempt and still succeeds even '
        'when slower than a would-be short default', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return http.Response(
          jsonEncode({
            'source': 'manual-text',
            'plaintextCompute': true,
            'message': 'ok',
            'conversations': <dynamic>[],
            'participants': <dynamic>[],
          }),
          200,
        );
      });
      final api = LifenizerApiClient(
        baseUrl: 'http://example.test',
        client: client,
      );

      final result = await api.importSource(
        'manual-text',
        ImportSourceRequest(text: 'x'),
      );
      expect(result.source, 'manual-text');
    });

    test('importSource sends the request to /api/imports/<source>', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'source': 'audio',
            'plaintextCompute': true,
            'message': 'ok',
            'conversations': <dynamic>[],
            'participants': <dynamic>[],
          }),
          200,
        );
      });
      final api = LifenizerApiClient(
        baseUrl: 'http://example.test',
        client: client,
      );

      await api.importSource(
        'audio',
        ImportSourceRequest(
          originalFileName: 'memo.m4a',
          mimeType: 'audio/mp4',
          payloadBase64: 'aGVsbG8=',
        ),
        timeout: const Duration(minutes: 10),
      );

      expect(captured, isNotNull);
      expect(captured!.url.path, '/api/imports/audio');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['payloadBase64'], 'aGVsbG8=');
      expect(body['originalFileName'], 'memo.m4a');
      expect(body['mimeType'], 'audio/mp4');
    });
  });
}
