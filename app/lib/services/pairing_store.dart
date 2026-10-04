import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto_service.dart';
import 'pairing_crypto.dart';

enum DeviceProtection { keyring, password, biometric }

/// Native credentials never enter vault snapshots, settings, or web storage.
class PairingCredentialStore {
  PairingCredentialStore({
    FlutterSecureStorage? storage,
    MethodChannel? biometricChannel,
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(resetOnError: false),
           ),
       _biometricChannel =
           biometricChannel ??
           const MethodChannel('com.lifenizer/device_protection');

  static const _key = 'lifenizer.paired-device.v1';
  static const _metadata = ['server', 'email', 'deviceId', 'until'];
  final FlutterSecureStorage _storage;
  final MethodChannel _biometricChannel;
  VaultCrypto? _passwordCrypto;
  String? _passwordSalt;
  bool _authenticating = false;

  static DeviceProtection protectionOf(Map<String, dynamic>? raw) {
    final value = raw?['protection'];
    if (value == null) return DeviceProtection.keyring;
    return DeviceProtection.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => throw const FormatException('Unknown device protection.'),
    );
  }

  void forgetUnlock() {
    _passwordCrypto?.lock();
    _passwordCrypto = null;
    _passwordSalt = null;
    if (_authenticating) {
      unawaited(_cancelAuthentication());
    }
  }

  Future<void> _cancelAuthentication() async {
    try {
      await _biometricChannel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // Native channel is absent in tests or an older app build.
    } on PlatformException {
      // Cancellation never grants access or changes stored credentials.
    }
  }

  Future<Map<String, dynamic>?> read() async {
    if (kIsWeb) {
      throw UnsupportedError('Device pairing requires the native app.');
    }
    final value = await _storage.read(key: _key);
    return value == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  Future<void> write(Map<String, dynamic> credentials) async {
    if (kIsWeb) {
      throw UnsupportedError('Device pairing requires the native app.');
    }
    final header = await read();
    if (protectionOf(header) != DeviceProtection.keyring) {
      _verifyMetadata(header!, credentials, includeDeadline: false);
    }
    switch (protectionOf(header)) {
      case DeviceProtection.keyring:
        await _storage.write(key: _key, value: jsonEncode(credentials));
      case DeviceProtection.password:
        if (_passwordCrypto == null || _passwordSalt != header!['salt']) {
          throw StateError(
            'Unlock device protection before updating credentials.',
          );
        }
        final wrapped = await _passwordHeader(
          credentials,
          _passwordCrypto!,
          _passwordSalt!,
        );
        await _storage.write(key: _key, value: jsonEncode(wrapped));
      case DeviceProtection.biometric:
        await setProtection(DeviceProtection.biometric, credentials);
    }
  }

  Future<Map<String, dynamic>?> readForUnlock({
    String? password,
    bool authenticate = false,
  }) async {
    final header = await read();
    switch (protectionOf(header)) {
      case DeviceProtection.keyring:
        return header;
      case DeviceProtection.password:
        if (password == null || password.isEmpty) {
          throw StateError('Enter the device protection password.');
        }
        final crypto = VaultCrypto();
        try {
          await _unlockPassword(crypto, password, header!['salt'] as String);
          final credentials = await _decryptPassword(crypto, header);
          _verifyMetadata(header, credentials);
          forgetUnlock();
          _passwordCrypto = crypto;
          _passwordSalt = header['salt'] as String;
          return credentials;
        } catch (_) {
          crypto.lock();
          rethrow;
        }
      case DeviceProtection.biometric:
        _requireAndroid();
        if (!authenticate) {
          throw StateError('Authenticate on this device before unlocking.');
        }
        final credentials = await _decryptBiometric(header!);
        _verifyMetadata(header, credentials);
        return credentials;
    }
  }

  Future<void> setProtection(
    DeviceProtection mode,
    Map<String, dynamic> credentials, {
    String? password,
    String? currentPassword,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Device protection requires the native app.');
    }
    final previous = await read();
    if (previous == null) {
      throw StateError('Connect this device before protecting it.');
    }
    final verified = await readForUnlock(
      password: currentPassword,
      authenticate: true,
    );
    _verifyMetadata(verified!, credentials, includeDeadline: false);
    if (mode == DeviceProtection.biometric) _requireAndroid();
    if (mode == DeviceProtection.password &&
        (password == null || password.length < 12)) {
      throw ArgumentError(
        'Use a device protection password of at least 12 characters.',
      );
    }
    VaultCrypto? crypto;
    String? salt;
    String? stagedKey;
    try {
      Map<String, dynamic> header;
      switch (mode) {
        case DeviceProtection.keyring:
          header = Map<String, dynamic>.from(credentials);
        case DeviceProtection.password:
          salt = PairingCrypto.randomToken();
          crypto = VaultCrypto();
          await _unlockPassword(crypto, password!, salt);
          header = await _passwordHeader(credentials, crypto, salt);
        case DeviceProtection.biometric:
          final encrypted = await _authenticate<Map<dynamic, dynamic>>(
            'encrypt',
            jsonEncode(credentials),
          );
          if (encrypted == null ||
              encrypted['cipherText'] is! String ||
              encrypted['nonce'] is! String) {
            throw StateError(
              'Device verification did not protect these credentials.',
            );
          }
          header = {
            ..._header(credentials, mode),
            'cipherText': encrypted['cipherText'],
            'nonce': encrypted['nonce'],
          };
      }
      if (mode != DeviceProtection.keyring) {
        stagedKey = '$_key.staged.${PairingCrypto.randomToken()}';
        await _storage.write(key: stagedKey, value: jsonEncode(header));
        final staged = await _storage.read(key: stagedKey);
        if (staged == null) {
          throw StateError('Could not verify protected credential storage.');
        }
        final stored = Map<String, dynamic>.from(jsonDecode(staged) as Map);
        final decoded = mode == DeviceProtection.password
            ? await _decryptPassword(crypto!, stored)
            : await _decryptBiometric(stored);
        if (jsonEncode(decoded) != jsonEncode(credentials)) {
          throw StateError('Could not verify protected credential storage.');
        }
      }
      // Stage and verify protected storage before removing the old payload.
      final value = jsonEncode(header);
      try {
        await _storage.write(key: _key, value: value);
        if (await _storage.read(key: _key) != value) {
          throw StateError('Could not verify device protection settings.');
        }
      } catch (_) {
        await _storage.write(key: _key, value: jsonEncode(previous));
        rethrow;
      }
      forgetUnlock();
      _passwordCrypto = crypto;
      _passwordSalt = salt;
      crypto = null;
    } finally {
      crypto?.lock();
      if (stagedKey != null) {
        try {
          await _storage.delete(key: stagedKey);
        } catch (_) {
          /* Staged entries contain only encrypted/protected data. */
        }
      }
    }
  }

  static Map<String, dynamic> _header(
    Map<String, dynamic> credentials,
    DeviceProtection mode,
  ) => {
    for (final field in _metadata)
      if (credentials.containsKey(field)) field: credentials[field],
    'protection': mode.name,
  };

  static void _verifyMetadata(
    Map<String, dynamic> header,
    Map<String, dynamic> credentials, {
    bool includeDeadline = true,
  }) {
    for (final field in _metadata) {
      if (!includeDeadline && field == 'until') continue;
      if (header[field] != credentials[field]) {
        throw StateError('Device protection does not match this vault.');
      }
    }
  }

  static void _requireAndroid() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('Device authentication requires Android.');
    }
  }

  Future<T?> _authenticate<T>(String method, Object arguments) async {
    _authenticating = true;
    try {
      return await _biometricChannel.invokeMethod<T>(method, arguments);
    } finally {
      _authenticating = false;
    }
  }

  Future<Map<String, dynamic>> _decryptBiometric(
    Map<String, dynamic> header,
  ) async {
    final value = await _authenticate<String>('decrypt', {
      'cipherText': header['cipherText'],
      'nonce': header['nonce'],
    });
    if (value == null) {
      throw StateError('Device verification did not unlock these credentials.');
    }
    return Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  static Future<void> _unlockPassword(
    VaultCrypto crypto,
    String password,
    String salt,
  ) => crypto.unlock(
    email: 'device-credentials',
    passphrase: password,
    vaultSalt: salt,
  );

  static Future<Map<String, dynamic>> _decryptPassword(
    VaultCrypto crypto,
    Map<String, dynamic> header,
  ) => crypto.decryptJson(
    cipherText: header['cipherText'] as String,
    nonce: header['nonce'] as String,
  );

  static Future<Map<String, dynamic>> _passwordHeader(
    Map<String, dynamic> credentials,
    VaultCrypto crypto,
    String salt,
  ) async {
    final encrypted = await crypto.encryptJson(credentials);
    return {
      ..._header(credentials, DeviceProtection.password),
      'salt': salt,
      'cipherText': encrypted.cipherText,
      'nonce': encrypted.nonce,
      'keyId': encrypted.keyId,
    };
  }
}
