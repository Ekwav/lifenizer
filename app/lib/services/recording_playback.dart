import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import '../app_state.dart';
import 'recording_codec.dart';

abstract class RecordingAudioEngine {
  Future<void> load(RecordingAudio audio);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> dispose();
  Duration get position;
  Duration get duration;
  Stream<void> get completed;
}

/// Decodes directly from memory; no plaintext temporary file or HTTP source.
class MemoryRecordingAudioEngine implements RecordingAudioEngine {
  final _engine = SoLoud.instance;
  AudioSource? _source;
  SoundHandle? _handle;
  bool _disposed = false;
  static int _nextId = 0;

  @override
  Future<void> load(RecordingAudio audio) async {
    if (!_engine.isInitialized) await _engine.init();
    if (_disposed) return;
    final bytes = await recordingForPlayback(audio.bytes);
    if (_disposed) return;
    final source = await _engine.loadMem(
      'recording-${_nextId++}-${audio.fileName}',
      bytes,
    );
    if (_disposed) {
      await _engine.disposeSource(source);
      return;
    }
    _source = source;
  }

  @override
  Stream<void> get completed => _source!.soundEvents
      .where(
        (e) =>
            e.event == SoundEventType.handleIsNoMoreValid &&
            e.handle == _handle,
      )
      .map((_) {});
  @override
  Duration get duration =>
      _source == null ? Duration.zero : _engine.getLength(_source!);
  @override
  Duration get position =>
      _handle == null ? Duration.zero : _engine.getPosition(_handle!);
  @override
  Future<void> play() async {
    if (_disposed || _source == null) return;
    if (_handle == null || !_engine.getIsValidVoiceHandle(_handle!)) {
      _handle = _engine.play(_source!);
    } else {
      _engine.setPause(_handle!, false);
    }
  }

  @override
  Future<void> pause() async {
    if (_handle != null) _engine.setPause(_handle!, true);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_source == null || _disposed) return;
    if (_handle == null || !_engine.getIsValidVoiceHandle(_handle!)) {
      _handle = _engine.play(_source!, paused: true);
    }
    _engine.seek(_handle!, position);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final source = _source;
    _source = null;
    _handle = null;
    if (source != null) await _engine.disposeSource(source);
  }
}

class RecordingPlayback extends ChangeNotifier {
  RecordingPlayback({
    required this.loader,
    RecordingAudioEngine Function()? engineFactory,
  }) : _engineFactory = engineFactory ?? MemoryRecordingAudioEngine.new;
  final Future<RecordingAudio> Function() loader;
  final RecordingAudioEngine Function() _engineFactory;
  RecordingAudioEngine? _engine;
  StreamSubscription<void>? _completed;
  Timer? _progress;
  int _generation = 0;
  bool loading = false;
  bool playing = false;
  String? error;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  Future<void> toggle() async {
    if (loading) return;
    loading = true;
    notifyListeners();
    final generation = _generation;
    error = null;
    try {
      if (_engine == null) {
        final audio = await loader();
        if (generation != _generation) return;
        final engine = _engineFactory();
        _engine = engine;
        await engine.load(audio);
        if (generation != _generation) return;
        duration = engine.duration;
        _completed = engine.completed.listen((_) {
          playing = false;
          position = duration;
          _progress?.cancel();
          notifyListeners();
        });
      }
      if (playing) {
        await _engine!.pause();
      } else {
        await _engine!.play();
      }
      if (generation != _generation) return;
      playing = !playing;
      _progress?.cancel();
      if (playing) {
        // Refresh the visible playhead only while audio is playing.
        _progress = Timer.periodic(const Duration(milliseconds: 250), (_) {
          position = _engine!.position;
          notifyListeners();
        });
      }
    } catch (_) {
      if (generation != _generation) return;
      clear();
      error =
          'Could not play this recording. Keep the recording device running, enable online sync there, or use a WAV, MP3, Ogg or FLAC recording.';
      notifyListeners();
    } finally {
      if (generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> seek(Duration value) async {
    if (_engine == null || loading) return;
    try {
      await _engine!.seek(value);
      position = value;
      notifyListeners();
    } catch (_) {
      error = 'Could not seek in this recording.';
      notifyListeners();
    }
  }

  /// Invalidates pending loads and releases decoded audio at lock or disposal.
  void clear({bool notify = true}) {
    _generation++;
    _progress?.cancel();
    _progress = null;
    unawaited(_completed?.cancel());
    _completed = null;
    final engine = _engine;
    _engine = null;
    if (engine != null) unawaited(engine.dispose().catchError((Object _) {}));
    loading = false;
    playing = false;
    position = duration = Duration.zero;
    error = null;
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    clear(notify: false);
    super.dispose();
  }
}
