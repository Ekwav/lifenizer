import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/imap_import_service.dart';
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

class _Credentials extends ImapCredentialStore {
  final records = <String, Map<String, dynamic>>{};
  Completer<Map<String, dynamic>?>? readGate;
  Completer<void>? writeGate;
  Completer<void>? writing;
  bool fail = false;
  @override
  Future<Map<String, dynamic>?> read(String identity) async {
    if (readGate != null) return readGate!.future;
    return records[identity] == null ? null : Map.from(records[identity]!);
  }

  @override
  Future<void> write(String identity, Map<String, dynamic> value) async {
    if (fail) throw StateError('Credential store unavailable');
    if (writing?.isCompleted == false) writing!.complete();
    await writeGate?.future;
    records[identity] = Map.from(value);
  }

  @override
  Future<void> remove(String identity) async => records.remove(identity);
}

class _Fixture {
  final vault = _VaultStore();
  final credentials = _Credentials();
  final requests = <Map<String, String>>[];
  String host = 'imap.example.test';
  bool more = false;
  int messages = 0;
  late final LifenizerAppState state;
  Future<void> open() async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/api/auth/')) {
        return http.Response(
          jsonEncode({
            'authToken': 'token',
            'userId': 'alice',
            'vaultId': 'vault',
            'vaultSalt': 'salt',
          }),
          200,
        );
      }
      if (request.url.path == '/api/imports/capabilities') {
        return http.Response('[]', 200);
      }
      if (request.url.path == '/api/imports/email/settings') {
        return http.Response(
          jsonEncode({
            'configured': true,
            'host': host,
            'port': 993,
            'useTls': true,
            'tls': 'SslOnConnect',
          }),
          200,
        );
      }
      if (request.url.path == '/api/imports/email') {
        final metadata = Map<String, String>.from(
          (jsonDecode(request.body) as Map)['metadata'] as Map,
        );
        requests.add(metadata);
        final uid = int.parse(metadata['afterUid']!) + 1;
        messages++;
        return http.Response(
          jsonEncode({
            'source': 'email',
            'plaintextCompute': true,
            'message': 'Email imported',
            'participants': [
              {
                'displayName': 'Sender',
                'identifiers': ['email:sender@example.test'],
              },
            ],
            'conversations': [
              {
                'title': 'Inbox thread',
                'source': 'email',
                'participantNames': ['Sender'],
                'participantIdentifiers': ['email:sender@example.test'],
                'sourceThreadId': 'email-thread',
                'segments': [
                  {
                    'text': 'Private email body $uid',
                    'participantIdentifier': 'email:sender@example.test',
                    'sourceMessageId': 'message-$uid',
                    'createdAt': '2026-10-03T10:00:00Z',
                  },
                ],
              },
            ],
            'diagnostics': {
              'nextUid': '$uid',
              'uidValidity': '123',
              'hasMore': more ? 'true' : 'false',
            },
          }),
          200,
        );
      }
      return http.Response('{"cursor":0,"envelopes":[]}', 200);
    });
    state = LifenizerAppState(
      localStore: vault,
      imapStore: credentials,
      apiFactory: (base) => LifenizerApiClient(baseUrl: base, client: client),
    );
    await state.login(
      baseUrl: 'https://vault.example.test',
      email: 'alice@example.test',
      passphrase: 'a long private vault passphrase',
    );
    expect(state.error, isNull);
  }

  Future<void> connect({String username = 'mail@example.test'}) =>
      state.emailImport.connect(
        username: username,
        password: '  app password  ',
        remember: true,
      );
  void dispose() => state.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reindex attachments replays earlier UIDs without duplicate messages',
    () async {
      final f = _Fixture();
      await f.open();
      addTearDown(f.dispose);
      await f.connect();
      await f.state.emailImport.fetch();
      expect(f.requests.last['afterUid'], '1');
      expect(f.state.conversations.single.segments, hasLength(2));
      await f.state.emailImport.reindexAttachments();
      expect(f.requests.last['afterUid'], '0');
      expect(f.state.conversations.single.segments, hasLength(2));
      expect(f.credentials.records.values.single['afterUid'], '1');
    },
  );

  test(
    'cursor advances after encrypted persistence and credentials never enter vault records',
    () async {
      final f = _Fixture();
      await f.open();
      addTearDown(f.dispose);
      await f.connect();
      expect(f.credentials.records.values.single['afterUid'], '1');
      expect(f.requests.single['password'], '  app password  ');
      expect(
        f.state.conversations.single.segments.single.text,
        'Private email body 1',
      );
      final local = jsonEncode(f.vault.records);
      expect(local, contains('cipherText'));
      expect(local, isNot(contains('app password')));
      expect(local, isNot(contains('Private email body')));
      await f.state.emailImport.fetch();
      expect(f.requests.last['afterUid'], '1');
      expect(f.credentials.records.values.single['afterUid'], '2');
    },
  );

  test(
    'disk failure retains old cursor and retries the unsaved page',
    () async {
      final f = _Fixture();
      await f.open();
      addTearDown(f.dispose);
      f.vault.fail = true;
      await f.connect();
      expect(f.state.emailImport.error, contains('Disk full'));
      expect(f.credentials.records.values.single['afterUid'], '0');
      f.vault.fail = false;
      await f.state.emailImport.fetch();
      expect(f.requests.map((request) => request['afterUid']), ['0', '0']);
      expect(f.credentials.records.values.single['afterUid'], '1');
    },
  );

  test(
    'each run is bounded to twenty pages and configured host changes never receive credentials',
    () async {
      final f = _Fixture();
      await f.open();
      addTearDown(f.dispose);
      f.more = true;
      await f.connect();
      expect(f.requests, hasLength(20));
      expect(f.credentials.records.values.single['afterUid'], '20');
      expect(f.state.emailImport.status, contains('more remain'));
      f.host = 'different.example.test';
      await f.state.emailImport.fetch();
      expect(f.requests, hasLength(20));
      expect(f.state.emailImport.error, contains('server changed'));
    },
  );

  test('delayed restore cannot replace a newly connected account', () async {
    final f = _Fixture();
    await f.open();
    addTearDown(f.dispose);
    f.credentials.readGate = Completer();
    f.state.emailImport.start();
    await f.connect(username: 'new@example.test');
    f.credentials.readGate!.complete({
      'username': 'old@example.test',
      'password': 'old',
      'mailbox': 'INBOX',
      'host': f.host,
      'port': 993,
      'remember': true,
      'afterUid': '500',
      'uidValidity': '123',
    });
    await Future<void>.delayed(Duration.zero);
    expect(f.state.emailImport.username, 'new@example.test');
    expect(f.credentials.records.values.single['username'], 'new@example.test');
  });

  test(
    'removing during a delayed cursor write never resurrects the saved account',
    () async {
      final f = _Fixture();
      await f.open();
      addTearDown(f.dispose);
      await f.connect();
      f.credentials.writeGate = Completer();
      f.credentials.writing = Completer();
      final fetch = f.state.emailImport.fetch();
      await f.credentials.writing!.future;
      final remove = f.state.emailImport.removeAccount();
      expect(f.state.emailImport.connected, isFalse);
      f.credentials.writeGate!.complete();
      await fetch;
      await remove;
      expect(f.state.emailImport.connected, isFalse);
      expect(f.credentials.records, isEmpty);
    },
  );

  test(
    'failed keyring replacement keeps the existing account in memory and saved',
    () async {
      final f = _Fixture();
      await f.open();
      addTearDown(f.dispose);
      await f.connect(username: 'old@example.test');
      f.credentials.fail = true;
      await f.connect(username: 'new@example.test');
      expect(f.state.emailImport.username, 'old@example.test');
      expect(
        f.credentials.records.values.single['username'],
        'old@example.test',
      );
      expect(
        f.state.emailImport.error,
        contains('Credential store unavailable'),
      );
    },
  );
}
