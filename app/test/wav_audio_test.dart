import 'dart:convert';
import 'dart:typed_data';

import 'package:app/services/wav_audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sentence clip excludes audio before and after its timestamps', () {
    final pcm = Uint8List(3 * 32000);
    pcm.fillRange(0, 32000, 11);
    pcm.fillRange(32000, 64000, 22);
    pcm.fillRange(64000, pcm.length, 33);
    final clip = clipWav(encodeWav(pcm), startMs: 1000, endMs: 2000);
    expect(clip.length, 32044);
    expect(clip.sublist(44), everyElement(22));
    expect(
      clipWav(encodeWav(pcm), startMs: 2000).sublist(44),
      everyElement(33),
    );
  });

  test(
    'invalid format, truncated audio and oversized sentences are rejected',
    () {
      final wav = encodeWav(Uint8List(32000));
      final stereo = Uint8List.fromList(wav);
      ByteData.sublistView(stereo).setUint16(22, 2, Endian.little);
      for (final bytes in [stereo, wav.sublist(0, wav.length - 1)]) {
        expect(() => clipWav(bytes, startMs: 0), throwsFormatException);
      }
      for (final start in [-1, 1000]) {
        expect(() => clipWav(wav, startMs: start), throwsFormatException);
      }
      expect(
        () => clipWav(encodeWav(Uint8List(121 * 32000)), startMs: 0),
        throwsFormatException,
      );
    },
  );

  test(
    'Whisper WAV carries correct format, length and PCM without corruption',
    () {
      final pcm = Uint8List.fromList([0, 0, 255, 127, 0, 128]);
      final wav = encodeWav(pcm);
      final header = ByteData.sublistView(wav);
      expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
      expect(header.getUint32(4, Endian.little), wav.length - 8);
      expect(header.getUint16(20, Endian.little), 1);
      expect(header.getUint16(22, Endian.little), 1);
      expect(header.getUint32(24, Endian.little), 16000);
      expect(header.getUint32(28, Endian.little), 32000);
      expect(header.getUint32(40, Endian.little), pcm.length);
      expect(wav.sublist(44), pcm);
    },
  );
}
