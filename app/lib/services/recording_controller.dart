import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import 'wav_audio.dart';
import 'recording_location_service.dart';
import '../models.dart';

/// Owns the microphone independently of the Capture page.
class RecordingController extends ChangeNotifier with WidgetsBindingObserver {
  RecordingController(this.state) {
    // Pure vault operations can construct state without a Flutter binding.
    try {
      _binding = WidgetsBinding.instance;
    } catch (_) {
      _binding = null;
    }
    _binding?.addObserver(this);
    state.addListener(_stateChanged);
    if (_binding != null && supportsBackground) {
      _background.setMethodCallHandler((call) async {
        if (call.method == 'changed') {
          _stateChanged();
        }
      });
    }
    scheduleMicrotask(_stateChanged);
  }

  WidgetsBinding? _binding;
  String get _scope => jsonEncode([state.apiBaseUrl, state.rememberedEmail]);
  bool get _resumed => _binding?.lifecycleState == AppLifecycleState.resumed;
  Future<void>? _reconciling;

  void _stateChanged() {
    if (!_disposed && supportsBackground && _resumed && !working) {
      unawaited(_reconcile());
    }
  }

  Future<void> _reconcile() => _reconciling ??= _reconcileNative().whenComplete(
    () => _reconciling = null,
  );

  void _nativeStatus(Map<Object?, Object?>? status) {
    recording = status?['recording'] == true;
    final timestamp = status?['startedAt'] as int?;
    if (timestamp != null && timestamp > 0) {
      startedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    }
    if (status?['error'] != null) error = status!['error'] as String;
    if (recording) {
      _clock ??= Timer.periodic(const Duration(seconds: 1), (_) => _changed());
    } else {
      _clock?.cancel();
      _clock = null;
    }
  }

  Future<void> _reconcileNative() async {
    try {
      _nativeStatus(
        await _background.invokeMapMethod<Object?, Object?>('status'),
      );
      if (recording || !_canImport) return;
      final scope = _scope;
      final captures =
          await _background.invokeListMethod<Object?>('pending', {
            'scope': scope,
          }) ??
          [];
      for (final value in captures) {
        if (!_canImport || scope != _scope) break;
        try {
          final capture = value as Map<Object?, Object?>;
          final arguments = {'scope': scope, 'id': capture['id']};
          final pcm = await _background.invokeMethod<Uint8List>(
            'read',
            arguments,
          );
          if (!_canImport || scope != _scope) break;
          if (pcm == null || pcm.isEmpty) {
            error = 'No audio was captured. Check your microphone.';
            continue;
          }
          await state.importPendingRecording(
            encodeWav(pcm),
            DateTime.fromMillisecondsSinceEpoch(capture['startedAt'] as int),
            capture['id'] as String,
            location: capture['location'] is Map
                ? RecordingLocation.fromJson(
                    Map<String, dynamic>.from(capture['location'] as Map),
                  )
                : null,
          );
          await _background.invokeMethod<void>('ack', arguments);
        } catch (failure) {
          error = 'Could not recover a recording: $failure';
        }
      }
    } catch (failure) {
      error = 'Could not recover the recording: $failure';
    } finally {
      _changed();
    }
  }

  bool get _canImport =>
      !_disposed && _resumed && state.isAuthenticated && !state.busy;

  void _initialize() {
    if (_recorder != null) return;
    _recorder = AudioRecorder();
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
    if (state == AppLifecycleState.resumed) {
      _stateChanged();
    } else if (!supportsBackground &&
        (state == AppLifecycleState.detached ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused)) {
      unawaited(stop());
    }
  }

  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (recording ||
        _disposed ||
        (!supportsBackground && state.audioDraft != null)) {
      return;
    }
    if (!_resumed) {
      error = 'Start recording while Lifenizer is open.';
      _changed();
      return;
    }
    if (!supportsBackground) _initialize();
    working = true;
    error = null;
    _changed();
    try {
      if (supportsBackground) {
        await _reconciling;
        await RecordingLocationService.instance.load();
        if (state.rememberedEmail.isEmpty) {
          throw StateError('Choose a library before recording.');
        }
        if (await _background.invokeMethod<bool>('permission') != true) {
          throw StateError('Microphone permission was denied.');
        }
        if (_disposed || !_resumed) {
          throw StateError('Start recording while Lifenizer is open.');
        }
        _nativeStatus(
          await _background.invokeMapMethod<Object?, Object?>('start', {
            'scope': _scope,
            'captureLocation': RecordingLocationService.instance.enabled,
          }),
        );
        return;
      }
      if (!state.isAuthenticated) throw StateError('Unlock the vault first.');
      if (!await _recorder!.hasPermission()) {
        throw StateError(
          'Microphone permission was denied. Enable it in your device settings.',
        );
      }
      if (_disposed || !state.isAuthenticated || !_resumed) {
        throw StateError('Start recording while Lifenizer is open.');
      }
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
      await _recorder?.stop();
    } finally {
      working = false;
      _changed();
    }
  }

  Future<void> stop() =>
      _stopping ??= _finish().whenComplete(() => _stopping = null);

  Future<void> _finish() async {
    await _starting;
    if (supportsBackground) {
      working = true;
      _changed();
      try {
        _nativeStatus(
          await _background.invokeMapMethod<Object?, Object?>('stop'),
        );
        await _reconciling;
        await _reconcile();
      } catch (failure) {
        error = 'Could not stop the recording: $failure';
      } finally {
        working = false;
        _changed();
      }
      return;
    }
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
      _clock?.cancel();
      recording = false;
      working = false;
      _changed();
    }
  }

  Future<void> _release() async {
    if (!supportsBackground) await stop();
    await _stream?.cancel();
    await _recorder?.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    _binding?.removeObserver(this);
    state.removeListener(_stateChanged);
    if (_binding != null && supportsBackground) {
      _background.setMethodCallHandler(null);
    }
    _clock?.cancel();
    unawaited(_release());
    super.dispose();
  }
}
