import 'dart:async';
import 'package:app/app_state.dart';
import 'package:app/services/recording_playback.dart';
import 'package:flutter_test/flutter_test.dart';

class _Engine implements RecordingAudioEngine {
  final events = StreamController<void>.broadcast(sync: true);
  int plays = 0;
  int pauses = 0;
  bool disposed = false;
  RecordingAudio? loaded;
  @override
  Duration position = Duration.zero;
  @override
  Duration get duration => const Duration(seconds: 10);
  @override
  Stream<void> get completed => events.stream;
  @override
  Future<void> load(RecordingAudio audio) async => loaded = audio;
  @override
  Future<void> play() async => plays++;
  @override
  Future<void> pause() async => pauses++;
  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<void> dispose() async {
    disposed = true;
    await events.close();
  }
}

void main() {
  test(
    'play, pause, resume and seek reuse one in-memory source, then release it',
    () async {
      final engine = _Engine();
      var loads = 0;
      final playback = RecordingPlayback(
        loader: () async {
          loads++;
          return RecordingAudio(bytes: [1, 2, 3]);
        },
        engineFactory: () => engine,
      );
      await playback.toggle();
      expect(playback.playing, true);
      expect(engine.loaded!.bytes, [1, 2, 3]);
      await playback.toggle();
      expect(playback.playing, false);
      expect(engine.pauses, 1);
      await playback.seek(const Duration(seconds: 5));
      expect(playback.position, const Duration(seconds: 5));
      await playback.toggle();
      expect(engine.plays, 2);
      expect(loads, 1);
      engine.events.add(null);
      expect(playback.playing, false);
      expect(playback.position, playback.duration);
      playback.dispose();
      expect(engine.disposed, true);
    },
  );

  test(
    'lock or disposal invalidates an in-flight loader before it reaches the engine',
    () async {
      final gate = Completer<RecordingAudio>();
      var created = 0;
      final playback = RecordingPlayback(
        loader: () => gate.future,
        engineFactory: () {
          created++;
          return _Engine();
        },
      );
      final playing = playback.toggle();
      expect(playback.loading, true);
      playback.clear();
      gate.complete(RecordingAudio(bytes: [1]));
      await playing;
      expect(created, 0);
      expect(playback.loading, false);
      expect(playback.playing, false);
      playback.dispose();
    },
  );

  test('a failed load reports an actionable error and permits retry', () async {
    final engine = _Engine();
    var attempts = 0;
    final playback = RecordingPlayback(
      loader: () async {
        if (attempts++ == 0) throw StateError('Unavailable');
        return RecordingAudio(bytes: [1]);
      },
      engineFactory: () => engine,
    );
    await playback.toggle();
    expect(playback.error, contains('recording device'));
    expect(playback.loading, false);
    await playback.toggle();
    expect(playback.playing, true);
    expect(playback.error, isNull);
    playback.dispose();
  });
}
