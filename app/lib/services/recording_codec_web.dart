import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'pcm_convert.dart';
import 'wav_audio.dart';

// Browsers keep recording WAV and play Ogg Opus through SoLoud; sentence
// clips of Opus recordings (for example synced from Android) are decoded by
// the browser's WebAudio decoder.

Future<Uint8List?> encodeOpusInWorker(
  Uint8List pcm,
  List<String> libraries,
) async => null;

/// Decodes 16 kHz samples [start, end) of [ogg] to a WAV.
Future<Uint8List?> decodeOpusToWav(
  Uint8List ogg,
  List<String> libraries, {
  int start = 0,
  int? end,
}) async {
  final samples = await _decodeAt16k(ogg);
  final from = start.clamp(0, samples.length);
  final to = (end ?? samples.length).clamp(from, samples.length);
  return floatToWav(Float32List.sublistView(samples, from, to));
}

Future<Uint8List?> decodeOpusClip(
  Uint8List ogg,
  List<String> libraries, {
  required int startMs,
  required int endMs,
}) async {
  final wav = await decodeOpusToWav(
    ogg,
    libraries,
    start: startMs * 16,
    end: endMs * 16,
  );
  return clipWav(wav!, startMs: 0);
}

Future<Float32List> _decodeAt16k(Uint8List ogg) async {
  final buffer = await _decodeInBrowser(ogg);
  final channels = [
    for (var channel = 0; channel < buffer.numberOfChannels; channel++)
      buffer.getChannelData(channel).toDart,
  ];
  return resample(downmix(channels), buffer.sampleRate.round(), 16000);
}

Future<web.AudioBuffer> _decodeInBrowser(Uint8List ogg) async {
  try {
    // decodeAudioData detaches its input, so it gets a copy.
    final input = Uint8List.fromList(ogg).buffer.toJS;
    return await _offlineContext().decodeAudioData(input).toDart;
  } catch (_) {
    throw const FormatException(
      'This browser cannot decode the compressed recording. Open it in the Android or Linux app.',
    );
  }
}

/// Decoding resamples to the context's rate; some browsers refuse 16 kHz.
web.OfflineAudioContext _offlineContext() {
  try {
    return web.OfflineAudioContext(1.toJS, 1, 16000);
  } catch (_) {
    return web.OfflineAudioContext(1.toJS, 1, 48000);
  }
}
