import 'dart:convert';
import 'dart:io';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/browser_extension_receiver_service.dart';
import 'package:app/services/browser_history_types.dart';
import 'package:app/services/document_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

class _Vault extends LifenizerAppState {
  bool unlocked = true;
  @override
  bool get isAuthenticated => unlocked;
}

class _Store extends DocumentCredentialStore {
  final saved = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String identity, String source) async =>
      saved['$identity/$source'];
  @override
  Future<void> write(
    String identity,
    String source,
    Map<String, dynamic> value,
  ) async => saved['$identity/$source'] = jsonDecode(jsonEncode(value));
}

const _id = 'dQw4w9WgXcQ';
const _ext = 'chrome-extension://abcdef';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  late _Vault state;
  late _Store store;
  late BrowserExtensionReceiverService service;
  late List<ViewingImportBatch> sent;
  late List<int> hooked;
  late HttpClient client;
  late String token;

  Future<void> create() async {
    state = _Vault()
      ..session = AuthSession(
        authToken: 't',
        userId: 'u',
        vaultId: 'v',
        vaultSalt: 's',
      );
    addTearDown(state.dispose);
    store = _Store();
    service = BrowserExtensionReceiverService(
      state,
      store: store,
      supportedOverride: true,
      defaultPort: 0,
      importer: (batch) async {
        sent.add(batch);
        return batch.entries;
      },
      onImported: (n) async => hooked.add(n),
    );
    addTearDown(service.dispose);
    service.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await service.setEnabled(true);
    token = service.token!;
  }

  setUp(() {
    sent = [];
    hooked = [];
    client = HttpClient();
  });
  tearDown(() => client.close(force: true));

  Future<(int, Map<String, dynamic>?, HttpHeaders)> call(
    String method,
    String path, {
    Object? body,
    String? bearer,
    bool auth = true,
    Map<String, String> headers = const {},
    String? contentType = 'application/json',
    String? host,
    String? rawBody,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${service.port}$path'),
    );
    if (host != null) request.headers.host = host.split(':').first;
    if (host != null && host.contains(':')) {
      request.headers.port = int.parse(host.split(':').last);
    }
    if (auth) {
      request.headers.set('authorization', 'Bearer ${bearer ?? token}');
    }
    headers.forEach(request.headers.set);
    if (rawBody != null || body != null) {
      if (contentType != null) {
        request.headers.set('content-type', contentType);
      }
      request.write(rawBody ?? jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (
      response.statusCode,
      text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>,
      response.headers,
    );
  }

  Map<String, dynamic> visit(
    String url, {
    String time = '2026-10-01T10:00:00Z',
    String? precision,
    String? channel,
  }) => {
    'url': url,
    'title': 'T - YouTube',
    'time': time,
    'channel': ?channel,
    'timePrecision': ?precision,
  };

  Map<String, dynamic> payload(List<Map<String, dynamic>> visits) => {
    'source': 'lifenizer-extension',
    'version': 1,
    'visits': visits,
  };

  const yt = 'https://www.youtube.com/watch?v=$_id';

  group('security', () {
    test('disabled by default and token is 32 random bytes', () async {
      state = _Vault()
        ..session = AuthSession(
          authToken: 't',
          userId: 'u',
          vaultId: 'v',
          vaultSalt: 's',
        );
      addTearDown(state.dispose);
      final s = BrowserExtensionReceiverService(
        state,
        store: _Store(),
        supportedOverride: true,
        defaultPort: 0,
      );
      addTearDown(s.dispose);
      s.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(s.enabled, isFalse);
      expect(s.listening, isFalse);
      expect(s.token, isNull);
      await s.setEnabled(true);
      expect(base64Url.decode(base64Url.normalize(s.token!)), hasLength(32));
      expect(s.listening, isTrue);
    });

    test('missing or wrong bearer token gets 401', () async {
      await create();
      expect((await call('GET', '/v1/ping', auth: false)).$1, 401);
      expect((await call('GET', '/v1/ping', bearer: 'nope')).$1, 401);
      expect((await call('GET', '/v1/ping', bearer: '${token}x')).$1, 401);
      expect((await call('GET', '/v1/ping')).$1, 200);
    });

    test('foreign Host header gets 403', () async {
      await create();
      final r = await call('GET', '/v1/ping', host: 'evil.com:${service.port}');
      expect(r.$1, 403);
      final ok = await call(
        'GET',
        '/v1/ping',
        host: 'localhost:${service.port}',
      );
      expect(ok.$1, 200);
    });

    test('foreign Origin gets 403, extension origins are echoed', () async {
      await create();
      for (final origin in ['https://evil.com', 'null', 'http://localhost']) {
        final r = await call(
          'GET',
          '/v1/ping',
          headers: {'origin': origin},
        );
        expect(r.$1, 403, reason: origin);
      }
      for (final origin in ['chrome-extension://abc', 'moz-extension://abc']) {
        final r = await call('GET', '/v1/ping', headers: {'origin': origin});
        expect(r.$1, 200);
        expect(r.$3.value('access-control-allow-origin'), origin);
      }
    });

    test('preflight for extension origins works without a token', () async {
      await create();
      final r = await call(
        'OPTIONS',
        '/v1/watch-history',
        auth: false,
        headers: {'origin': _ext},
      );
      expect(r.$1, 204);
      expect(r.$3.value('access-control-allow-origin'), _ext);
      expect(r.$3.value('access-control-allow-methods'), contains('POST'));
      expect(
        r.$3.value('access-control-allow-headers'),
        allOf(contains('Authorization'), contains('Content-Type')),
      );
      final bad = await call(
        'OPTIONS',
        '/v1/watch-history',
        auth: false,
        headers: {'origin': 'https://evil.com'},
      );
      expect(bad.$1, 403);
    });

    test('unknown paths 404, wrong method 405, non-JSON 415', () async {
      await create();
      expect((await call('GET', '/nope')).$1, 404);
      expect((await call('GET', '/v1/watch-history')).$1, 405);
      final r = await call(
        'POST',
        '/v1/watch-history',
        rawBody: 'hi',
        contentType: 'text/plain',
      );
      expect(r.$1, 415);
    });

    test('body over 8 MB is rejected with 413', () async {
      await create();
      final big = '{"visits":[],"pad":"${'a' * (9 * 1024 * 1024)}"}';
      int status;
      try {
        status = (await call('POST', '/v1/watch-history', rawBody: big)).$1;
      } on SocketException {
        // The server may close the connection while the client still writes.
        status = 413;
      } on HttpException {
        status = 413;
      }
      expect(status, 413);
      expect(sent, isEmpty);
      // Still serving afterwards.
      expect((await call('GET', '/v1/ping')).$1, 200);
    });

    test('disabling stops listening; regenerating invalidates the token', () async {
      await create();
      final old = token;
      final port = service.port;
      await service.regenerateToken();
      expect(service.token, isNot(old));
      expect((await call('GET', '/v1/ping', bearer: old)).$1, 401);
      expect((await call('GET', '/v1/ping', bearer: service.token)).$1, 200);
      expect(
        store.saved.values.single['token'],
        service.token,
        reason: 'persisted',
      );

      await service.setEnabled(false);
      expect(service.listening, isFalse);
      final socket = Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      );
      await expectLater(socket, throwsA(isA<SocketException>()));
    });

    test('a busy port shows a clear error and stays disabled', () async {
      final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(blocker.close);
      await create();
      await service.setEnabled(false);
      await service.setPort(blocker.port);
      await service.setEnabled(true);
      expect(service.listening, isFalse);
      expect(service.enabled, isFalse);
      expect(service.error, contains('already in use'));
    });
  });

  group('endpoints', () {
    test('ping reports the unlocked state', () async {
      await create();
      var r = await call('GET', '/v1/ping');
      expect(r.$2, {'app': 'lifenizer', 'unlocked': true});
      state.unlocked = false;
      r = await call('GET', '/v1/ping');
      expect(r.$2, {'app': 'lifenizer', 'unlocked': false});
    });

    test('locked vault gets 503', () async {
      await create();
      state.unlocked = false;
      final r = await call(
        'POST',
        '/v1/watch-history',
        body: payload([visit(yt)]),
      );
      expect(r.$1, 503);
      expect(r.$2, {'error': 'locked'});
      expect(sent, isEmpty);
    });

    test('malformed input gets 400', () async {
      await create();
      for (final raw in [
        '{not json',
        '[]',
        '{"visits":"x"}',
        '{"visits":[{"url":"$yt"}]}',
        '{"visits":[{"url":"$yt","time":"yesterday"}]}',
        '{"visits":[{"url":"$yt","time":"2026-10-01T10:00:00Z","timePrecision":"week"}]}',
        '{"version":2,"visits":[]}',
      ]) {
        final r = await call('POST', '/v1/watch-history', rawBody: raw);
        expect(r.$1, 400, reason: raw);
      }
      expect(sent, isEmpty);
    });

    test('video visits become batches, other URLs are ignored', () async {
      await create();
      final r = await call(
        'POST',
        '/v1/watch-history',
        body: payload([
          visit(yt, channel: 'Rick'),
          visit(
            'https://www.tiktok.com/@u/video/7234567890123456789',
            time: '2026-10-01T11:00:00Z',
          ),
          visit('https://example.com/'),
          visit('https://www.youtube.com/results?search_query=x'),
        ]),
      );
      expect(r.$1, 200);
      expect(r.$2, {'accepted': 2, 'imported': 2});
      expect(sent.map((b) => b.source), [
        'youtube-watch-history',
        'tiktok-watch-history',
      ]);
      final youtube = jsonDecode(sent[0].json) as List;
      expect(youtube.single['titleUrl'], yt);
      expect(youtube.single['time'], '2026-10-01T10:00:00Z');
      expect(youtube.single['subtitles'], [
        {'name': 'Rick'},
      ]);
      expect(sent[1].json, contains('7234567890123456789'));
      expect(service.visitsAccepted, 2);
      expect(service.lastSync, isNotNull);
      expect(hooked, [2]);
    });

    test('a request with only non-video URLs imports nothing', () async {
      await create();
      final r = await call(
        'POST',
        '/v1/watch-history',
        body: payload([visit('https://example.com/')]),
      );
      expect(r.$2, {'accepted': 0, 'imported': 0});
      expect(sent, isEmpty);
      expect(hooked, isEmpty);
    });
  });

  group('day precision', () {
    final noon = DateTime(2026, 10, 1, 12);

    Conversation existing(DateTime watchedAt) => Conversation(
      id: 'c1',
      title: 'T',
      source: 'youtube-watch-history',
      sourceThreadId: 'youtube:$_id',
      participantIds: const [],
      segments: [
        ConversationSegment(
          id: 's1',
          text: 'T',
          sourceMessageId:
              'youtube:$_id@${watchedAt.millisecondsSinceEpoch ~/ 1000}',
          createdAt: watchedAt.toUtc(),
        ),
      ],
    );

    Future<(int, Map<String, dynamic>?, HttpHeaders)> dayVisit() => call(
      'POST',
      '/v1/watch-history',
      body: payload([
        visit(yt, time: noon.toUtc().toIso8601String(), precision: 'day'),
      ]),
    );

    test('does not duplicate a watch already seen that local day', () async {
      await create();
      state.conversations.add(existing(DateTime(2026, 10, 1, 8, 13, 5)));
      final r = await dayVisit();
      expect(r.$2, {'accepted': 1, 'imported': 0});
      expect(sent, isEmpty);
    });

    test('a different day is imported and a resend is idempotent', () async {
      await create();
      state.conversations.add(existing(DateTime(2026, 9, 30, 8)));
      final first = await dayVisit();
      expect(first.$2, {'accepted': 1, 'imported': 1});
      final again = await dayVisit();
      expect(again.$2!['accepted'], 1);
      // Both sends carry the identical watch second, so the vault merge by
      // sourceMessageId keeps one watch.
      expect(sent, hasLength(2));
      expect(sent[0].json, sent[1].json);
      expect(
        (jsonDecode(sent[0].json) as List).single['time'],
        noon.toUtc().toIso8601String().replaceAll('.000', ''),
      );
    });

    test('an exact visit in the same request wins over the day visit', () async {
      await create();
      final exact = DateTime(2026, 10, 1, 9, 30, 1);
      final r = await call(
        'POST',
        '/v1/watch-history',
        body: payload([
          visit(yt, time: noon.toUtc().toIso8601String(), precision: 'day'),
          visit(yt, time: exact.toUtc().toIso8601String()),
        ]),
      );
      expect(r.$2!['accepted'], 2);
      final list = jsonDecode(sent.single.json) as List;
      expect(list, hasLength(1));
      expect(
        DateTime.parse(list.single['time'] as String).toLocal().hour,
        9,
      );
    });

    test('exact visits are never filtered', () async {
      await create();
      state.conversations.add(existing(DateTime(2026, 10, 1, 8)));
      final r = await call(
        'POST',
        '/v1/watch-history',
        body: payload([
          visit(yt, time: DateTime(2026, 10, 1, 9).toUtc().toIso8601String()),
        ]),
      );
      expect(r.$2, {'accepted': 1, 'imported': 1});
    });
  });
}
