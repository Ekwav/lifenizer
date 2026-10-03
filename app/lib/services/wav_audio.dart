import 'dart:convert';
import 'dart:typed_data';

/// Wrap mono 16-bit little-endian PCM captured at 16 kHz in a WAV container.
Uint8List encodeWav(Uint8List pcm) {
  final data = ByteData(44 + pcm.length);
  final bytes = data.buffer.asUint8List();
  void label(int offset, String text) =>
      bytes.setRange(offset, offset + 4, ascii.encode(text));
  label(0, 'RIFF');
  data.setUint32(4, 36 + pcm.length, Endian.little);
  label(8, 'WAVE');
  label(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  label(36, 'data');
  data.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}
