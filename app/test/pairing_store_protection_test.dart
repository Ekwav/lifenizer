import 'dart:convert';

import 'package:app/services/pairing_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = 'lifenizer.paired-device.v1';
const _password = 'device password one';
const _newPassword = 'device password two';
final _credentials = <String, dynamic>{
  'email': 'paired@example.test',
  'server': 'https://example.test/lifenizer',
  'deviceId': 'device-one',
  'until': 123456,
  'secret': 'secret-private-pairing-capability',
  'vaultPassphrase': 'private-vault-passphrase',
  'refreshToken': 'private-server-refresh-token',
  'pendingEnrollment': {'secret': 'private-pending-secret'},
};

class _MemoryStorage extends FlutterSecureStorage {
  final values = <String, String>{};
  bool failWrites = false;
  bool corruptHeader = false;

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
    if (failWrites) throw StateError('Secure storage unavailable');
    if (value == null) {
      values.remove(key);
    } else {
      values[key] =
          corruptHeader && key == _key && value.contains('"protection"')
          ? '{}'
          : value;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _MemoryStorage keyring;
  late PairingCredentialStore store;
  const channel = MethodChannel('lifenizer-test/device-protection');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, String> nativePayloads;
  late int decryptions;
  late bool failDecrypt;

  setUp(() async {
    keyring = _MemoryStorage();
    nativePayloads = {};
    decryptions = 0;
    failDecrypt = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'cancel':
          return null;
        case 'encrypt':
          final cipherText = base64Encode(
            utf8.encode('encrypted-operation-${nativePayloads.length}'),
          );
          nativePayloads[cipherText] = call.arguments as String;
          return {
            'cipherText': cipherText,
            'nonce': base64Encode(List<int>.filled(12, 0)),
          };
        case 'decrypt':
          decryptions++;
          if (failDecrypt) throw PlatformException(code: 'cancelled');
          final payload = call.arguments as Map;
          return nativePayloads[payload['cipherText']];
        default:
          throw MissingPluginException();
      }
    });
    store = PairingCredentialStore(storage: keyring, biometricChannel: channel);
    await store.write(_credentials);
  });
  tearDown(() async {
    store.forgetUnlock();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'OS keyring mode remains the default and requires no additional input',
    () async {
      expect(
        PairingCredentialStore.protectionOf(await store.read()),
        DeviceProtection.keyring,
      );
      expect(await store.readForUnlock(), _credentials);
      store.forgetUnlock();
      expect(await store.readForUnlock(), _credentials);
    },
  );

  test(
    'password wraps every secret and explicit unlock is required even with a cached key',
    () async {
      await store.setProtection(
        DeviceProtection.password,
        _credentials,
        password: _password,
      );
      final header = (await store.read())!;
      expect(
        PairingCredentialStore.protectionOf(header),
        DeviceProtection.password,
      );
      expect(keyring.values, hasLength(1));
      for (final field in [
        'secret',
        'vaultPassphrase',
        'refreshToken',
        'pendingEnrollment',
      ]) {
        expect(header.containsKey(field), isFalse);
        expect(
          keyring.values.values.single,
          isNot(contains(_credentials[field].toString())),
        );
      }
      expect(header['email'], _credentials['email']);
      expect(header['salt'], isNotEmpty);
      await expectLater(store.readForUnlock(), throwsStateError);
      store.forgetUnlock();
      await expectLater(
        store.readForUnlock(password: 'wrong password'),
        throwsA(anything),
      );
      expect(await store.read(), header);
      expect(await store.readForUnlock(password: _password), _credentials);
    },
  );

  test(
    'credential updates preserve protection and are rejected after forgetting the key',
    () async {
      await store.setProtection(
        DeviceProtection.password,
        _credentials,
        password: _password,
      );
      final updated = {
        ..._credentials,
        'refreshToken': 'new-private-refresh-token',
        'until': 654321,
      };
      await store.write(updated);
      expect((await store.read())!['until'], 654321);
      expect(await store.readForUnlock(password: _password), updated);
      await expectLater(
        store.write({...updated, 'email': 'other@example.test'}),
        throwsStateError,
      );
      store.forgetUnlock();
      await expectLater(store.write(updated), throwsStateError);
      expect(
        PairingCredentialStore.protectionOf(await store.read()),
        DeviceProtection.password,
      );
      expect(await store.readForUnlock(password: _password), updated);
    },
  );

  test(
    'password replacement and disabling require current password and preserve the payload',
    () async {
      await store.setProtection(
        DeviceProtection.password,
        _credentials,
        password: _password,
      );
      final original = await store.read();
      await expectLater(
        store.setProtection(DeviceProtection.keyring, _credentials),
        throwsStateError,
      );
      expect(await store.read(), original);
      await store.setProtection(
        DeviceProtection.password,
        _credentials,
        password: _newPassword,
        currentPassword: _password,
      );
      expect((await store.read())!['salt'], isNot(original!['salt']));
      store.forgetUnlock();
      await expectLater(
        store.readForUnlock(password: _password),
        throwsA(anything),
      );
      expect(await store.readForUnlock(password: _newPassword), _credentials);
      await store.setProtection(
        DeviceProtection.keyring,
        _credentials,
        currentPassword: _newPassword,
      );
      expect(await store.read(), _credentials);
      expect(keyring.values, hasLength(1));
    },
  );

  test(
    'staging and header verification failures retain the original credentials',
    () async {
      keyring.failWrites = true;
      await expectLater(
        store.setProtection(
          DeviceProtection.password,
          _credentials,
          password: _password,
        ),
        throwsStateError,
      );
      keyring.failWrites = false;
      expect(await store.read(), _credentials);
      keyring.corruptHeader = true;
      await expectLater(
        store.setProtection(
          DeviceProtection.password,
          _credentials,
          password: _password,
        ),
        throwsStateError,
      );
      expect(await store.read(), _credentials);
      expect(keyring.values, hasLength(1));
      await expectLater(
        store.setProtection(
          DeviceProtection.password,
          _credentials,
          password: 'short',
        ),
        throwsArgumentError,
      );
      expect(await store.read(), _credentials);
    },
  );

  test(
    'Android authentication encrypts secrets and verifies every explicit unlock without a cached bypass',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await store.setProtection(DeviceProtection.biometric, _credentials);
      final header = (await store.read())!;
      expect(
        header.keys,
        unorderedEquals([
          'server',
          'email',
          'deviceId',
          'until',
          'protection',
          'cipherText',
          'nonce',
        ]),
      );
      expect(keyring.values, hasLength(1));
      for (final field in ['secret', 'vaultPassphrase', 'refreshToken']) {
        expect(
          keyring.values.values.single,
          isNot(contains(_credentials[field] as String)),
        );
      }
      final reads = decryptions;
      await expectLater(store.readForUnlock(), throwsStateError);
      expect(decryptions, reads);
      expect(await store.readForUnlock(authenticate: true), _credentials);
      expect(await store.readForUnlock(authenticate: true), _credentials);
      expect(decryptions, reads + 2);
      store.forgetUnlock();
      expect(await store.readForUnlock(authenticate: true), _credentials);
      expect(decryptions, reads + 3);
      failDecrypt = true;
      await expectLater(
        store.readForUnlock(authenticate: true),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        store.setProtection(DeviceProtection.keyring, _credentials),
        throwsA(isA<PlatformException>()),
      );
      expect(await store.read(), header);
      failDecrypt = false;
      final updated = {..._credentials, 'until': 654321};
      await store.write(updated);
      expect(await store.readForUnlock(authenticate: true), updated);
      expect(keyring.values, hasLength(1));
      await store.setProtection(DeviceProtection.keyring, updated);
      expect(await store.read(), updated);
    },
  );

  test(
    'failed biometric setup and unsupported platforms never replace the default payload',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      failDecrypt = true;
      await expectLater(
        store.setProtection(DeviceProtection.biometric, _credentials),
        throwsA(isA<PlatformException>()),
      );
      expect(await store.read(), _credentials);
      expect(keyring.values, hasLength(1));
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await expectLater(
        store.setProtection(DeviceProtection.biometric, _credentials),
        throwsUnsupportedError,
      );
      expect(await store.read(), _credentials);
    },
  );

  test(
    'protected metadata tampering does not unlock another account',
    () async {
      await store.setProtection(
        DeviceProtection.password,
        _credentials,
        password: _password,
      );
      final tampered = {
        ...(await store.read())!,
        'email': 'other@example.test',
      };
      keyring.values[_key] = jsonEncode(tampered);
      store.forgetUnlock();
      await expectLater(
        store.readForUnlock(password: _password),
        throwsStateError,
      );
    },
  );
}
