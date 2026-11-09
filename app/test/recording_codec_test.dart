import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/audio_format.dart';
import 'package:app/services/ogg_opus.dart';
import 'package:app/services/opus_native.dart';
import 'package:app/services/recording_codec.dart';
import 'package:app/services/wav_audio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/opus_fixture.dart';

const _missing = ['libopus-does-not-exist.so'];
final _hasOpus = OpusLibrary.tryOpen(defaultOpusLibraries) != null;
// CI installs libopus, so a missing library fails there instead of skipping.
final _onCi = Platform.environment['CI'] != null;
final _skipOpus = _hasOpus || _onCi ? false : 'libopus is not installed';

/// [seconds] of a 440 Hz tone as 16 kHz mono PCM16.
Uint8List tone(double seconds) {
  final samples = (16000 * seconds).round();
  final pcm = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    final value = math.sin(2 * math.pi * 440 * i / 16000) * 12000;
    pcm.setInt16(i * 2, value.round(), Endian.little);
  }
  return pcm.buffer.asUint8List();
}

Int16List samplesOf(Uint8List wav) {
  final data = ByteData.sublistView(wav, 44);
  return Int16List.fromList(
    List.generate(
      data.lengthInBytes ~/ 2,
      (i) => data.getInt16(i * 2, Endian.little),
    ),
  );
}

/// Normalized cross-correlation at zero lag: 1 means identical shape.
double correlation(Uint8List a, Int16List b) {
  final left = ByteData.sublistView(a);
  var dot = 0.0, energyA = 0.0, energyB = 0.0;
  for (var i = 0; i < b.length; i++) {
    final x = left.getInt16(i * 2, Endian.little).toDouble();
    final y = b[i].toDouble();
    dot += x * y;
    energyA += x * x;
    energyB += y * y;
  }
  return dot / math.sqrt(energyA * energyB);
}

void main() {
  group('encodeRecording', () {
    test('falls back to WAV without an Opus encoder', () async {
      final pcm = tone(0.2);
      final stored = await encodeRecording(pcm, opusLibraries: _missing);
      expect(RecordingFormat.detect(stored), RecordingFormat.wav);
      expect(stored.sublist(44), pcm);
    });

    test('stores Ogg Opus that decodes back in place', () async {
      final pcm = tone(2.5);
      final stored = await encodeRecording(pcm);

      expect(RecordingFormat.detect(stored), RecordingFormat.oggOpus);
      expect(stored.length, lessThan(pcm.length ~/ 6));
      final stream = OggOpusStream.parse(stored);
      expect(stream.preSkip % 3, 0);
      expect(stream.endGranule, stream.preSkip + pcm.length ~/ 2 * 3);

      final wav = await recordingForPlayback(stored);
      final decoded = samplesOf(wav);
      expect(decoded.length, pcm.length ~/ 2);
      // A wrong pre-skip shifts the tone and destroys the correlation.
      expect(correlation(pcm, decoded), greaterThan(0.9));
    }, skip: _skipOpus);
  });

  test('libopus is available on CI', () {
    expect(_hasOpus, isTrue, reason: 'install libopus0 in the CI job');
  }, skip: _onCi ? false : 'only enforced on CI');

  group('recordingClip', () {
    test('cuts WAV as before and rejects other files', () async {
      final wav = await encodeRecording(tone(1), opusLibraries: _missing);
      final clip = await recordingClip(wav, startMs: 250, endMs: 500);
      expect(clip, clipWav(wav, startMs: 250, endMs: 500));
      expect(
        recordingClip([1, 2, 3], startMs: 0, endMs: 10),
        throwsFormatException,
      );
    });

    test('matches decoding everything and then clipping', () async {
      final stored = await encodeRecording(tone(30));
      final full = await recordingForPlayback(stored);
      final expected = samplesOf(clipWav(full, startMs: 20000, endMs: 21000));

      final clip = await recordingClip(stored, startMs: 20000, endMs: 21000);
      final actual = samplesOf(clip);

      expect(actual.length, expected.length);
      // With the 500 ms pre-roll the decoder state has fully converged.
      var worst = 0;
      for (var i = 0; i < actual.length; i++) {
        worst = math.max(worst, (actual[i] - expected[i]).abs());
      }
      expect(worst, lessThanOrEqualTo(2));
    }, skip: _skipOpus);

    test('decodes the start of a recording and stops at endMs', () async {
      final stored = await encodeRecording(tone(2));
      final clip = await recordingClip(stored, startMs: 0, endMs: 500);
      expect(samplesOf(clip).length, 8000);
    }, skip: _skipOpus);

    test('still rejects sentences longer than two minutes', () async {
      final stored = await encodeRecording(tone(130));
      expect(
        recordingClip(stored, startMs: 1000, endMs: null),
        throwsFormatException,
      );
      expect(
        recordingClip(stored, startMs: -1, endMs: 10),
        throwsFormatException,
      );
    }, skip: _skipOpus);

    test('explains when Opus cannot be decoded here', () {
      expect(
        recordingClip(
          ffmpegOgg,
          startMs: 0,
          endMs: 50,
          opusLibraries: _missing,
        ),
        throwsFormatException,
      );
    });
  });

  group('recordingForPlayback', () {
    test('plays Opus as 16 kHz WAV where libopus decodes it', () async {
      final wav = await recordingForPlayback(ffmpegOgg);
      expect(RecordingFormat.detect(wav), RecordingFormat.wav);
      expect(samplesOf(wav).length, 1600);
    }, skip: _skipOpus);

    test('hands Opus to the player unchanged without a decoder', () async {
      final ogg = Uint8List.fromList(ffmpegOgg);
      final played = await recordingForPlayback(ogg, opusLibraries: _missing);
      expect(played, same(ogg));
    });

    test('decodes what precedes a page cut off mid-write', () async {
      final stored = await encodeRecording(tone(3));
      final cut = Uint8List.sublistView(stored, 0, stored.length - 100);
      final wav = await recordingForPlayback(cut);
      expect(RecordingFormat.detect(wav), RecordingFormat.wav);
      final samples = samplesOf(wav).length;
      expect(samples, greaterThan(16000));
      expect(samples, lessThan(48000));
    }, skip: _skipOpus);

    test('hands unreadable Opus to the player unchanged', () async {
      // 40 bytes of garbage where the next page should start.
      final broken = Uint8List.fromList([...ffmpegOgg, ...List.filled(40, 65)]);
      final played = await recordingForPlayback(broken);
      expect(played, same(broken));
    }, skip: _skipOpus);

    test('leaves WAV alone', () async {
      final wav = await encodeRecording(tone(0.1), opusLibraries: _missing);
      expect(await recordingForPlayback(wav), same(wav));
    });
  });

  test('a sentence clip of an Opus recording is a WAV clip', () async {
    final stored = await encodeRecording(tone(3));
    final segment = ConversationSegment(
      id: 'second',
      text: 'second',
      offsetMs: 1000,
      endMs: 2000,
    );
    final conversation = Conversation(
      id: 'memo',
      title: 'Memo',
      source: 'audio',
      participantIds: [],
      segments: [segment],
    );
    final state = LifenizerAppState();
    addTearDown(state.dispose);
    final clip = await state.loadTranscriptionSentence(
      conversation: conversation,
      segment: segment,
      audioOverride: stored,
    );
    expect(RecordingFormat.detect(clip.bytes), RecordingFormat.wav);
    expect(samplesOf(clip.bytes).length, 16000);
    expect(clip.fileName, 'sentence.wav');
  }, skip: _skipOpus);
}
