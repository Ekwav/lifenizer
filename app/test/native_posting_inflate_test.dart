import 'dart:typed_data';
import 'package:app/services/native_posting_inflate.dart';
import 'package:archive/archive.dart' as archive;
import 'package:flutter_test/flutter_test.dart';

Uint8List managed(Uint8List bytes) {
  final out = archive.OutputMemoryStream(size: 64);
  if (!const archive.GZipDecoderWeb().decodeStream(
    archive.InputMemoryStream(bytes),
    out,
    verify: true,
  )) {
    throw const FormatException('Invalid gzip');
  }
  return out.getBytes();
}

Uint8List encode(List<int> bytes) =>
    const archive.GZipEncoderWeb().encodeBytes(bytes);
Uint8List decode(Uint8List bytes, NativePostingInflate? decoder) =>
    decoder?.decode(bytes) ?? managed(bytes);
void main() {
  final decoder = NativePostingInflate.tryCreate();
  test('optional query inflater matches managed bytes through64KiB', () {
    for (final size in [0, 1, 127, 1024, 65536]) {
      final plain = Uint8List.fromList(
            List.generate(size, (i) => (i * 37) & 255),
          ),
          packed = encode(plain);
      expect(decode(packed, decoder), plain);
      expect(decode(packed, null), plain);
      if (decoder != null) expect(decoder.decode(packed), plain);
    }
    if (decoder != null) expect(decoder.successfulInflates, greaterThan(0));
  });
  test('oversized input or declared output uses managed fallback', () {
    final plain = Uint8List(65537), packed = encode(Uint8List(65537));
    expect(decoder?.decode(packed), isNull);
    expect(decode(packed, decoder), plain);
    expect(decoder?.decode(Uint8List(128 * 1024 + 1)), isNull);
  });
  test('CRC, size, truncation and trailing data keep strict rejection', () {
    final packed = encode([1, 2, 3, 4, 5]);
    final bad = <Uint8List>[
      for (var length = 0; length < packed.length; length++)
        Uint8List.sublistView(packed, 0, length),
      Uint8List.fromList([...packed, 0]),
      Uint8List.fromList([...packed, 31, 139, 8, 0, 0, 0, 0, 0, 0, 0]),
      for (final at in [packed.length - 8, packed.length - 4])
        Uint8List.fromList(packed)..[at] ^= 1,
    ];
    for (final bytes in bad) {
      expect(decoder?.decode(bytes), isNull);
      expect(() => decode(bytes, decoder), throwsFormatException);
    }
  });
  test('legacy headers and concatenated members remain managed-compatible', () {
    final one = encode([1, 2]), two = encode([3, 4, 5]);
    final concat = Uint8List.fromList([...one, ...two]);
    expect(decoder?.decode(concat), isNull);
    expect(decode(concat, decoder), [1, 2, 3, 4, 5]);
    final name = Uint8List.fromList([
      ...one.take(10),
      65,
      66,
      0,
      ...one.skip(10),
    ])..[3] = 8;
    expect(decoder?.decode(name), isNull);
    expect(decode(name, decoder), [1, 2]);
  });
  test('native success owns output and leaves input intact', () {
    final packed = encode([1, 2, 3]), before = Uint8List.fromList(packed);
    final output = decode(packed, decoder);
    output[0] = 9;
    expect(packed, before);
    expect(decode(packed, decoder), [1, 2, 3]);
  });
}
