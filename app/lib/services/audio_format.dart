import 'dart:typed_data';

/// Recording containers the app writes itself, detected by magic bytes.
enum RecordingFormat {
  wav('audio/wav', 'wav'),
  oggOpus('audio/ogg', 'ogg');

  const RecordingFormat(this.contentType, this.extension);
  final String contentType;
  final String extension;

  String get fileName => 'recording.$extension';

  /// The format of [bytes], or null for anything else (mp3, m4a, …).
  static RecordingFormat? detect(List<int> bytes) {
    if (_isWav(bytes)) return wav;
    if (_isOggOpus(bytes)) return oggOpus;
    return null;
  }
}

bool _isWav(List<int> bytes) =>
    bytes.length >= 12 &&
    _matches(bytes, 0, _riff) &&
    _matches(bytes, 8, _wave);

// The backend accepts OpusHead anywhere in the first 128 bytes; so do we.
bool _isOggOpus(List<int> bytes) {
  if (bytes.length < 36 || !_matches(bytes, 0, _oggS)) return false;
  final end = bytes.length < 128 ? bytes.length : 128;
  for (var offset = 4; offset + _opusHead.length <= end; offset++) {
    if (_matches(bytes, offset, _opusHead)) return true;
  }
  return false;
}

bool _matches(List<int> bytes, int offset, Uint8List magic) {
  for (var i = 0; i < magic.length; i++) {
    if (bytes[offset + i] != magic[i]) return false;
  }
  return true;
}

final _riff = Uint8List.fromList('RIFF'.codeUnits);
final _wave = Uint8List.fromList('WAVE'.codeUnits);
final _oggS = Uint8List.fromList('OggS'.codeUnits);
final _opusHead = Uint8List.fromList('OpusHead'.codeUnits);
