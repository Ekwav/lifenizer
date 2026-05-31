import 'dart:convert';

import 'package:cryptography/cryptography.dart';

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

  Future<EncryptedPayload> encryptJson(Map<String, dynamic> json) async {
    final key = _requireKey();
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
  }) async {
    final key = _requireKey();
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
