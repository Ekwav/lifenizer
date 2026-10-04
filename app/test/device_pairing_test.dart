import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/main.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/pairing_crypto.dart';
import 'package:app/services/pairing_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

class _Keyring extends PairingCredentialStore {
  Map<String, dynamic>? value;
  bool failWrites = false;
  @override
  Future<Map<String, dynamic>?> read() async => value == null
      ? null
      : Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  @override
  Future<void> write(Map<String, dynamic> credentials) async {
    if (failWrites) throw StateError('Keyring locked');
    value = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(credentials)) as Map,
    );
  }
}

class _Server {
  final session = {
    'authToken': 'initial-token',
    'userId': 'user',
    'vaultId': 'vault',
    'vaultSalt': 'salt',
  };
  final requests = <http.Request>[];
  final pending = <Map<String, dynamic>>[];
  final envelopes = <Map<String, dynamic>>[];
  final transfers = <String, Map<String, dynamic>>{};
  final requestSeen = Completer<void>();
  String? firstHash;
  bool loseBootstrapResponse = false;
  bool offline = false;
  bool failPull = false;
  String? refreshEmail;
  _Keyring? firstStore;
  Map<String, dynamic> auth(String id) => {
    'session': session,
    'email': 'paired@lifenizer.invalid',
    'deviceId': id,
    'bootstrapExpiresAt': DateTime.now()
        .toUtc()
        .add(const Duration(hours: 2))
        .toIso8601String(),
  };

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (offline) throw http.ClientException('Offline');
    expect(request.url.path, startsWith('/lifenizer/api/'));
    final path = request.url.path.substring('/lifenizer'.length);
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map;
    Object result;
    if (path == '/api/pairing/request') {
      expect(body.containsKey('secret'), isFalse);
      if (firstHash == null || body['refreshTokenHash'] == firstHash) {
        firstHash ??= body['refreshTokenHash'] as String;
        expect(
          firstStore?.value?['pendingEnrollment']['vaultPassphrase'],
          isNotEmpty,
        );
        if (loseBootstrapResponse) {
          loseBootstrapResponse = false;
          throw http.ClientException('Lost response');
        }
        result = {'status': 'bootstrap', ...auth('device-1')};
      } else {
        final id = 'request-${pending.length + 1}';
        final record = <String, dynamic>{
          ...Map<String, dynamic>.from(body),
          'id': id,
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 5))
              .toIso8601String(),
        };
        pending.add(record);
        if (!requestSeen.isCompleted) requestSeen.complete();
        result = {
          'status': 'pending',
          'requestId': id,
          'requestToken': 'poll-token',
          'expiresAt': record['expiresAt'],
        };
      }
    } else if (path.endsWith('/poll')) {
      final id = path.split('/')[3];
      result = transfers[id] == null
          ? {'status': 'pending'}
          : {
              'status': 'approved',
              ...auth('device-2'),
              'transfer': transfers[id],
            };
    } else if (path == '/api/pairing/pending') {
      result = pending
          .where((record) => !transfers.containsKey(record['id']))
          .toList();
    } else if (path.endsWith('/approve')) {
      transfers[path.split('/')[3]] = Map<String, dynamic>.from(body);
      return http.Response('', 204);
    } else if (path.endsWith('/deny')) {
      pending.removeWhere((record) => record['id'] == path.split('/')[3]);
      return http.Response('', 204);
    } else if (path == '/api/pairing/refresh') {
      session['authToken'] = 'renewed-token';
      result = {
        ...auth(body['deviceId'] as String? ?? 'device-1'),
        if (refreshEmail != null) 'email': refreshEmail,
      };
    } else if (path == '/api/sync/pull') {
      if (failPull) throw http.ClientException('Pull unavailable');
      result = {
        'cursor': envelopes.length,
        'envelopes': envelopes
            .where(
              (e) =>
                  (e['serverSequence'] as int) >
                  int.parse(request.url.queryParameters['since']!),
            )
            .toList(),
      };
    } else if (path == '/api/sync/push') {
      for (final e in body['envelopes'] as List) {
        if (!envelopes.any((old) => old['id'] == e['id'])) {
          envelopes.add({
            ...Map<String, dynamic>.from(e),
            'serverSequence': envelopes.length + 1,
          });
        }
      }
      result = {'cursor': envelopes.length};
    } else if (path == '/api/imports/capabilities') {
      result = [];
    } else {
      throw StateError('Unexpected $path');
    }
    return http.Response(jsonEncode(result), 200);
  }
}

Future<LifenizerAppState> _state(_Server server, _Keyring keyring) async {
  final database = await databaseFactoryMemory.openDatabase(
    'pair-${identityHashCode(keyring)}',
  );
  final local = LocalVaultStore(database);
  final state = LifenizerAppState(
    localStore: local,
    pairingStore: keyring,
    apiFactory: (url) =>
        LifenizerApiClient(baseUrl: url, client: MockClient(server.handle)),
  );
  addTearDown(() async {
    state.dispose();
    await database.close();
  });
  return state;
}

String _link({bool expired = false}) =>
    'lifenizer://connect?server=https%3A%2F%2Fexample.test%2Flifenizer#v=1&secret=${base64UrlEncode(List<int>.generate(32, (i) => i + 1))}&until=${DateTime.now().toUtc().add(Duration(minutes: expired ? -1 : 30)).millisecondsSinceEpoch ~/ 1000}';

void main() {
  test(
    'bootstrap saves credentials before enrollment and retries a lost response with the same vault key',
    () async {
      final keyring = _Keyring();
      final server = _Server()
        ..firstStore = keyring
        ..loseBootstrapResponse = true;
      final state = await _state(server, keyring);
      final link = _link();
      await state.pairing.connect(link);
      expect(state.isAuthenticated, isFalse);
      final savedKey = keyring.value!['pendingEnrollment']['vaultPassphrase'];
      final savedHash = server.firstHash;
      await state.pairing.connect(link);
      expect(
        state.isAuthenticated,
        isTrue,
        reason: state.error ?? state.pairing.error,
      );
      expect(keyring.value!['vaultPassphrase'], savedKey);
      expect(
        await PairingCrypto.refreshHash(
          keyring.value!['refreshToken'] as String,
        ),
        savedHash,
      );
      expect(
        state.pairing.automaticApprovalUntil!.millisecondsSinceEpoch ~/ 1000,
        PairingLink.parse(link).until.millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        server.requests.any((r) => r.url.path.contains('/auth/')),
        isFalse,
      );
      final stored = keyring.value!;
      await state.lock();
      server.offline = true;
      await state.pairing.unlockSaved();
      expect(state.isAuthenticated, isTrue, reason: state.error);
      expect(keyring.value, stored);
    },
  );

  test(
    'locked keyring stops setup before any server account is created',
    () async {
      final keyring = _Keyring()..failWrites = true;
      final server = _Server()..firstStore = keyring;
      final state = await _state(server, keyring);
      await state.pairing.connect(_link());
      expect(state.isAuthenticated, isFalse);
      expect(server.requests, isEmpty);
    },
  );

  test(
    'two devices exchange a real encrypted vault key only after approval, with the original deadline bound',
    () async {
      final firstStore = _Keyring();
      final secondStore = _Keyring();
      final server = _Server()..firstStore = firstStore;
      final first = await _state(server, firstStore);
      final second = await _state(server, secondStore);
      final link = _link(expired: true);
      await first.pairing.connect(link);
      expect(first.isAuthenticated, isTrue);
      final connection = second.pairing.connect(link);
      await server.requestSeen.future;
      await first.pairing.tick();
      expect(first.pairing.automaticApprovalActive, isFalse);
      expect(first.pairing.pending, hasLength(1));
      expect(server.transfers, isEmpty);
      final pending = first.pairing.pending.single;
      await expectLater(
        first.pairing.approve({
          ...pending,
          'proof': base64Encode(List<int>.filled(32, 0)),
        }),
        throwsStateError,
      );
      expect(server.transfers, isEmpty);
      await first.pairing.approve(pending, automatic: true);
      expect(server.transfers, isEmpty);
      await first.pairing.approve(pending);
      await connection;
      expect(
        second.isAuthenticated,
        isTrue,
        reason: second.error ?? second.pairing.error,
      );
      expect(
        secondStore.value!['vaultPassphrase'],
        firstStore.value!['vaultPassphrase'],
      );
      expect(secondStore.value!['until'], firstStore.value!['until']);
      expect(first.pairing.pending, isEmpty);
      expect(
        server.transfers.values.single.values,
        isNot(contains(firstStore.value!['vaultPassphrase'])),
      );
      await second.pairing.refreshAccess();
      expect(second.session!.authToken, 'renewed-token');
    },
  );

  test(
    'valid requests automatically connect only inside the locally authorized hour',
    () async {
      final firstStore = _Keyring();
      final secondStore = _Keyring();
      final server = _Server()..firstStore = firstStore;
      final first = await _state(server, firstStore);
      final second = await _state(server, secondStore);
      final link = _link();
      await first.pairing.connect(link);
      final connection = second.pairing.connect(link);
      await server.requestSeen.future;
      await first.pairing.tick();
      await connection;
      expect(first.pairing.automaticApprovalActive, isTrue);
      expect(
        second.isAuthenticated,
        isTrue,
        reason: second.error ?? second.pairing.error,
      );
      expect(
        secondStore.value!['vaultPassphrase'],
        firstStore.value!['vaultPassphrase'],
      );
      await first.lock();
      expect(first.pairing.pending, isEmpty);
      expect(await first.pairing.refreshAccess(), isNull);
      server.failPull =
          true; // Refresh succeeds; the encrypted local vault must still unlock.
      await first.pairing.unlockSaved();
      expect(
        first.isAuthenticated,
        isTrue,
        reason: first.error ?? first.pairing.error,
      );
      expect(first.status, contains('Local vault unlocked'));
    },
  );

  test(
    'another server or connection secret cannot replace the only stored vault key',
    () async {
      final keyring = _Keyring();
      final server = _Server()..firstStore = keyring;
      final state = await _state(server, keyring);
      final link = _link();
      await state.pairing.connect(link);
      await state.lock();
      final saved = await keyring.read();
      server.requests.clear();
      final otherSecret = link.replaceFirst(
        base64UrlEncode(List<int>.generate(32, (i) => i + 1)),
        base64UrlEncode(List<int>.filled(32, 99)),
      );
      for (final other in [
        link.replaceFirst('example.test', 'another.test'),
        otherSecret,
      ]) {
        await state.pairing.connect(other);
        expect(keyring.value, saved);
        expect(server.requests, isEmpty);
        expect(state.pairing.error, contains('existing key was preserved'));
      }
    },
  );

  test(
    'a reset server bootstrap cannot overwrite an existing paired vault key',
    () async {
      final keyring = _Keyring();
      final server = _Server()..firstStore = keyring;
      final state = await _state(server, keyring);
      final link = _link();
      await state.pairing.connect(link);
      await state.lock();
      final saved = await keyring.read();
      server.firstHash = null; // Simulate a database reset at the same URL.
      await state.pairing.connect(link);
      expect(state.isAuthenticated, isFalse);
      expect(keyring.value, saved);
      expect(
        state.pairing.error,
        contains('existing device key was preserved'),
      );
    },
  );

  test(
    'a forged refresh identity never installs its session, including without a local snapshot',
    () async {
      final keyring = _Keyring();
      final server = _Server()..firstStore = keyring;
      final state = await _state(server, keyring);
      await state.pairing.connect(_link());
      await state.lock();
      final saved = await keyring.read();
      server.refreshEmail = 'another@lifenizer.invalid';
      await state.pairing.unlockSaved();
      expect(
        state.isAuthenticated,
        isTrue,
      ); // Existing encrypted local cache unlocks offline.
      expect(state.session!.authToken, 'initial-token');
      expect(state.pairing.error, contains('another paired account'));
      expect(keyring.value, saved);
      final missingCache = await _state(server, _Keyring()..value = saved);
      await missingCache.pairing.restore(autoUnlock: false);
      server.requests.clear();
      await missingCache.pairing.unlockSaved();
      expect(missingCache.isAuthenticated, isFalse);
      expect(missingCache.session, isNull);
      expect(
        server.requests.any(
          (request) => request.url.path.endsWith('/sync/pull'),
        ),
        isFalse,
      );
      expect(missingCache.pairing.error, contains('another paired account'));
      expect(keyring.value, saved);
    },
  );

  test(
    'a lost first enrollment response recovers after the setup hour without extending approval',
    () async {
      final keyring = _Keyring();
      final server = _Server()
        ..firstStore = keyring
        ..loseBootstrapResponse = true;
      final state = await _state(server, keyring);
      final link = _link();
      await state.pairing.connect(link);
      final enrollment = keyring.value!['pendingEnrollment'] as Map;
      final originalKey = enrollment['vaultPassphrase'];
      enrollment['until'] =
          DateTime.now()
              .toUtc()
              .subtract(const Duration(hours: 2))
              .millisecondsSinceEpoch ~/
          1000;
      final requestCount = server.requests
          .where((request) => request.url.path.endsWith('/pairing/request'))
          .length;
      await state.pairing.connect(link);
      expect(
        state.isAuthenticated,
        isTrue,
        reason: state.error ?? state.pairing.error,
      );
      expect(keyring.value!['vaultPassphrase'], originalKey);
      expect(keyring.value!['until'], enrollment['until']);
      expect(state.pairing.automaticApprovalActive, isFalse);
      expect(
        server.requests.where(
          (request) => request.url.path.endsWith('/pairing/request'),
        ),
        hasLength(requestCount),
      );
      final refresh = server.requests.firstWhere(
        (request) => request.url.path.endsWith('/pairing/refresh'),
      );
      expect(jsonDecode(refresh.body)['deviceId'], isNull);
    },
  );

  testWidgets(
    'native setup is a single link; manual credentials remain available',
    (tester) async {
      final state = LifenizerAppState(pairingStore: _Keyring());
      addTearDown(state.dispose);
      await tester.pumpWidget(LifenizerApp(state: state));
      expect(find.text('Connect this device'), findsOneWidget);
      expect(find.text('Account password'), findsNothing);
      final linkField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Connection link',
      );
      expect(tester.widget<TextField>(linkField).obscureText, isTrue);
      await tester.tap(find.text('Use email and passwords'));
      await tester.pumpAndSettle();
      expect(find.text('Account password'), findsOneWidget);
    },
  );

  test('expired API access retries once with renewed authorization', () async {
    var refreshes = 0;
    final headers = <String?>[];
    final client = LifenizerApiClient(
      baseUrl: 'https://example.test/lifenizer',
      authToken: 'expired',
      refreshAuth: () async {
        refreshes++;
        return 'fresh';
      },
      client: MockClient((request) async {
        headers.add(request.headers['authorization']);
        if (request.headers['authorization'] == 'Bearer expired') {
          return http.Response('', 401);
        }
        return http.Response(jsonEncode({'cursor': 0, 'envelopes': []}), 200);
      }),
    );
    await client.pull(0);
    expect(refreshes, 1);
    expect(headers, ['Bearer expired', 'Bearer fresh']);
  });
}
