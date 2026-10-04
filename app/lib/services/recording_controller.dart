import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import 'wav_audio.dart';

/// Owns the microphone independently of the Capture page.
class RecordingController extends ChangeNotifier with WidgetsBindingObserver {
  RecordingController(this.state);

  void _initialize() {
    if (_recorder != null) return;
    _recorder = AudioRecorder();
    WidgetsBinding.instance.addObserver(this);
    if (supportsBackground) {
      _background.setMethodCallHandler((call) async {
        if (call.method == 'stop') await stop();
      });
    }
  }

  final LifenizerAppState state;
  AudioRecorder? _recorder;
  final _pcm = BytesBuilder(copy: false);
  static const _background = MethodChannel('com.lifenizer/recording');
  StreamSubscription<Uint8List>? _stream;
  Timer? _clock;
  Future<void>? _starting;
  Future<void>? _stopping;
  bool _disposed = false;
  bool recording = false;
  bool working = false;
  DateTime? startedAt;
  String? error;

  bool get supportsBackground =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached ||
        (!supportsBackground &&
            (state == AppLifecycleState.hidden ||
                state == AppLifecycleState.paused))) {
      unawaited(stop());
    }
  }

  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (recording || _disposed || state.audioDraft != null) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      error = 'Start recording while Lifenizer is open.';
      _changed();
      return;
    }
    _initialize();
    working = true;
    error = null;
    _changed();
    try {
      if (!state.isAuthenticated) throw StateError('Unlock the vault first.');
      if (!await _recorder!.hasPermission()) {
        throw StateError(
          'Microphone permission was denied. Enable it in your device settings.',
        );
      }
      if (supportsBackground) {
        await _background.invokeMethod<void>('notificationPermission');
      }
      if (_disposed ||
          !state.isAuthenticated ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        throw StateError('Start recording while Lifenizer is open.');
      }
      if (supportsBackground) await _background.invokeMethod<void>('start');
      _pcm.clear();
      final stream = await _recorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.mic,
          ),
        ),
      );
      startedAt = DateTime.now();
      recording = true;
      _stream = stream.listen(
        (chunk) {
          _pcm.add(chunk);
          if (_pcm.length >= 16000 * 2 * 60 * 30) unawaited(stop());
        },
        onError: (Object failure) {
          error = 'Microphone interrupted: $failure';
          unawaited(stop());
        },
        onDone: () {
          if (recording) unawaited(stop());
        },
      );
      _clock = Timer.periodic(const Duration(seconds: 1), (_) => _changed());
    } catch (failure) {
      error = failure.toString();
      try {
        await _recorder!.stop();
      } finally {
        await _stopBackground();
      }
    } finally {
      working = false;
      _changed();
    }
  }

  Future<void> stop() =>
      _stopping ??= _finish().whenComplete(() => _stopping = null);

  Future<void> _finish() async {
    await _starting;
    if (!recording) return;
    working = true;
    _changed();
    try {
      await _recorder!.stop();
      await _stream?.cancel();
      if (_pcm.length == 0) {
        throw StateError('No audio was captured. Check your microphone.');
      }
      await state.saveAudioDraft(encodeWav(_pcm.toBytes()), startedAt!);
      _pcm.clear();
    } catch (failure) {
      error = failure.toString();
      state.reportError('Could not save the recording: $failure');
    } finally {
      await _stream?.cancel();
      await _stopBackground();
      _clock?.cancel();
      recording = false;
      working = false;
      _changed();
    }
  }

  Future<void> _stopBackground() async {
    if (!supportsBackground) return;
    try {
      await _background.invokeMethod<void>('stop');
    } catch (failure) {
      error = 'Could not close the recording notification: $failure';
    }
  }

  Future<void> _release() async {
    await stop();
    await _stream?.cancel();
    await _recorder?.dispose();
    if (_recorder != null && supportsBackground) {
      _background.setMethodCallHandler(null);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_recorder != null) WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    unawaited(_release());
    super.dispose();
  }
}
