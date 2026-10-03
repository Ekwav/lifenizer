import 'dart:convert';
import 'dart:typed_data';

import 'package:app/services/wav_audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
