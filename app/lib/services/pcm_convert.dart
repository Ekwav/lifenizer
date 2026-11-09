import 'dart:typed_data';

import 'wav_audio.dart';

/// Averages [channels] into one mono channel.
Float32List downmix(List<Float32List> channels) {
  if (channels.length == 1) return channels.single;
  final length = channels.map((c) => c.length).reduce((a, b) => a < b ? a : b);
  final mono = Float32List(length);
  for (final channel in channels) {
    for (var i = 0; i < length; i++) {
      mono[i] += channel[i] / channels.length;
    }
  }
  return mono;
}

/// Changes the sample rate: box-averaged when downsampling (a simple
/// anti-alias filter), linearly interpolated when upsampling.
Float32List resample(Float32List input, int fromRate, int toRate) {
  if (fromRate == toRate) return input;
  final length = input.length * toRate ~/ fromRate;
  final ratio = fromRate / toRate;
  return ratio > 1
      ? _boxDownsample(input, length, ratio)
      : _interpolate(input, length, ratio);
}

Float32List _boxDownsample(Float32List input, int length, double ratio) {
  final output = Float32List(length);
  for (var i = 0; i < length; i++) {
    final from = (i * ratio).floor();
    final to = ((i + 1) * ratio).floor().clamp(from + 1, input.length);
    var sum = 0.0;
    for (var j = from; j < to; j++) {
      sum += input[j];
    }
    output[i] = sum / (to - from);
  }
  return output;
}

Float32List _interpolate(Float32List input, int length, double ratio) {
  final output = Float32List(length);
  final last = input.length - 1;
  for (var i = 0; i < length; i++) {
    final position = i * ratio;
    final left = position.floor().clamp(0, last);
    final right = (left + 1).clamp(0, last);
    final weight = position - left;
    output[i] = input[left] * (1 - weight) + input[right] * weight;
  }
  return output;
}

/// Float samples in [-1, 1] (clipped beyond) as a 16 kHz mono PCM16 WAV.
Uint8List floatToWav(Float32List samples) {
  final wav = wavBuffer(samples.length);
  final data = ByteData.sublistView(wav);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, _toPcm16(samples[i]), Endian.little);
  }
  return wav;
}

int _toPcm16(double sample) => (sample.clamp(-1.0, 1.0) * 32767).round();
