import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/document_credentials.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/paperless_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast.dart';

class _Database extends Fake implements Database {}

class _VaultStore extends LocalVaultStore {
  _VaultStore() : super(_Database());
  final records = <String, Map<String, dynamic>>{};
  bool fail = false;
  @override
  Future<Map<String, dynamic>?> read(String key) async => records[key];
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    if (fail && key.startsWith('vault:')) throw StateError('Disk full');
    records[key] = Map.from(value);
  }
}

class _Credentials extends DocumentCredentialStore {
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String identity, String source) async =>
      records['$identity/$source'];
  @override
  Future<void> write(
    String identity,
    String source,
    Map<String, dynamic> value,
  ) async {
    records['$identity/$source'] = Map.from(value);
  }

  @override
  Future<void> remove(String identity, String source) async =>
      records.remove('$identity/$source');
  Map<String, dynamic> get account => records.entries
      .singleWhere((entry) => entry.key.endsWith('/paperless'))
      .value;
}

class _Fixture {
  final vault = _VaultStore();
  final credentials = _Credentials();
  final requests = <Map<String, String>>[];
  String baseUrl = 'https://paperless.example.test';
  bool more = true;
  bool futureModified = false;
  late final LifenizerAppState state;
  Future<void> open({PaperlessClient? paperlessClient}) async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/api/auth/')) {
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
      if (request.url.path == '/api/imports/capabilities') {
        return http.Response('[]', 200);
      }
      if (request.url.path == '/api/imports/paperless/settings') {
        return http.Response(
          jsonEncode({'configured': true, 'baseUrl': baseUrl}),
          200,
        );
      }
      if (request.url.path == '/api/imports/paperless') {
        final metadata = Map<String, String>.from(
          (jsonDecode(request.body) as Map)['metadata'] as Map,
        );
        requests.add(metadata);
        final page = int.parse(metadata['page']!);
        return http.Response(
          jsonEncode({
            'source': 'paperless',
            'message': 'Documents imported',
            'participants': [],
            'conversations': [
              {
                'title': 'Scan $page',
                'source': 'paperless',
                'sourceThreadId': 'paperless:doc:$page',
                'segments': [
                  {
                    'text': 'Private PDF text $page',
                    'sourceMessageId': 'paperless:doc:$page',
                  },
                ],
              },
            ],
            'diagnostics': {
              'nextPage': more && page == 1 ? '2' : '',
              'hasMore': more && page == 1 ? 'true' : 'false',
              'nextModifiedAfter': futureModified
                  ? DateTime.now()
                        .add(const Duration(days: 1))
                        .toUtc()
                        .toIso8601String()
                  : '2020-10-04T12:0$page:00Z',
            },
          }),
          200,
        );
      }
      return http.Response('{"cursor":0,"envelopes":[]}', 200);
    });
    state = LifenizerAppState(
      localStore: vault,
      documentStore: credentials,
      paperlessClient: paperlessClient,
      apiFactory: (base) => LifenizerApiClient(baseUrl: base, client: client),
    );
    await state.login(
      baseUrl: 'https://vault.example.test',
      email: 'owner@example.test',
      passphrase: 'a long private vault passphrase',
    );
    expect(state.error, isNull);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'documents without OCR stay searchable and later text updates in place',
    () async {
      final f = _Fixture();
      var content = '';
      final local = PaperlessClient(
        client: MockClient((request) async {
          final document = {
            'id': 34,
            'title': 'Receipt waiting for OCR',
            'content': content,
            'modified': content.isEmpty
                ? '2020-10-04T12:00:00Z'
                : '2020-10-04T12:10:00Z',
          };
          return http.Response(
            jsonEncode(
              request.url.path.endsWith('/34/')
                  ? document
                  : {
                      'results': [document],
                      'next': null,
                    },
            ),
            200,
          );
        }),
      );
      await f.open(paperlessClient: local);
      addTearDown(f.state.dispose);
      await f.state.documentImport.connect(
        baseUrl: 'http://127.0.0.1:8002',
        token: 'private-token',
      );
      expect(f.state.documentImport.error, isNull);
      expect(f.state.conversations.single.title, 'Receipt waiting for OCR');
      expect(f.state.conversations.single.segments.single.text, isEmpty);
      expect(
        (await f.state.searchAsync('Receipt waiting')).single.id,
        f.state.conversations.single.id,
      );
      expect(
        f.state.documentImport.status,
        contains('1 without extracted text'),
      );
      final id = f.state.conversations.single.id;
      content = 'OCR text now available';
      await f.state.documentImport.fetch();
      expect(f.state.documentImport.error, isNull);
      expect(f.state.conversations.single.id, id);
      expect(f.state.conversations.single.segments.single.text, content);
      expect(
        f.state.documentImport.status,
        isNot(contains('without extracted text')),
      );
    },
  );
  test(
    'direct Paperless imports stay local and retry a failed encrypted save',
    () async {
      final f = _Fixture();
      final pages = <String?>[];
      var empty = false;
      final local = PaperlessClient(
        client: MockClient((request) async {
          expect(request.url.origin, 'http://127.0.0.1:8002');
          expect(request.headers['authorization'], 'Token local-private-token');
          pages.add(request.url.queryParameters['page']);
          if (empty) return http.Response('{"next":null,"results":[]}', 200);
          final page = int.parse(pages.last!);
          return http.Response(
            jsonEncode({
              'next': page == 1
                  ? 'http://other.invalid/never-follow-this'
                  : null,
              'results': [
                {
                  'id': page,
                  'title': 'Local scan $page',
                  'content': 'Private local document $page',
                  'modified': '2020-10-04T12:0$page:00Z',
                },
              ],
            }),
            200,
          );
        }),
      );
      await f.open(paperlessClient: local);
      addTearDown(f.state.dispose);
      f.vault.fail = true;
      await f.state.documentImport.connect(
        baseUrl: 'http://127.0.0.1:8002',
        token: 'local-private-token',
      );
      expect(f.state.documentImport.directConnection, isTrue);
      expect(f.state.documentImport.baseUrl, 'http://127.0.0.1:8002/');
      expect(f.credentials.account['page'], '1');
      expect(f.state.documentImport.error, isNotNull);
      expect(f.requests, isEmpty);
      f.vault.fail = false;
      await f.state.documentImport.fetch();
      expect(pages, ['1', '1', '2']);
      expect(f.state.conversations.length, 2);
      final watermark = f.credentials.account['modifiedAfter'];
      empty = true;
      await f.state.documentImport.fetch();
      await f.state.documentImport.fetch();
      expect(
        f.credentials.account['modifiedAfter'],
        watermark,
        reason: 'Empty checks must not move the overlap window backward',
      );
      expect(
        f.state.conversations.first.sourceThreadId,
        'paperless:http://127.0.0.1:8002/:1',
      );
      expect(f.credentials.account['page'], '1');
      expect(
        f.credentials.account['modifiedAfter'],
        '2020-10-04T12:01:00.000Z',
      );
      expect(
        jsonEncode(f.vault.records),
        isNot(contains('local-private-token')),
      );
      expect(
        jsonEncode(f.vault.records),
        isNot(contains('Private local document')),
      );
      f.baseUrl = 'https://changed-server.example.test';
      await f.state.documentImport.fetch();
      expect(f.state.documentImport.error, isNull);
      expect(f.requests, isEmpty);
      expect(f.state.conversations.length, 2);
    },
  );

  test(
    'direct Paperless rejects unsafe addresses before saving a token',
    () async {
      final f = _Fixture();
      await f.open(
        paperlessClient: PaperlessClient(
          client: MockClient((_) async {
            fail('An invalid address must never receive a token');
          }),
        ),
      );
      addTearDown(f.state.dispose);
      await f.state.documentImport.connect(
        baseUrl: 'http://public.example.test',
        token: 'private-token',
      );
      expect(f.state.documentImport.connected, isFalse);
      expect(f.state.documentImport.error, isNotNull);
      expect(f.credentials.records, isEmpty);
      expect(f.requests, isEmpty);
    },
  );
  test(
    'Paperless pages persist encrypted before cursor and token stays in OS store',
    () async {
      final f = _Fixture();
      await f.open();
      addTearDown(f.state.dispose);
      await f.state.documentImport.connect(token: 'private-api-token');
      expect(f.requests.map((p) => p['page']), ['1', '2']);
      expect(f.requests.every((p) => !p.containsKey('modifiedAfter')), isTrue);
      expect(f.credentials.account['page'], '1');
      expect(
        f.credentials.account['modifiedAfter'],
        '2020-10-04T12:01:00.000Z',
      );
      expect(f.state.conversations.length, 2);
      expect(jsonEncode(f.vault.records), isNot(contains('Private PDF text')));
      expect(jsonEncode(f.vault.records), isNot(contains('private-api-token')));
      await f.state.documentImport.fetch();
      expect(f.requests[2]['modifiedAfter'], '2020-10-04T12:01:00.000Z');
    },
  );
  test(
    'Paperless save failure retains page and changed server never receives token',
    () async {
      final f = _Fixture();
      await f.open();
      addTearDown(f.state.dispose);
      f.vault.fail = true;
      await f.state.documentImport.connect(token: 'private-api-token');
      expect(f.credentials.account['page'], '1');
      expect(f.credentials.account['modifiedAfter'], isNull);
      expect(f.state.documentImport.error, isNotNull);
      f.vault.fail = false;
      await f.state.documentImport.fetch();
      expect(f.requests.map((p) => p['page']), ['1', '1', '2']);
      final count = f.requests.length;
      f.baseUrl = 'https://different-paperless.example.test';
      await f.state.documentImport.fetch();
      expect(f.requests.length, count);
      expect(f.state.documentImport.error, contains('changed'));
    },
  );
  test(
    'Paperless watermark replays changes made during a paginated import',
    () async {
      final f = _Fixture()..futureModified = true;
      await f.open();
      addTearDown(f.state.dispose);
      final before = DateTime.now().toUtc().subtract(
        const Duration(minutes: 1),
      );
      await f.state.documentImport.connect(token: 'private-api-token');
      final after = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
      final watermark = DateTime.parse(
        f.credentials.account['modifiedAfter'] as String,
      );
      expect(watermark.isBefore(before), isFalse);
      expect(watermark.isAfter(after), isFalse);
      expect(f.requests.every((p) => !p.containsKey('modifiedAfter')), isTrue);
    },
  );
}
