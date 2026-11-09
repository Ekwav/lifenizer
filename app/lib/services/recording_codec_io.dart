import 'dart:isolate';
import 'dart:typed_data';

import 'opus_native.dart';
import 'wav_audio.dart';

/// Encodes in a worker isolate; null when libopus is unavailable.
Future<Uint8List?> encodeOpusInWorker(Uint8List pcm, List<String> libraries) =>
    Isolate.run(
      () => OpusLibrary.tryOpen(libraries)?.encodeOggOpus(pcm),
      debugName: 'opus-encode',
    );

/// Decodes 16 kHz samples [start, end) to WAV in a worker isolate; null when
/// libopus is unavailable.
Future<Uint8List?> decodeOpusToWav(
  Uint8List ogg,
  List<String> libraries, {
  int start = 0,
  int? end,
}) => Isolate.run(
  () => OpusLibrary.tryOpen(
    libraries,
  )?.decodeOggOpusWav(ogg, start: start, end: end),
  debugName: 'opus-decode',
);

/// Decodes [startMs, endMs) and validates it as a sentence clip, all in the
/// worker; null when libopus is unavailable.
Future<Uint8List?> decodeOpusClip(
  Uint8List ogg,
  List<String> libraries, {
  required int startMs,
  required int endMs,
}) => Isolate.run(() {
  final opus = OpusLibrary.tryOpen(libraries);
  if (opus == null) return null;
  final wav = opus.decodeOggOpusWav(ogg, start: startMs * 16, end: endMs * 16);
  return clipWav(wav, startMs: 0);
}, debugName: 'opus-clip');
