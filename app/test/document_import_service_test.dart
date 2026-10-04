import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/document_credentials.dart';
import 'package:app/services/local_vault_store.dart';
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
  Future<void> open() async {
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
