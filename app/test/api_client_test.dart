import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/api_client.dart';
import 'package:app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('invitation token is sent only for nonempty registration', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({
          'authToken': 'token',
          'userId': 'user',
          'vaultId': 'vault',
          'vaultSalt': 'salt',
        }),
        200,
      );
    });
    final api = LifenizerApiClient(
      baseUrl: 'https://example.test',
      client: client,
    );
    await api.accountLogin(
      email: 'alice@example.test',
      password: 'password',
      register: true,
      registrationToken: '  synthetic-invitation  ',
    );
    await api.accountLogin(
      email: 'alice@example.test',
      password: 'password',
      register: true,
      registrationToken: '  ',
    );
    await api.accountLogin(
      email: 'alice@example.test',
      password: 'password',
      registrationToken: 'synthetic-invitation',
    );
    expect(
      jsonDecode(requests[0].body)['registrationToken'],
      'synthetic-invitation',
    );
    expect(
      (jsonDecode(requests[1].body) as Map).containsKey('registrationToken'),
      isFalse,
    );
    expect(
      (jsonDecode(requests[2].body) as Map).containsKey('registrationToken'),
      isFalse,
    );
    client.close();
  });

  test(
    'every API request preserves an HTTPS reverse proxy path prefix',
    () async {
      for (final suffix in ['', '/']) {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          expect(request.url.scheme, 'https');
          expect(request.url.host, 'mail.coflnet.com');
          expect(request.url.path, startsWith('/lifenizer/api/'));
          final route = request.url.path.substring('/lifenizer'.length);
          Object body;
          if (route.startsWith('/api/auth/')) {
            body = {
              'authToken': 'token',
              'userId': 'user',
              'vaultId': 'vault',
              'vaultSalt': 'salt',
            };
          } else if (route == '/api/imports/capabilities' ||
              (route == '/api/images' && request.method == 'GET')) {
            body = [];
          } else if (route.startsWith('/api/imports/')) {
            body = {
              'source': 'manual-text',
              'plaintextCompute': true,
              'message': 'ok',
              'conversations': [],
              'participants': [],
            };
          } else if (route == '/api/sync/pull') {
            expect(request.url.queryParameters, {'since': '42'});
            body = {'cursor': 42, 'envelopes': []};
          } else if (route == '/api/sync/push') {
            body = {'cursor': 42};
          } else if (route == '/api/analysis/relations/extract') {
            body = {'relations': []};
          } else if (route == '/api/images') {
            body = {
              'id': 'image-id',
              'fileName': 'opaque.bin',
              'contentType': 'application/octet-stream',
              'sizeBytes': 3,
              'uploadedAt': '2026-10-03T12:00:00Z',
            };
          } else if (route == '/api/images/image-id' &&
              request.method == 'GET') {
            return http.Response.bytes([1, 2, 3], 200);
          } else if (route == '/api/images/image-id' &&
              request.method == 'DELETE') {
            return http.Response('', 204);
          } else if (route == '/api/premium/status') {
            body = {
              'plan': 'free',
              'usedBytes': 0,
              'limitBytes': 1000,
              'usedPercent': 0.0,
            };
          } else if (route == '/api/premium/checkout/premium') {
            body = {'checkoutUrl': 'https://checkout.example.test'};
          } else {
            fail('Unexpected API route: $route');
          }
          return http.Response(jsonEncode(body), 200);
        });
        final api = LifenizerApiClient(
          baseUrl: 'https://mail.coflnet.com/lifenizer$suffix',
          client: client,
        );
        await api.accountLogin(
          email: 'alice@example.test',
          password: 'password',
        );
        await api.accountLogin(
          email: 'alice@example.test',
          password: 'password',
          register: true,
        );
        await api.devLogin(email: 'alice@example.test', displayName: 'Alice');
        final authenticated = api.authenticated('token');
        await authenticated.importCapabilities();
        await authenticated.importSource(
          'manual-text',
          ImportSourceRequest(text: 'notes'),
        );
        await authenticated.push([]);
        await authenticated.pull(42);
        await authenticated.extractRelations(
          text: 'notes',
          conversationId: 'conversation',
        );
        await authenticated.uploadImage(
          Uint8List.fromList([1, 2, 3]),
          'opaque.bin',
          'application/octet-stream',
        );
        await authenticated.listImages(conversationId: 'conversation/id');
        expect(requests.last.url.queryParameters, {
          'conversationId': 'conversation/id',
        });
        expect(await authenticated.downloadImage('image-id'), [1, 2, 3]);
        await authenticated.deleteImage('image-id');
        await authenticated.getQuotaStatus();
        await authenticated.createCheckoutUrl('premium');
        expect(requests, hasLength(14));
        client.close();
      }
    },
  );

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
