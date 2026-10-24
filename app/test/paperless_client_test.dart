import 'dart:convert';

import 'package:app/services/paperless_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const baseUrl = 'http://127.0.0.1:8002/paperless';
  const token = 'private-token';
  Map<String, dynamic> document(int id) => {
    'id': id,
    'title': 'Überweisung 東京',
    'content': 'Extracted text €',
    'correspondent': 3,
    'created': '2025-01-02T03:04:05Z',
    'modified': '2026-02-03T04:05:06Z',
    'original_file_name': 'Beleg.pdf',
    'document_type': 4,
    'archive_serial_number': 12,
  };
  http.Response json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  Future<dynamic> fetch(
    PaperlessClient client, {
    Map<String, String> metadata = const {},
  }) => client.fetchPage(baseUrl: baseUrl, token: token, metadata: metadata);

  test('validates private HTTP and public HTTPS; preserves path prefix', () {
    for (final host in [
      '127.0.0.1',
      '10.1.2.3',
      '172.16.2.3',
      '192.168.1.2',
      'localhost',
      'paperless.local',
      '[::1]',
      '[fd00::1]',
      '[fe80::1]',
    ]) {
      expect(
        PaperlessClient.validateBaseUrl('http://$host:8002/sub///').path,
        '/sub/',
      );
    }
    expect(
      PaperlessClient.validateBaseUrl('https://example.com/sub').toString(),
      'https://example.com/sub/',
    );
    for (final url in [
      'ftp://localhost',
      'http://example.com',
      'http://172.32.0.1',
      'http://127.0.0.1.evil.com',
      'http://2130706433',
      'http://[2001:db8::1]',
      'https://user:secret@example.com',
      'https://example.com/?token=x',
      'https://example.com/#x',
      '/relative',
    ]) {
      expect(
        () => PaperlessClient.validateBaseUrl(url),
        throwsFormatException,
        reason: url,
      );
    }
  });

  test(
    'normalizes Unicode, stable identities, metadata, and correspondents',
    () async {
      final requests = <http.Request>[];
      final client = PaperlessClient(
        client: MockClient((request) async {
          requests.add(request);
          expect(request.headers['Authorization'], 'Token $token');
          expect(request.url.host, '127.0.0.1');
          expect(request.followRedirects, isFalse);
          if (request.url.path.endsWith('correspondents/3/')) {
            return json({'name': 'Käthe'});
          }
          expect(request.url.queryParameters, {
            'page_size': '50',
            'page': '2',
            'ordering': 'id',
            'modified__gte': '2025-01-01T00:00:00Z',
          });
          return json({
            'results': [document(7), document(8)],
            'next': 'https://evil.example/steal-token',
          });
        }),
      );
      final result = await fetch(
        client,
        metadata: {
          'limit': '500',
          'page': '2',
          'modifiedAfter': '2025-01-01T00:00:00Z',
        },
      );
      expect(requests.length, 2);
      expect(result.plaintextCompute, isFalse);
      expect(result.participants.single.displayName, 'Käthe');
      final conversation = result.conversations.first;
      expect(conversation.title, 'Überweisung 東京');
      expect(
        conversation.sourceThreadId,
        'paperless:http://127.0.0.1:8002/paperless/:7',
      );
      expect(
        conversation.sourceUrl,
        'http://127.0.0.1:8002/paperless/documents/7/details',
      );
      expect(conversation.segments.single.text, 'Extracted text €');
      expect(
        conversation.segments.single.sourceMessageId,
        conversation.sourceThreadId,
      );
      expect(
        conversation.segments.single.createdAt,
        DateTime.utc(2025, 1, 2, 3, 4, 5),
      );
      expect(conversation.metadata['archive_serial_number'], '12');
      expect(conversation.artifactNames, ['Beleg.pdf']);
      expect(result.diagnostics['nextPage'], '3');
      expect(
        result.diagnostics['nextModifiedAfter'],
        '2026-02-03T04:05:06.000Z',
      );
    },
  );

  test(
    'editing an imported document between pages preserves the next document',
    () async {
      final documents = [
        {
          ...document(1),
          'correspondent': null,
          'modified': '2026-01-01T00:00:00Z',
        },
        {
          ...document(2),
          'correspondent': null,
          'modified': '2026-02-01T00:00:00Z',
        },
      ];
      final client = PaperlessClient(
        client: MockClient((request) async {
          final page = int.parse(request.url.queryParameters['page']!);
          if (page == 2) documents[0]['modified'] = '2026-03-01T00:00:00Z';
          final ordered = [...documents];
          if (request.url.queryParameters['ordering']!.startsWith('modified')) {
            ordered.sort(
              (a, b) =>
                  (a['modified'] as String).compareTo(b['modified'] as String),
            );
          }
          return json({
            'results': [ordered[page - 1]],
            'next': page == 1 ? '?page=2' : null,
          });
        }),
      );
      final first = await fetch(client, metadata: {'limit': '1'});
      final second = await fetch(
        client,
        metadata: {'limit': '1', 'page': first.diagnostics['nextPage']!},
      );
      expect(
        [
          first.conversations.single.metadata['id'],
          second.conversations.single.metadata['id'],
        ],
        ['1', '2'],
      );
    },
  );

  test(
    'imports pending OCR metadata and later text with the same identity',
    () async {
      final paths = <String>[];
      var ready = false;
      final client = PaperlessClient(
        client: MockClient((request) async {
          paths.add(request.url.path);
          return json(
            request.url.path.endsWith('/7/')
                ? {
                    ...document(7),
                    'correspondent': null,
                    'content': ready ? 'OCR finished' : '   ',
                  }
                : {
                    'results': [
                      {'id': 7},
                    ],
                    'next': null,
                  },
          );
        }),
      );
      final pending = await fetch(client);
      final pendingDocument = pending.conversations.single;
      expect(pendingDocument.segments, isEmpty);
      expect(pendingDocument.title, 'Überweisung 東京');
      expect(pendingDocument.metadata['id'], '7');
      expect(
        pendingDocument.sourceUrl,
        'http://127.0.0.1:8002/paperless/documents/7/details',
      );
      expect(pending.diagnostics['documentsWithoutText'], '1');
      expect(paths, [
        '/paperless/api/documents/',
        '/paperless/api/documents/7/',
      ]);
      ready = true;
      final completed = await fetch(client);
      expect(
        completed.conversations.single.sourceThreadId,
        pendingDocument.sourceThreadId,
      );
      expect(
        completed.conversations.single.segments.single.text,
        'OCR finished',
      );
      expect(completed.diagnostics['documentsWithoutText'], '0');
    },
  );

  test('detail text and embedded correspondent are normalized', () async {
    final client = PaperlessClient(
      client: MockClient(
        (request) async => json(
          request.url.path.endsWith('/7/')
              ? {
                  ...document(7),
                  'correspondent': {'name': 'Local person'},
                }
              : {
                  'results': [
                    {'id': 7},
                  ],
                  'next': null,
                },
        ),
      ),
    );
    final result = await fetch(client);
    expect(result.participants.single.displayName, 'Local person');
    expect(result.diagnostics['hasMore'], 'false');
    expect(result.diagnostics['nextPage'], '');
  });

  test('empty page preserves previous watermark', () async {
    final client = PaperlessClient(
      client: MockClient((_) async => json({'results': [], 'next': null})),
    );
    final result = await fetch(
      client,
      metadata: {'modifiedAfter': '2026-04-01T00:00:00Z'},
    );
    expect(result.diagnostics['nextModifiedAfter'], '2026-04-01T00:00:00.000Z');
  });

  test('rejects malformed IDs before any detail request', () async {
    for (final id in [null, '../secret', 0, -1, 1.5]) {
      var requests = 0;
      final client = PaperlessClient(
        client: MockClient((_) async {
          requests++;
          return json({
            'results': [
              {'id': id},
            ],
            'next': null,
          });
        }),
      );
      await expectLater(fetch(client), throwsA(isA<PaperlessException>()));
      expect(requests, 1);
    }
  });

  test(
    'redirects and HTTP failures are actionable without leaking bodies',
    () async {
      for (final status in [301, 302, 307, 401, 403, 500]) {
        var requests = 0;
        final client = PaperlessClient(
          client: MockClient((request) async {
            requests++;
            expect(request.followRedirects, isFalse);
            return http.Response(
              'private-body $token',
              status,
              headers: {'location': 'https://evil.example/'},
            );
          }),
        );
        await expectLater(
          fetch(client),
          throwsA(
            isA<PaperlessException>().having(
              (e) => e.message,
              'sanitized message',
              allOf(
                isNot(contains(token)),
                isNot(contains('private-body')),
                contains(
                  status < 400
                      ? 'final server URL'
                      : status < 500
                      ? 'permissions'
                      : '500',
                ),
              ),
            ),
          ),
        );
        expect(requests, 1);
      }
    },
  );

  test('network and malformed JSON failures omit private data', () async {
    for (final invalidJson in [false, true]) {
      final client = PaperlessClient(
        client: MockClient((_) async {
          if (invalidJson) return http.Response('private-body $token', 200);
          throw http.ClientException('private-body $token');
        }),
      );
      await expectLater(
        fetch(client),
        throwsA(
          isA<PaperlessException>().having(
            (e) => e.message,
            'message',
            allOf(isNot(contains(token)), isNot(contains('private-body'))),
          ),
        ),
      );
    }
  });

  test('rejects oversized declared and streamed responses', () async {
    for (final declared in [false, true]) {
      final client = PaperlessClient(
        client: MockClient.streaming(
          (request, _) async => http.StreamedResponse(
            Stream.value(
              declared ? <int>[] : List<int>.filled(25 * 1024 * 1024 + 1, 32),
            ),
            200,
            contentLength: declared ? 25 * 1024 * 1024 + 1 : null,
          ),
        ),
      );
      await expectLater(
        fetch(client),
        throwsA(
          isA<PaperlessException>().having(
            (e) => e.message,
            'message',
            contains('25 MiB'),
          ),
        ),
      );
    }
  });
}
