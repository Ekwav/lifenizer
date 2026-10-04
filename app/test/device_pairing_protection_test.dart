import 'dart:async';
import 'dart:convert';

import 'package:app/api_client.dart';
import 'package:app/app_state.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:app/services/pairing_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

const _password = 'local device password';
const _server = 'https://example.test/lifenizer';
final _credentials = <String, dynamic>{
  'server': _server,
  'email': 'paired@example.test',
  'deviceId': 'device-one',
  'until': 1,
  'secret': base64UrlEncode(List.filled(32, 1)),
  'vaultPassphrase': 'private paired vault passphrase',
  'refreshToken': 'private pairing refresh token',
};

class _Storage extends FlutterSecureStorage {
  final values = <String, String>{};
  int reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

class _Fixture {
  final keyring = _Storage();
  static const channel = MethodChannel('com.lifenizer/device_protection');
  final nativePayloads = <String, String>{};
  int nativeAuthentications = 0;
  final requests = <http.Request>[];
  late final store = PairingCredentialStore(storage: keyring);
  late final LifenizerAppState state;

  Future<void> initialize(DeviceProtection mode) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'cancel') return null;
          nativeAuthentications++;
          if (call.method == 'encrypt') {
            final cipher = base64Encode(List.filled(32, nativeAuthentications));
            nativePayloads[cipher] = call.arguments as String;
            return {
              'cipherText': cipher,
              'nonce': base64Encode(List.filled(12, 1)),
            };
          }
          if (call.method == 'decrypt') {
            return nativePayloads[(call.arguments as Map)['cipherText']];
          }
          throw StateError('Unexpected native method: ${call.method}');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await store.write(_credentials);
    await store.setProtection(mode, _credentials, password: _password);
    store.forgetUnlock();
    final database = await databaseFactoryMemory.openDatabase(
      'protected-pairing-${identityHashCode(this)}',
    );
    state = LifenizerAppState(
      localStore: LocalVaultStore(database),
      pairingStore: store,
      apiFactory: (url) => LifenizerApiClient(
        baseUrl: url,
        client: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          final Object result;
          if (path.endsWith('/pairing/refresh')) {
            result = {
              'email': _credentials['email'],
              'deviceId': _credentials['deviceId'],
              'session': {
                'authToken': 'auth-token',
                'userId': 'user',
                'vaultId': 'vault',
                'vaultSalt': 'vault-salt',
              },
            };
          } else if (path.endsWith('/sync/pull')) {
            result = {'cursor': 0, 'envelopes': []};
          } else if (path.endsWith('/imports/capabilities') ||
              path.endsWith('/pairing/pending')) {
            result = [];
          } else {
            throw StateError('Unexpected request: $path');
          }
          return http.Response(jsonEncode(result), 200);
        }),
      ),
    );
    addTearDown(() async {
      state.dispose();
      store.forgetUnlock();
      await database.close();
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final mode in [DeviceProtection.password, DeviceProtection.biometric]) {
    test(
      '${mode.name} restore and implicit unlock never authenticate or access the network',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final fixture = _Fixture();
          await fixture.initialize(mode);
          final authentications = fixture.nativeAuthentications;
          if (mode == DeviceProtection.biometric) {
            expect(authentications, greaterThan(0));
          }
          await fixture.state.pairing.restore(autoUnlock: true);
          await fixture.state.pairing.unlockSaved();
          expect(fixture.state.pairing.higherSecurity, isTrue);
          expect(fixture.state.isAuthenticated, isFalse);
          expect(fixture.nativeAuthentications, authentications);
          expect(fixture.requests, isEmpty);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  test(
    'explicit password unlock uses encrypted credentials and lock forgets their key',
    () async {
      final fixture = _Fixture();
      await fixture.initialize(DeviceProtection.password);
      await fixture.state.pairing.restore(autoUnlock: true);
      final header = await fixture.store.read();
      await fixture.state.pairing.unlockSaved(
        password: 'wrong password',
        authenticate: true,
      );
      expect(fixture.state.isAuthenticated, isFalse);
      expect(fixture.state.pairing.error, isNotNull);
      expect(fixture.requests, isEmpty);
      expect(await fixture.store.read(), header);

      await fixture.state.pairing.unlockSaved(
        password: _password,
        authenticate: true,
      );
      expect(
        fixture.state.isAuthenticated,
        isTrue,
        reason: fixture.state.pairing.error ?? fixture.state.error,
      );
      expect(
        fixture.requests.any(
          (request) => request.url.path.endsWith('/pairing/refresh'),
        ),
        isTrue,
      );
      for (final request in fixture.requests) {
        expect(request.body, isNot(contains(_password)));
        expect(
          request.body,
          isNot(contains(_credentials['vaultPassphrase'] as String)),
        );
      }
      await fixture.store.write(_credentials);
      await fixture.state.lock();
      expect(fixture.state.isAuthenticated, isFalse);
      await expectLater(fixture.store.write(_credentials), throwsStateError);
      final requestsAfterLock = fixture.requests.length;
      await fixture.state.pairing.unlockSaved();
      expect(fixture.state.isAuthenticated, isFalse);
      expect(fixture.requests, hasLength(requestsAfterLock));
      expect(
        await fixture.store.readForUnlock(password: _password),
        _credentials,
      );
    },
  );

  test('reconnecting cannot replace a protected paired vault', () async {
    final fixture = _Fixture();
    await fixture.initialize(DeviceProtection.password);
    await fixture.state.pairing.restore(autoUnlock: false);
    final header = await fixture.store.read();
    final link =
        'lifenizer://connect?server=https%3A%2F%2Fexample.test%2Flifenizer'
        '#v=1&secret=${_credentials['secret']}&until=1';
    await fixture.state.pairing.connect(link);
    expect(fixture.state.isAuthenticated, isFalse);
    expect(fixture.state.pairing.error, contains('disable Device security'));
    expect(fixture.requests, isEmpty);
    expect(await fixture.store.read(), header);
    expect(
      await fixture.store.readForUnlock(password: _password),
      _credentials,
    );
  });

  test(
    'locking during device verification prevents a late approval from reopening the vault',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final fixture = _Fixture();
        await fixture.initialize(DeviceProtection.biometric);
        await fixture.state.pairing.restore(autoUnlock: false);
        final header = await fixture.store.read();
        final verificationStarted = Completer<void>();
        final verifiedCredentials = Completer<String>();
        var cancellations = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_Fixture.channel, (call) async {
              if (call.method == 'cancel') {
                cancellations++;
                return null;
              }
              expect(call.method, 'decrypt');
              verificationStarted.complete();
              return verifiedCredentials.future;
            });

        final unlocking = fixture.state.pairing.unlockSaved(authenticate: true);
        await verificationStarted.future;
        await fixture.state.lock();
        verifiedCredentials.complete(jsonEncode(_credentials));
        await unlocking;

        expect(cancellations, greaterThanOrEqualTo(1));
        expect(fixture.state.status, 'Vault locked');
        expect(fixture.state.isAuthenticated, isFalse);
        expect(fixture.state.pairing.busy, isFalse);
        expect(fixture.requests, isEmpty);
        expect(await fixture.store.read(), header);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
