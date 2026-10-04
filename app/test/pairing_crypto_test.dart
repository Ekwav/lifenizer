import 'dart:convert';

import 'package:app/services/pairing_crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final secret = List<int>.generate(32, (i) => i + 1);
  final link = PairingLink(
    'https://example.test/lifenizer',
    secret,
    DateTime.utc(2030),
  );

  test('connection fragment is private and insecure or malformed links fail', () {
    final uri =
        'lifenizer://connect?server=https%3A%2F%2Fexample.test%2Flifenizer#v=1&secret=${base64UrlEncode(secret)}&until=1893456000';
    final parsed = PairingLink.parse(uri);
    expect(parsed.server, link.server);
    expect(parsed.secret, secret);
    expect(parsed.until, link.until);
    expect(Uri.parse(uri).queryParameters.containsKey('secret'), isFalse);
    expect(
      () => PairingLink.parse(uri.replaceFirst('https%', 'http%')),
      throwsFormatException,
    );
    expect(
      () => PairingLink.parse(uri.replaceFirst('v=1', 'v=2')),
      throwsFormatException,
    );
    expect(
      () =>
          PairingLink.parse(uri.replaceFirst(base64UrlEncode(secret), 'AAAA')),
      throwsFormatException,
    );
  });

  test(
    'bootstrap and device proofs bind the full request and refresh credential',
    () async {
      final request = await PairingCrypto.request(link, 'Android phone');
      addTearDown(request.dispose);
      final bootstrapMac = await Hmac.sha256().calculateMac(
        utf8.encode('lifenizer:enroll:v1'),
        secretKey: SecretKey(secret),
      );
      expect(
        request.body['bootstrapToken'],
        base64UrlEncode(bootstrapMac.bytes).replaceAll('=', ''),
      );
      expect(await PairingCrypto.verifyRequest(secret, request.body), isTrue);
      for (final field in [
        'deviceName',
        'refreshTokenHash',
        'proof',
        'publicKey',
        'nonce',
      ]) {
        expect(
          await PairingCrypto.verifyRequest(secret, {
            ...request.body,
            field: 'invalid',
          }),
          isFalse,
          reason: field,
        );
      }
      expect(
        await PairingCrypto.verifyRequest(
          List<int>.filled(32, 0),
          request.body,
        ),
        isFalse,
      );
      expect(
        jsonEncode(request.body),
        isNot(contains(base64UrlEncode(secret))),
      );
      expect(jsonEncode(request.body), isNot(contains(request.refreshToken)));
      expect(
        await PairingCrypto.verificationCode(request.body),
        matches(RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}$')),
      );
    },
  );

  test(
    'real X25519 transfer authenticates ciphertext, requester and connection secret',
    () async {
      final request = await PairingCrypto.request(link, 'KDE computer');
      final wrongKey = await PairingCrypto.request(link, 'KDE computer');
      addTearDown(request.dispose);
      addTearDown(wrongKey.dispose);
      const vaultPassphrase = 'private generated vault key';
      const until = 1893456000;
      final transfer = await PairingCrypto.encryptTransfer(
        request.body,
        vaultPassphrase,
        until,
        secret,
      );
      expect(await PairingCrypto.decryptTransfer(request, transfer, secret), {
        'vaultPassphrase': vaultPassphrase,
        'approvalUntil': until,
      });
      expect(jsonEncode(transfer), isNot(contains(vaultPassphrase)));
      expect(base64Decode(transfer['nonce'] as String), hasLength(12));
      expect(
        base64Decode(transfer['senderPublicKey'] as String),
        hasLength(32),
      );
      await expectLater(
        PairingCrypto.decryptTransfer(wrongKey, transfer, secret),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      final wrongSecret = List<int>.filled(32, 0);
      await expectLater(
        PairingCrypto.decryptTransfer(request, transfer, wrongSecret),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      final forged = await PairingCrypto.encryptTransfer(
        request.body,
        'relay chosen key',
        until,
        wrongSecret,
      );
      await expectLater(
        PairingCrypto.decryptTransfer(request, forged, secret),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      final packed =
          jsonDecode(
                utf8.decode(base64Decode(transfer['cipherText'] as String)),
              )
              as Map;
      final cipher = base64Decode(packed['c'] as String)..[0] ^= 1;
      packed['c'] = base64Encode(cipher);
      await expectLater(
        PairingCrypto.decryptTransfer(request, {
          ...transfer,
          'cipherText': base64Encode(utf8.encode(jsonEncode(packed))),
        }, secret),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    },
  );
}
