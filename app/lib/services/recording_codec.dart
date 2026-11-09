import 'package:flutter/foundation.dart';

import 'audio_format.dart';
import 'recording_codec_io.dart'
    if (dart.library.js_interop) 'recording_codec_web.dart';
import 'wav_audio.dart';

/// Where libopus is found: Linux soname first, then the Android/bundled name.
const defaultOpusLibraries = ['libopus.so.0', 'libopus.so'];

/// Stores a finished 16 kHz mono PCM16 recording as Ogg Opus (~7 MB for 30
/// minutes) when this platform can encode it, otherwise as WAV like before.
Future<Uint8List> encodeRecording(
  Uint8List pcm, {
  List<String> opusLibraries = defaultOpusLibraries,
}) async {
  try {
    final ogg = await encodeOpusInWorker(pcm, opusLibraries);
    if (ogg != null) return ogg;
  } catch (failure) {
    // A broken codec must never lose the recording.
    debugPrint('Opus encoding failed, keeping WAV: $failure');
  }
  return encodeWav(pcm);
}

/// Longest sentence a correction may use (as enforced by [clipWav]).
const _maxClipMs = 120000;

const _invalidSentence = FormatException(
  'Select a valid audio sentence of at most two minutes.',
);

const _cannotDecode = FormatException(
  'This device cannot decode the compressed recording. Open it in the Android or Linux app.',
);

/// A 16 kHz mono PCM WAV clip of [startMs, endMs) for corrections. Ogg Opus
/// is decoded in a worker from shortly before [startMs] only; WAV is cut as
/// before; anything else is rejected by [clipWav].
Future<Uint8List> recordingClip(
  List<int> bytes, {
  required int startMs,
  int? endMs,
  List<String> opusLibraries = defaultOpusLibraries,
}) async {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (RecordingFormat.detect(data) != RecordingFormat.oggOpus) {
    return compute(_wavClip, (data, startMs, endMs));
  }
  if (startMs < 0) throw _invalidSentence;
  // One millisecond past the limit still lets clipWav reject a long sentence.
  final limit = startMs + _maxClipMs + 1;
  final clip = await decodeOpusClip(
    data,
    opusLibraries,
    startMs: startMs,
    endMs: endMs == null || endMs > limit ? limit : endMs,
  );
  if (clip == null) throw _cannotDecode;
  return clip;
}

Uint8List _wavClip((Uint8List, int, int?) input) =>
    clipWav(input.$1, startMs: input.$2, endMs: input.$3);

/// Bytes for SoLoud's in-memory player. SoLoud decodes Ogg Opus to 48 kHz
/// floats (~345 MB for 30 minutes), so where libopus is available we hand it
/// 16 kHz WAV built in the worker instead, the same as legacy recordings. The
/// web build, or a stream we cannot read, goes to SoLoud unchanged.
Future<Uint8List> recordingForPlayback(
  Uint8List bytes, {
  List<String> opusLibraries = defaultOpusLibraries,
}) async {
  if (kIsWeb || RecordingFormat.detect(bytes) != RecordingFormat.oggOpus) {
    return bytes;
  }
  try {
    return await decodeOpusToWav(bytes, opusLibraries) ?? bytes;
  } on FormatException {
    return bytes;
  }
}
