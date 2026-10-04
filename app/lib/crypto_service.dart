import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'services/vault_worker_io.dart'
    if (dart.library.js_interop) 'services/vault_worker_web.dart';

class EncryptedPayload {
  EncryptedPayload({
    required this.cipherText,
    required this.nonce,
    required this.keyId,
  });

  final String cipherText;
  final String nonce;
  final String keyId;
}

class VaultCrypto {
  final AesGcm _algorithm = AesGcm.with256bits();
  SecretKey? _vaultKey;

  static const String keyId = 'pbkdf2-sha256-aesgcm-v1';

  bool get isUnlocked => _vaultKey != null;

  void lock() {
    _vaultKey?.destroy();
    _vaultKey = null;
  }

  Future<void> unlock({
    required String email,
    required String passphrase,
    required String vaultSalt,
  }) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 180000,
      bits: 256,
    );
    _vaultKey = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: utf8.encode('lifenizer:$email:$vaultSalt'),
    );
  }

  Future<EncryptedPayload> encryptJson(
    Map<String, dynamic> json, {
    bool background = false,
  }) async {
    final key = _requireKey();
    if (background) {
      final bytes = (await key.extractBytes()).toList();
      try {
        return await _encryptInWorker(json, bytes);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    }
    final nonce = _algorithm.newNonce();
    final clearText = utf8.encode(jsonEncode(json));
    final box = await _algorithm.encrypt(
      clearText,
      secretKey: key,
      nonce: nonce,
    );
    final packed = jsonEncode({
      'c': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    });
    return EncryptedPayload(
      cipherText: base64Encode(utf8.encode(packed)),
      nonce: base64Encode(box.nonce),
      keyId: keyId,
    );
  }

  Future<Map<String, dynamic>> decryptJson({
    required String cipherText,
    required String nonce,
    bool background = false,
  }) async {
    final key = _requireKey();
    if (background) {
      final bytes = (await key.extractBytes()).toList();
      try {
        return await _decryptInWorker(cipherText, nonce, bytes);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    }
    final packed = jsonDecode(utf8.decode(base64Decode(cipherText))) as Map;
    final box = SecretBox(
      base64Decode(packed['c'] as String),
      nonce: base64Decode(nonce),
      mac: Mac(base64Decode(packed['m'] as String)),
    );
    final clearText = await _algorithm.decrypt(box, secretKey: key);
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(clearText)) as Map);
  }

  SecretKey _requireKey() {
    final key = _vaultKey;
    if (key == null) {
      throw StateError('Vault is locked.');
    }
    return key;
  }
}

// Keep closures outside VaultCrypto so workers capture only snapshot data/key
// bytes, never the live app or an open local database.
Future<EncryptedPayload> _encryptInWorker(
  Map<String, dynamic> json,
  List<int> bytes,
) => runVaultWork(() async {
  final crypto = VaultCrypto().._vaultKey = SecretKey(bytes);
  try {
    return await crypto.encryptJson(json);
  } finally {
    crypto.lock();
    bytes.fillRange(0, bytes.length, 0);
  }
});

Future<Map<String, dynamic>> _decryptInWorker(
  String cipherText,
  String nonce,
  List<int> bytes,
) => runVaultWork(() async {
  final crypto = VaultCrypto().._vaultKey = SecretKey(bytes);
  try {
    return await crypto.decryptJson(cipherText: cipherText, nonce: nonce);
  } finally {
    crypto.lock();
    bytes.fillRange(0, bytes.length, 0);
  }
});
