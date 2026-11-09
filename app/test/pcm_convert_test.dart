import 'dart:typed_data';

import 'package:app/services/audio_format.dart';
import 'package:app/services/pcm_convert.dart';
import 'package:flutter_test/flutter_test.dart';

Int16List samplesOf(Uint8List wav) {
  final data = ByteData.sublistView(wav, 44);
  return Int16List.fromList(
    List.generate(
      data.lengthInBytes ~/ 2,
      (i) => data.getInt16(i * 2, Endian.little),
    ),
  );
}

void main() {
  test('floatToWav rounds, scales and clips to PCM16', () {
    final wav = floatToWav(
      Float32List.fromList([0, 0.5, -0.5, 1, -1, 1.7, -3, 0.00002]),
    );
    expect(RecordingFormat.detect(wav), RecordingFormat.wav);
    expect(samplesOf(wav), [0, 16384, -16384, 32767, -32767, 32767, -32767, 1]);
  });

  test('resample keeps the rate when nothing changes', () {
    final input = Float32List.fromList([0.1, 0.2]);
    expect(resample(input, 16000, 16000), same(input));
  });

  test('downsampling 48 kHz averages each group of three', () {
    final input = Float32List.fromList([0, 0.3, 0.6, 1, 1, 1, -1, 0, 1]);
    final output = resample(input, 48000, 16000);
    expect(output, hasLength(3));
    expect(output[0], closeTo(0.3, 1e-6));
    expect(output[1], closeTo(1, 1e-6));
    expect(output[2], closeTo(0, 1e-6));
  });

  test('downsampling 44.1 kHz keeps a constant level and the duration', () {
    final input = Float32List(44100)..fillRange(0, 44100, 0.25);
    final output = resample(input, 44100, 16000);
    expect(output, hasLength(16000));
    expect(output.every((value) => (value - 0.25).abs() < 1e-6), isTrue);
  });

  test('upsampling interpolates between neighbours', () {
    final output = resample(Float32List.fromList([0, 1]), 8000, 16000);
    expect(output, hasLength(4));
    expect(output[0], 0);
    expect(output[1], closeTo(0.5, 1e-6));
    expect(output[2], 1);
  });

  test('downmix averages channels', () {
    final mono = downmix([
      Float32List.fromList([1, 0.5]),
      Float32List.fromList([0, -0.5]),
    ]);
    expect(mono, [0.5, 0]);
  });
}
