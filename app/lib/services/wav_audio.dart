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

/// Extract only the selected sentence from our 16 kHz mono PCM WAV recordings.
Uint8List clipWav(List<int> source, {required int startMs, int? endMs}) {
  final bytes = Uint8List.fromList(source);
  if (bytes.length < 44 ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WAVE') {
    throw const FormatException(
      'Choose the original 16 kHz mono PCM WAV recording.',
    );
  }
  final data = ByteData.sublistView(bytes);
  var validFormat = false;
  int? offset;
  var length = 0;
  for (var position = 12; position + 8 <= bytes.length;) {
    final size = data.getUint32(position + 4, Endian.little);
    final next = position + 8 + size;
    if (next > bytes.length) {
      throw const FormatException('The WAV recording is truncated.');
    }
    final name = ascii.decode(
      bytes.sublist(position, position + 4),
      allowInvalid: true,
    );
    if (name == 'fmt ' && size >= 16) {
      validFormat =
          data.getUint16(position + 8, Endian.little) == 1 &&
          data.getUint16(position + 10, Endian.little) == 1 &&
          data.getUint32(position + 12, Endian.little) == 16000 &&
          data.getUint16(position + 20, Endian.little) == 2 &&
          data.getUint16(position + 22, Endian.little) == 16;
    } else if (name == 'data') {
      offset = position + 8;
      length = size;
      break;
    }
    position = next + (size.isOdd ? 1 : 0);
  }
  if (!validFormat || offset == null || length.isOdd) {
    throw const FormatException(
      'Choose the original 16 kHz mono PCM WAV recording.',
    );
  }
  final start = startMs * 32;
  final requestedEnd = endMs == null ? length : endMs * 32;
  final end = requestedEnd.clamp(0, length);
  if (startMs < 0 || start >= end || (end - start) > 16000 * 2 * 120) {
    throw const FormatException(
      'Select a valid audio sentence of at most two minutes.',
    );
  }
  return encodeWav(Uint8List.sublistView(bytes, offset + start, offset + end));
}
