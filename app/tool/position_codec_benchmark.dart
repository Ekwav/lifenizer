import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:app/services/search_posting_positions.dart';

/// Measures position decoding separately from SQLite, ranking and phrase joins.
/// All generated text-free fixtures and encrypted pages stay in memory.
Future<void> main() async {
  const documents = 2000000;
  const pageCount = (documents + 1023) ~/ 1024;
  final bitmap = Uint8List(128)..fillRange(0, 128, 255);
  final cipher = AesGcm.with256bits();
  final key = SecretKeyData(List<int>.generate(32, (i) => i));
  for (final fixture in [
    ('fixed', 1),
    ('fixed', 3),
    ('varied', 1),
    ('varied', 3),
  ]) {
    final random = Random(42);
    List<int> offsets() {
      if (fixture.$1 == 'fixed') return fixture.$2 == 1 ? [5] : [0, 128, 199];
      final values = <int>{};
      while (values.length < fixture.$2) {
        values.add(random.nextInt(200));
      }
      return values.toList()..sort();
    }

    final positions = <int, List<int>>{
      for (var document = 0; document < 1024; document++) document: offsets(),
    };
    final encoded = encodePostingPositions(bitmap, positions);
    final header = Uint8List(168)..setRange(0, bitmap.length, bitmap);
    Uint8List posting(List<int> tail) => Uint8List(header.length + tail.length)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + tail.length, tail);
    final raw = posting(encoded);
    final encrypted = <SecretBox>[];
    for (var page = 0; page < pageCount; page++) {
      encrypted.add(await cipher.encrypt(raw, secretKey: key));
    }
    var checksum = 0;
    void visit(int document, List<int> values) {
      checksum += document + values.last;
    }

    for (var i = 0; i < 64; i++) {
      visitPostingPositions(bitmap, encoded, visit);
    }
    final decode = Stopwatch()..start();
    for (var page = 0; page < pageCount; page++) {
      visitPostingPositions(bitmap, encoded, visit);
    }
    decode.stop();
    final decrypt = Stopwatch()..start();
    for (final box in encrypted) {
      final plain = await cipher.decrypt(box, secretKey: key);
      visitPostingPositions(
        bitmap,
        Uint8List.sublistView(
          plain is Uint8List ? plain : Uint8List.fromList(plain),
          header.length,
        ),
        visit,
      );
    }
    decrypt.stop();
    final compressed = posting(gzip.encode(encoded));
    final compressedPages = <SecretBox>[];
    for (var page = 0; page < pageCount; page++) {
      compressedPages.add(await cipher.encrypt(compressed, secretKey: key));
    }
    final decompress = Stopwatch()..start();
    for (final box in compressedPages) {
      final packed = await cipher.decrypt(box, secretKey: key);
      final plain = gzip.decode(
        Uint8List.sublistView(
          packed is Uint8List ? packed : Uint8List.fromList(packed),
          header.length,
        ),
      );
      visitPostingPositions(
        bitmap,
        plain is Uint8List ? plain : Uint8List.fromList(plain),
        visit,
      );
    }
    decompress.stop();
    final scored = encodePostingPositions(
      bitmap,
      positions,
      fieldBoosts: {
        for (var document = 0; document < 1024; document++)
          document: document % 100 == 0 ? 4 : 0,
      },
    );
    void score(int document, int tf, int boost) {
      checksum += document + tf + boost;
    }

    final scoreDecode = Stopwatch()..start();
    for (var page = 0; page < pageCount; page++) {
      visitPostingScores(bitmap, scored, score);
    }
    scoreDecode.stop();
    final v5 = posting([5, ...gzip.encode(scored)]);
    final scoredPages = <SecretBox>[];
    for (var page = 0; page < pageCount; page++) {
      scoredPages.add(await cipher.encrypt(v5, secretKey: key));
    }
    final scoreDecrypt = Stopwatch()..start();
    for (final box in scoredPages) {
      final packed = await cipher.decrypt(box, secretKey: key);
      if (packed[header.length] != 5) throw StateError('Invalid v5 marker.');
      final plain = gzip.decode(
        Uint8List.sublistView(
          packed is Uint8List ? packed : Uint8List.fromList(packed),
          header.length + 1,
        ),
      );
      visitPostingScores(
        bitmap,
        plain is Uint8List ? plain : Uint8List.fromList(plain),
        score,
      );
    }
    scoreDecrypt.stop();
    final encode = Stopwatch()..start();
    for (var page = 0; page < pageCount; page++) {
      checksum += encodePostingPositions(bitmap, positions).length;
    }
    encode.stop();
    stdout.writeln(
      jsonEncode({
        'documents': pageCount * 1024,
        'fixture': fixture.$1,
        'occurrencesPerDocument': fixture.$2,
        'encryptedBytes': (raw.length + 28) * pageCount,
        'decodeMilliseconds': decode.elapsedMicroseconds / 1000,
        'decryptAndDecodeMilliseconds': decrypt.elapsedMicroseconds / 1000,
        'compressedEncryptedBytes': (compressed.length + 28) * pageCount,
        'decryptInflateDecodeMilliseconds':
            decompress.elapsedMicroseconds / 1000,
        'v5EncryptedBytes': (v5.length + 28) * pageCount,
        'v5ScoreDecodeMilliseconds': scoreDecode.elapsedMicroseconds / 1000,
        'v5ScoreDecryptInflateMilliseconds':
            scoreDecrypt.elapsedMicroseconds / 1000,
        'encodeMilliseconds': encode.elapsedMicroseconds / 1000,
        'checksum': checksum,
      }),
    );
  }
  key.destroy();
}
