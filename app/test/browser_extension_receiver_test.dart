import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:app/models.dart';
import 'package:app/services/browser_extension_receiver_service.dart';
import 'package:app/services/browser_history_types.dart';
import 'package:app/services/document_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

class _Vault extends LifenizerAppState {
  bool unlocked = true;
  @override
  bool get isAuthenticated => unlocked;
  void changed() => notifyListeners();
}

class _Store extends DocumentCredentialStore {
  final saved = <String, Map<String, dynamic>>{};
  Completer<void>? readGate;
  Completer<void>? writeGate;
  Completer<void>? writeStarted;
  @override
  Future<Map<String, dynamic>?> read(String identity, String source) async {
    await readGate?.future;
    return saved['$identity/$source'];
  }

  @override
  Future<void> write(
    String identity,
    String source,
    Map<String, dynamic> value,
  ) async {
    writeStarted?.complete();
    writeStarted = null;
    await writeGate?.future;
    saved['$identity/$source'] = jsonDecode(jsonEncode(value));
  }
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
  late List<NormalizedImportResult> messages;
  late HttpClient client;
  late String token;

  Future<void> create({
    bool realMessages = false,
    ViewingBatchImporter? importer,
    DateTime Function()? now,
  }) async {
    state = _Vault()
      ..session = AuthSession(
        authToken: 't',
        userId: 'u',
        vaultId: 'v',
        vaultSalt: 's',
      );
    addTearDown(state.dispose);
    if (realMessages) {
      await state.debugAuthenticateForTesting(
        LifenizerApiClient(
          baseUrl: 'http://127.0.0.1:5075',
          authToken: 't',
          client: MockClient((_) async => http.Response('{"cursor":1}', 200)),
        ),
      );
    }
    store = _Store();
    service = BrowserExtensionReceiverService(
      state,
      store: store,
      supportedOverride: true,
      defaultPort: 0,
      now: now,
      importer:
          importer ??
          (batch) async {
            sent.add(batch);
            return batch.entries;
          },
      messageImporter: realMessages
          ? null
          : (batch) async {
              messages.add(batch);
              return batch.conversations.length;
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
    messages = [];
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

  String pairingCode(String link) =>
      Uri.splitQueryString(Uri.parse(link).fragment)['code']!;

  Future<(int, Map<String, dynamic>?, HttpHeaders)> pair(String code) => call(
    'POST',
    '/v1/pair',
    auth: false,
    headers: {'origin': _ext},
    body: {'code': code},
  );

  group('extension pairing', () {
    test(
      'public discovery and landing page never reveal credentials',
      () async {
        await create();
        final link = await service.createPairingLink();
        final uri = Uri.parse(link);
        final code = pairingCode(link);
        expect(uri.scheme, 'http');
        expect(uri.host, '127.0.0.1');
        expect(uri.port, service.port);
        expect(uri.path, '/v1/pair');
        expect(uri.hasQuery, isFalse);
        expect(base64Url.decode(base64Url.normalize(code)), hasLength(32));
        expect(link, isNot(contains(token)));
        final discovery = await call('GET', '/v1/discovery', auth: false);
        expect(discovery.$2, {
          'app': 'lifenizer',
          'version': 1,
          'enabled': true,
          'unlocked': true,
        });
        expect(discovery.$3.value('cache-control'), 'no-store');
        final request = await client.getUrl(uri.replace(fragment: ''));
        final response = await request.close();
        final html = await utf8.decodeStream(response);
        expect(response.statusCode, 200);
        expect(response.headers.contentType?.mimeType, 'text/html');
        expect(response.headers.value('cache-control'), 'no-store');
        expect(html, allOf(isNot(contains(token)), isNot(contains(code))));
        expect(service.pairingLink, link);
      },
    );

    test(
      'a code exchanges once without bearer and returns uncached credentials',
      () async {
        await create();
        final code = pairingCode(await service.createPairingLink());
        final result = await pair(code);
        expect(result.$1, 200);
        expect(result.$2, {
          'app': 'lifenizer',
          'version': 1,
          'port': service.port,
          'token': token,
        });
        expect(result.$3.value('cache-control'), 'no-store');
        expect(result.$3.value('access-control-allow-origin'), _ext);
        expect(service.pairingLink, isNull);
        expect((await pair(code)).$1, 401);
        expect(
          (await call(
            'GET',
            '/v1/ping',
            bearer: result.$2!['token'] as String,
          )).$1,
          200,
        );
      },
    );

    test('rejected attempts preserve the valid pairing code', () async {
      await create();
      final link = await service.createPairingLink();
      final code = pairingCode(link);
      expect((await pair('wrong-code')).$1, 401);
      for (final origin in [
        null,
        'https://evil.test',
        'null',
        'http://localhost',
      ]) {
        final result = await call(
          'POST',
          '/v1/pair',
          auth: false,
          headers: {'origin': ?origin},
          body: {'code': code},
        );
        expect(result.$1, 403, reason: 'origin: $origin');
        expect(service.pairingLink, link);
      }
      final foreign = await call(
        'POST',
        '/v1/pair',
        auth: false,
        headers: {'origin': _ext},
        host: 'evil.test:${service.port}',
        body: {'code': code},
      );
      expect(foreign.$1, 403);
      expect((await pair(code)).$1, 200);
    });

    test(
      'cold pairing restores the custom port before checking the link',
      () async {
        await create();
        final customPort = service.port;
        await service.setEnabled(false);
        await service.setPort(customPort);
        final restored = BrowserExtensionReceiverService(
          state,
          store: store,
          supportedOverride: true,
          defaultPort: 0,
        );
        addTearDown(restored.dispose);
        final link = await restored.createPairingLink(expectedPort: customPort);
        expect(Uri.parse(link).port, customPort);
        expect(restored.enabled, isTrue);
        expect(restored.listening, isTrue);
      },
    );

    test('expiry and replacement make previous codes unusable', () async {
      var now = DateTime.utc(2026, 10, 25);
      await create(now: () => now);
      final first = pairingCode(await service.createPairingLink());
      now = now.add(const Duration(minutes: 2));
      expect(service.pairingLink, isNull);
      expect((await pair(first)).$1, 401);
      final second = pairingCode(await service.createPairingLink());
      final third = pairingCode(await service.createPairingLink());
      expect((await pair(second)).$1, 401);
      expect((await pair(third)).$1, 200);
    });

    test('concurrent exchanges release the credential at most once', () async {
      await create();
      final code = pairingCode(await service.createPairingLink());
      final results = await Future.wait([pair(code), pair(code)]);
      expect(results.map((result) => result.$1), unorderedEquals([200, 401]));
      expect(
        results.where((result) => result.$2?.containsKey('token') ?? false),
        hasLength(1),
      );
    });

    test(
      'a slow exchange cannot consume the next vault pairing code',
      () async {
        await create();
        final code = pairingCode(await service.createPairingLink());
        final body = jsonEncode({'code': code});
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${service.port}/v1/pair'),
        );
        request.headers
          ..contentType = ContentType.json
          ..set('origin', _ext);
        request.contentLength = utf8.encode(body).length;
        request.write(body.substring(0, body.length - 1));
        await request.flush();
        // Allow the receiver to capture the first vault before completing JSON.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final next = AuthSession(
          authToken: 'other',
          userId: 'other-user',
          vaultId: 'other-vault',
          vaultSalt: 'other-salt',
        );
        final identity = jsonEncode([
          state.apiBaseUrl,
          state.rememberedEmail,
          next.userId,
          next.vaultId,
        ]);
        store.saved['$identity/browser-extension'] = {
          'enabled': true,
          'token': 'next-vault-token',
          'port': service.port,
        };
        state.session = next;
        state.changed();
        await service.createPairingLink(code: code);
        request.write(body.substring(body.length - 1));
        final response = await request.close();
        final result = jsonDecode(await utf8.decodeStream(response));
        expect(response.statusCode, 503);
        expect(result, {'error': 'vault-changed'});
        expect(service.pairingLink, isNotNull);
        expect((await pair(code)).$1, 200);
      },
    );

    for (final change in ['lock', 'disable', 'token']) {
      test('$change invalidates pending pairing permanently', () async {
        await create();
        final code = pairingCode(await service.createPairingLink());
        switch (change) {
          case 'lock':
            state.unlocked = false;
            state.changed();
            state.unlocked = true;
            state.changed();
          case 'disable':
            await service.setEnabled(false);
            await service.setEnabled(true);
          case 'token':
            await service.regenerateToken();
        }
        expect(service.pairingLink, isNull);
        expect((await pair(code)).$1, 401);
      });
    }
  });

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
        final r = await call('GET', '/v1/ping', headers: {'origin': origin});
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

    test(
      'disabling stops listening; regenerating invalidates the token',
      () async {
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
      },
    );

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

    test('configured port must remain stable across restarts', () async {
      await create();
      final port = service.port;
      for (final invalid in [0, -1, 65536]) {
        expect(() => service.setPort(invalid), throwsFormatException);
      }
      expect(service.port, port);
      expect(service.listening, isTrue);
    });

    for (final failRestore in [false, true]) {
      test(
        'old vault token fails during another vault restore (failure: $failRestore)',
        () async {
          await create();
          final oldToken = token;
          final gate = Completer<void>();
          store.readGate = gate;
          state.session = AuthSession(
            authToken: 'other-token',
            userId: 'other-user',
            vaultId: 'other-vault',
            vaultSalt: 'other-salt',
          );
          state.changed();
          expect(service.token, isNull);
          expect(service.enabled, isFalse);
          expect((await call('GET', '/v1/ping', bearer: oldToken)).$1, 401);
          expect(
            (await call(
              'POST',
              '/v1/watch-history',
              bearer: oldToken,
              body: payload([visit(yt)]),
            )).$1,
            401,
          );
          expect(sent, isEmpty);
          if (failRestore) {
            gate.completeError(StateError('Credential store unavailable'));
            await Future<void>.delayed(Duration.zero);
            expect(service.error, contains('Could not restore'));
            expect(service.token, isNull);
            expect((await call('GET', '/v1/ping', bearer: oldToken)).$1, 401);
          } else {
            gate.complete();
            await service.setEnabled(true);
            expect(service.token, isNot(oldToken));
            expect((await call('GET', '/v1/ping', bearer: oldToken)).$1, 401);
            expect(
              (await call('GET', '/v1/ping', bearer: service.token)).$1,
              200,
            );
          }
        },
      );
    }
  });

  test(
    'queued settings from an old vault cannot replace new pairing',
    () async {
      await create();
      const nextToken = 'another-vaults-existing-extension-token';
      final nextSession = AuthSession(
        authToken: 'other',
        userId: 'other-user',
        vaultId: 'other-vault',
        vaultSalt: 'other-salt',
      );
      final nextIdentity = jsonEncode([
        state.apiBaseUrl,
        state.rememberedEmail,
        nextSession.userId,
        nextSession.vaultId,
      ]);
      store.saved['$nextIdentity/browser-extension'] = {
        'enabled': true,
        'token': nextToken,
        'port': service.port,
      };
      final started = Completer<void>();
      final gate = Completer<void>();
      store.writeStarted = started;
      store.writeGate = gate;
      final saving = service.setPort(service.port);
      await started.future;
      final rotating = service.regenerateToken();
      state.session = nextSession;
      state.changed();
      gate.complete();
      await saving;
      await rotating;
      await service.setEnabled(true);
      expect(service.token, nextToken);
      expect(
        store.saved['$nextIdentity/browser-extension']!['token'],
        nextToken,
      );
      expect((await call('GET', '/v1/ping', bearer: token)).$1, 401);
      expect((await call('GET', '/v1/ping', bearer: nextToken)).$1, 200);
    },
  );

  test(
    'history stops between batches and cannot update another vault',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var batches = 0;
      await create(
        importer: (_) async {
          batches++;
          started.complete();
          await release.future;
          return 1;
        },
      );
      final response = call(
        'POST',
        '/v1/watch-history',
        body: payload(
          List.generate(
            501,
            (index) => visit(
              yt,
              time: DateTime.utc(
                2026,
                10,
                1,
              ).add(Duration(seconds: index)).toIso8601String(),
            ),
          ),
        ),
      );
      await started.future;
      final next = AuthSession(
        authToken: 'other',
        userId: 'next',
        vaultId: 'next',
        vaultSalt: 'salt',
      );
      final identity = jsonEncode([
        state.apiBaseUrl,
        state.rememberedEmail,
        next.userId,
        next.vaultId,
      ]);
      store.saved['$identity/browser-extension'] = {
        'enabled': true,
        'port': service.port,
        'token': 'next-vault-token',
      };
      state.session = next;
      state.changed();
      await service.setEnabled(true);
      release.complete();
      final result = await response;
      expect(result.$1, 503);
      expect(result.$2, {'error': 'vault-changed'});
      expect(batches, 1);
      expect(hooked, isEmpty);
      expect(service.lastSync, isNull);
      expect(service.visitsAccepted, 0);
      expect(service.videosImported, 0);
      expect(store.saved['$identity/browser-extension']!['lastSync'], isNull);
    },
  );

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

  group('browser messages', () {
    Map<String, dynamic> message({
      String platform = 'discord',
      String id = '1',
      String text = 'Hello',
    }) => {
      'platform': platform,
      'threadId': '123',
      'threadTitle': 'Friends',
      'id': id,
      'text': text,
      'createdAt': '2026-10-01T10:00:00Z',
      'authorId': '456',
      'authorName': 'Alice',
    };
    Map<String, dynamic> batch(List<Object?> items) => {
      'source': 'lifenizer-extension',
      'version': 1,
      'messages': items,
    };

    test('uses bearer, origin, JSON and unlocked vault gates', () async {
      await create();
      expect((await call('GET', '/v1/messages')).$1, 405);
      expect(
        (await call('POST', '/v1/messages', auth: false, body: batch([]))).$1,
        401,
      );
      expect(
        (await call(
          'POST',
          '/v1/messages',
          body: batch([]),
          headers: {'origin': 'https://evil.com'},
        )).$1,
        403,
      );
      expect(
        (await call(
          'POST',
          '/v1/messages',
          rawBody: '{}',
          contentType: 'text/plain',
        )).$1,
        415,
      );
      state.unlocked = false;
      expect(
        (await call('POST', '/v1/messages', body: batch([message()]))).$1,
        503,
      );
      expect(messages, isEmpty);
    });

    test(
      'validates whole bounded batch before accepting any message',
      () async {
        await create();
        for (final invalid in [
          batch([
            message(),
            {...message(), 'platform': 'telegram'},
          ]),
          batch([
            message(),
            {...message(), 'createdAt': 'yesterday'},
          ]),
          batch([
            {...message(), 'text': ''},
          ]),
          batch([
            {...message(), 'authorId': 123},
          ]),
          batch([
            {...message(), 'text': 'a' * 65537},
          ]),
          batch([
            {...message(), 'sourceUrl': 'javascript:alert(1)'},
          ]),
          batch(List.generate(501, (_) => message())),
          {...batch([]), 'source': 'other'},
          {...batch([]), 'version': 2},
        ]) {
          expect((await call('POST', '/v1/messages', body: invalid)).$1, 400);
        }
        expect(messages, isEmpty);
      },
    );

    test(
      'normalizes both platforms with stable thread, author and message IDs',
      () async {
        await create();
        final result = await call(
          'POST',
          '/v1/messages',
          body: batch([message(), message(platform: 'whatsapp', id: '2')]),
        );
        expect(result.$2, {'ok': true, 'imported': 2});
        final normalized = messages.single;
        expect(normalized.plaintextCompute, false);
        expect(normalized.conversations.map((c) => c.sourceThreadId), [
          'discord:123',
          'whatsapp:123',
        ]);
        expect(
          normalized.conversations.first.segments.single.sourceMessageId,
          '1',
        );
        expect(
          normalized.conversations.first.segments.single.participantIdentifier,
          'discord:456',
        );
        expect(normalized.participants.map((p) => p.identifiers.single), [
          'discord:456',
          'whatsapp:456',
        ]);
      },
    );

    test(
      'real ingestion skips duplicates and merges new or edited messages without losing old messages',
      () async {
        await create(realMessages: true);
        Future<Map<String, dynamic>?> send(List<Object?> items) async =>
            (await call('POST', '/v1/messages', body: batch(items))).$2;
        expect(await send([message()]), {'ok': true, 'imported': 1});
        expect(state.error, isNull);
        final id = state.conversations.single.id;
        final segmentId = state.conversations.single.segments.single.id;
        expect(await send([message()]), {'ok': true, 'imported': 0});
        expect(await send([message(id: '2', text: 'New reply')]), {
          'ok': true,
          'imported': 1,
        });
        expect(await send([message(text: 'Edited hello')]), {
          'ok': true,
          'imported': 1,
        });
        expect(state.conversations, hasLength(1));
        final conversation = state.conversations.single;
        expect(conversation.id, id);
        expect(conversation.segments, hasLength(2));
        expect(conversation.segments.first.id, segmentId);
        expect(conversation.segments.map((s) => s.text), [
          'Edited hello',
          'New reply',
        ]);
        expect(conversation.participantIds, hasLength(1));
      },
    );
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

    test(
      'an exact visit in the same request wins over the day visit',
      () async {
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
        expect(DateTime.parse(list.single['time'] as String).toLocal().hour, 9);
      },
    );

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
