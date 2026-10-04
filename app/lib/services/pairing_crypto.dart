import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// The secret lives in the URI fragment; only keyed proofs reach the server.
class PairingLink {
  PairingLink(this.server, this.secret, this.until);
  final String server;
  final List<int> secret;
  final DateTime until;

  factory PairingLink.parse(String value) {
    final uri = Uri.parse(value.trim());
    final fragment = Uri.splitQueryString(uri.fragment);
    final server = Uri.parse(uri.queryParameters['server'] ?? '');
    final secret = base64Url.decode(
      base64Url.normalize(fragment['secret'] ?? ''),
    );
    if (uri.scheme != 'lifenizer' ||
        uri.host != 'connect' ||
        fragment['v'] != '1' ||
        secret.length != 32 ||
        server.scheme != 'https' ||
        !server.hasAuthority ||
        server.userInfo.isNotEmpty ||
        server.hasQuery ||
        server.hasFragment) {
      throw const FormatException('Invalid secure connection link.');
    }
    final until = DateTime.fromMillisecondsSinceEpoch(
      int.parse(fragment['until'] ?? '') * 1000,
      isUtc: true,
    );
    return PairingLink(
      server.toString().replaceFirst(RegExp(r'/+$'), ''),
      secret,
      until,
    );
  }
}

class PairingCrypto {
  static String randomToken() {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  static Future<String> refreshHash(String token) async => (await Sha256().hash(
    utf8.encode(token),
  )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static Future<String> bootstrapProof(List<int> secret) async =>
      base64UrlEncode(
        await _mac(secret, 'lifenizer:enroll:v1'),
      ).replaceAll('=', '');

  static Future<List<int>> _mac(List<int> secret, String value) async =>
      (await Hmac.sha256().calculateMac(
        utf8.encode(value),
        secretKey: SecretKey(secret),
      )).bytes;

  static String _canonical(Map<String, dynamic> request) =>
      'lifenizer:device:v1\n${request['publicKey']}\n${request['nonce']}\n${request['deviceName']}\n${request['refreshTokenHash']}';

  static Future<bool> verifyRequest(
    List<int> secret,
    Map<String, dynamic> request,
  ) async {
    try {
      if (base64Decode(request['publicKey'] as String).length != 32 ||
          base64Decode(request['nonce'] as String).length != 32 ||
          !RegExp(
            r'^[0-9a-f]{64}$',
          ).hasMatch(request['refreshTokenHash'] as String)) {
        return false;
      }
      final actual = base64Decode(request['proof'] as String);
      final expected = await _mac(secret, _canonical(request));
      if (actual.length != expected.length) return false;
      var difference = 0;
      for (var i = 0; i < actual.length; i++) {
        difference |= actual[i] ^ expected[i];
      }
      return difference == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<PairingRequest> request(
    PairingLink link,
    String deviceName,
  ) async {
    final keyPair = await X25519().newKeyPair();
    final refreshToken = randomToken();
    final request = <String, dynamic>{
      'bootstrapToken': await bootstrapProof(link.secret),
      'deviceName': deviceName,
      'publicKey': base64Encode((await keyPair.extractPublicKey()).bytes),
      'nonce': base64Encode(
        base64Url.decode(base64Url.normalize(randomToken())),
      ),
      'refreshTokenHash': await refreshHash(refreshToken),
    };
    request['proof'] = base64Encode(
      await _mac(link.secret, _canonical(request)),
    );
    return PairingRequest(keyPair, refreshToken, request);
  }

  static Future<String> verificationCode(Map<String, dynamic> request) async {
    final hash = await Sha256().hash([
      ...base64Decode(request['publicKey'] as String),
      ...base64Decode(request['nonce'] as String),
    ]);
    final hex = hash.bytes
        .take(4)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return '${hex.substring(0, 4)}-${hex.substring(4)}';
  }

  static Future<SecretKey> _transferKey(
    SimpleKeyPair keyPair,
    String remoteKey,
    String requestNonce,
    List<int> secret,
  ) async {
    final publicBytes = base64Decode(remoteKey);
    final nonceBytes = base64Decode(requestNonce);
    if (publicBytes.length != 32 || nonceBytes.length != 32) {
      throw const FormatException('Invalid device key.');
    }
    final shared = await X25519().sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
    );
    try {
      return await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: shared,
        nonce: await _mac(secret, 'lifenizer:transfer:v1\n$requestNonce'),
        info: utf8.encode('lifenizer:pairing:v1'),
      );
    } finally {
      shared.destroy();
    }
  }

  static Future<Map<String, dynamic>> encryptTransfer(
    Map<String, dynamic> request,
    String passphrase,
    int approvalUntil,
    List<int> secret,
  ) async {
    final sender = await X25519().newKeyPair();
    final key = await _transferKey(
      sender,
      request['publicKey'] as String,
      request['nonce'] as String,
      secret,
    );
    try {
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(
          jsonEncode({
            'vaultPassphrase': passphrase,
            'approvalUntil': approvalUntil,
          }),
        ),
        secretKey: key,
      );
      return {
        'cipherText': base64Encode(
          utf8.encode(
            jsonEncode({
              'c': base64Encode(box.cipherText),
              'm': base64Encode(box.mac.bytes),
            }),
          ),
        ),
        'nonce': base64Encode(box.nonce),
        'senderPublicKey': base64Encode(
          (await sender.extractPublicKey()).bytes,
        ),
      };
    } finally {
      key.destroy();
      sender.destroy();
    }
  }

  static Future<Map<String, dynamic>> decryptTransfer(
    PairingRequest request,
    Map<String, dynamic> transfer,
    List<int> secret,
  ) async {
    final key = await _transferKey(
      request.keyPair,
      transfer['senderPublicKey'] as String,
      request.body['nonce'] as String,
      secret,
    );
    try {
      final packed =
          jsonDecode(
                utf8.decode(base64Decode(transfer['cipherText'] as String)),
              )
              as Map;
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(packed['c'] as String),
          nonce: base64Decode(transfer['nonce'] as String),
          mac: Mac(base64Decode(packed['m'] as String)),
        ),
        secretKey: key,
      );
      final payload = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(clear)) as Map,
      );
      if ((payload['vaultPassphrase'] as String).isEmpty ||
          payload['approvalUntil'] is! int) {
        throw const FormatException('Missing vault key or approval deadline.');
      }
      return payload;
    } finally {
      key.destroy();
    }
  }
}

class PairingRequest {
  PairingRequest(this.keyPair, this.refreshToken, this.body);
  final SimpleKeyPair keyPair;
  final String refreshToken;
  final Map<String, dynamic> body;
  void dispose() => keyPair.destroy();
}
