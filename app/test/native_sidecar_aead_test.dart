import 'dart:io';
import 'dart:typed_data';

import 'package:app/services/native_sidecar_aead.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _pack(SecretBox box) => Uint8List(28 + box.cipherText.length)
  ..setRange(0, 12, box.nonce)
  ..setRange(12, 28, box.mac.bytes)
  ..setRange(28, 28 + box.cipherText.length, box.cipherText);

SecretBox _unpack(Uint8List packed) => SecretBox(
  Uint8List.sublistView(packed, 28),
  nonce: Uint8List.sublistView(packed, 0, 12),
  mac: Mac(Uint8List.sublistView(packed, 12, 28)),
);

void main() {
  final probe = NativeSidecarAead.tryCreate(Uint8List(32));
  final nativeAvailable = probe != null;
  probe?.dispose();
  final cipher = AesGcm.with256bits();

  test(
    'Dart fallback preserves the envelope without a native backend',
    () async {
      final bytes = Uint8List.fromList(List.generate(32, (i) => i));
      final key = SecretKeyData(bytes, overwriteWhenDestroyed: true);
      try {
        final plain = Uint8List.fromList([0, 1, 2, 255]);
        final packed = _pack(
          await cipher.encrypt(plain, secretKey: key, nonce: Uint8List(12)),
        );
        expect(packed.length, plain.length + 28);
        expect(await cipher.decrypt(_unpack(packed), secretKey: key), plain);
        packed[12] ^= 1;
        await expectLater(
          cipher.decrypt(_unpack(packed), secretKey: key),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
      } finally {
        key.destroy();
      }
      expect(bytes, everyElement(0));
    },
  );

  test('native availability is optional and restricted to Linux', () {
    final backend = NativeSidecarAead.tryCreate(Uint8List(32));
    try {
      expect(backend != null, nativeAvailable);
      if (!Platform.isLinux) expect(backend, isNull);
    } finally {
      backend?.dispose();
    }
  });

  group(
    'native AES-GCM',
    () {
      late Uint8List rawKey;
      late SecretKeyData key;
      late NativeSidecarAead native;
      setUp(() {
        rawKey = Uint8List.fromList(List.generate(32, (i) => i));
        key = SecretKeyData(rawKey, overwriteWhenDestroyed: true);
        native = NativeSidecarAead.tryCreate(key.bytes)!;
      });
      tearDown(() {
        try {
          native.dispose();
        } finally {
          key.destroy();
        }
      });

      test('matches Dart ciphertext and decrypts in both directions', () async {
        for (final size in [0, 1, 15, 16, 17, 681, 1000, 65536]) {
          final plain = Uint8List.fromList(
            List.generate(size, (i) => (i * 37) & 255),
          );
          final nonce = Uint8List.fromList(
            List.generate(12, (i) => (size + i) & 255),
          );
          for (final aad in [
            <int>[],
            [1, 2, 3],
          ]) {
            final expected = _pack(
              await cipher.encrypt(
                plain,
                secretKey: key,
                nonce: nonce,
                aad: aad,
              ),
            );
            final actual = native.encrypt(plain, nonce, aad: aad);
            expect(actual, expected);
            expect(native.decrypt(expected, aad: aad), plain);
            expect(
              await cipher.decrypt(_unpack(actual), secretKey: key, aad: aad),
              plain,
            );
          }
        }
      });

      test(
        'rejects tampering and remains usable after authentication errors',
        () {
          final plain = Uint8List.fromList([1, 2, 3, 4]);
          final packed = native.encrypt(plain, Uint8List(12), aad: [5, 6]);
          for (final position in [0, 12, 28]) {
            final tampered = Uint8List.fromList(packed)..[position] ^= 1;
            expect(
              () => native.decrypt(tampered, aad: [5, 6]),
              throwsA(isA<SecretBoxAuthenticationError>()),
            );
            expect(native.decrypt(packed, aad: [5, 6]), plain);
          }
          expect(
            () => native.decrypt(packed, aad: [5, 7]),
            throwsA(isA<SecretBoxAuthenticationError>()),
          );
          expect(native.decrypt(packed, aad: [5, 6]), plain);
        },
      );

      test(
        'batch decryption preserves mixed-size wire bytes and AAD',
        () async {
          for (final aad in <List<int>>[
            [],
            [5, 6],
          ]) {
            final plains = <Uint8List>[];
            final packed = <Uint8List>[];
            for (final size in [0, 1, 681, 1000, 65536]) {
              final plain = Uint8List.fromList(
                List.generate(size, (i) => i & 255),
              );
              plains.add(plain);
              packed.add(
                _pack(
                  await cipher.encrypt(
                    plain,
                    secretKey: key,
                    nonce: Uint8List.fromList(
                      List.generate(12, (i) => (size + i) & 255),
                    ),
                    aad: aad,
                  ),
                ),
              );
            }
            expect(native.decryptMany(packed, aad: aad), plains);
            final independent = native.decryptMany([
              packed[1],
              packed[1],
            ], aad: aad);
            independent.first[0] ^= 1;
            expect(independent.last, plains[1]);
            expect(native.decrypt(packed[1], aad: aad), plains[1]);
            expect(
              () => native.decryptMany(packed, aad: [...aad, 7]),
              throwsA(isA<SecretBoxAuthenticationError>()),
            );
          }
        },
      );

      test('batch limits accept exact boundaries and reject excess', () {
        final packed = native.encrypt([1], Uint8List(12));
        expect(
          native.decryptMany(List.filled(512, packed)),
          everyElement(orderedEquals([1])),
        );
        expect(native.decryptMany([]), isEmpty);
        expect(
          () => native.decryptMany(List.filled(513, packed)),
          throwsArgumentError,
        );
        final plain = Uint8List(4 * 1024 * 1024 - 28);
        final boundary = native.encrypt(plain, Uint8List(12));
        expect(native.decryptMany([boundary]).single, plain);
        expect(
          () => native.decryptMany([Uint8List(boundary.length + 1)]),
          throwsArgumentError,
        );
        expect(
          () => native.decryptMany([boundary, packed]),
          throwsArgumentError,
        );
        expect(native.decryptMany([packed]).single, [1]);
      });

      test(
        'batch rejects middle auth errors without changing inputs and recovers',
        () {
          final plain = Uint8List.fromList([1, 2, 3, 4]);
          final packed = native.encrypt(plain, Uint8List(12), aad: [5, 6]);
          for (final position in [0, 12, 28]) {
            final tampered = Uint8List.fromList(packed)..[position] ^= 1;
            final rows = List<Uint8List>.filled(512, packed)..[256] = tampered;
            final before = [for (final row in rows) Uint8List.fromList(row)];
            expect(
              () => native.decryptMany(rows, aad: [5, 6]),
              throwsA(isA<SecretBoxAuthenticationError>()),
            );
            expect(rows, before);
            expect(native.decrypt(packed, aad: [5, 6]), plain);
            expect(native.decryptMany([packed], aad: [5, 6]), [plain]);
          }
          expect(
            () => native.decryptMany([packed, Uint8List(27)], aad: [5, 6]),
            throwsRangeError,
          );
          expect(native.decryptMany([packed], aad: [5, 6]), [plain]);
        },
      );

      test('rejects truncated envelopes and invalid nonce lengths', () {
        for (var length = 0; length < 28; length++) {
          expect(() => native.decrypt(Uint8List(length)), throwsRangeError);
        }
        for (final length in [0, 11, 13]) {
          expect(
            () => native.encrypt([], Uint8List(length)),
            throwsArgumentError,
          );
        }
        expect(
          () => NativeSidecarAead.tryCreate(Uint8List(31)),
          throwsArgumentError,
        );
      });

      test(
        'owns its key copy and rejects use after idempotent disposal',
        () async {
          final plain = Uint8List.fromList([3, 2, 1]);
          final packed = _pack(
            await cipher.encrypt(plain, secretKey: key, nonce: Uint8List(12)),
          );
          key.destroy();
          expect(rawKey, everyElement(0));
          expect(native.decrypt(packed), plain);
          native.dispose();
          native.dispose();
          expect(() => native.decrypt(packed), throwsStateError);
          expect(() => native.decryptMany([packed]), throwsStateError);
          expect(() => native.encrypt(plain, Uint8List(12)), throwsStateError);
        },
      );
    },
    skip: nativeAvailable
        ? false
        : 'Native Linux AES-GCM unavailable; Dart fallback tests still run.',
  );
}
