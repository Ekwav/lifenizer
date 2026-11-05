import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import '../services/wav_audio.dart';
import 'recording_audio_player.dart';

/// Records only a replacement sentence; never creates a library recording.
Future<({Uint8List audio, String text})?> recordReplacementSentence(
  BuildContext context, {
  required LifenizerAppState state,
  required String text,
}) => showDialog<({Uint8List audio, String text})>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ReplacementSentenceRecorder(state: state, text: text),
);

class _ReplacementSentenceRecorder extends StatefulWidget {
  const _ReplacementSentenceRecorder({required this.state, required this.text});
  final LifenizerAppState state;
  final String text;
  @override
  State<_ReplacementSentenceRecorder> createState() =>
      _ReplacementSentenceRecorderState();
}

class _ReplacementSentenceRecorderState
    extends State<_ReplacementSentenceRecorder>
    with WidgetsBindingObserver {
  static const _maxBytes = 16000 * 2 * 120;
  late final _text = TextEditingController(text: widget.text);
  late final String? _identity;
  final _recorder = AudioRecorder();
  final _pcm = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _stream;
  Timer? _limit;
  Future<void>? _starting;
  Future<void>? _stopping;
  Future<void>? _releasing;
  Uint8List? _audio;
  bool _recording = false;
  bool _closed = false;
  String? _error;

  bool get _conflict =>
      widget.state.recording.recording || widget.state.recording.working;
  bool get _valid =>
      !_closed &&
      mounted &&
      widget.state.isAuthenticated &&
      widget.state.recordingIdentity == _identity &&
      !_conflict;
  bool get _working => _starting != null || _stopping != null;

  @override
  void initState() {
    super.initState();
    _identity = widget.state.recordingIdentity;
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_changed);
    widget.state.recording.addListener(_changed);
  }

  void _changed() {
    if (_closed) return;
    if (!widget.state.isAuthenticated ||
        widget.state.recordingIdentity != _identity ||
        (_conflict && (_recording || _starting != null))) {
      _close();
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _close();
    }
  }

  void _clear() {
    _closed = true;
    _recording = false;
    _limit?.cancel();
    _pcm.clear();
    _audio = null;
    _text.clear();
    unawaited(_release());
  }

  void _close() {
    if (_closed) return;
    _clear();
    Navigator.of(context).pop();
  }

  Future<void> _release() => _releasing ??= _releaseRecorder();

  Future<void> _releaseRecorder() async {
    await _starting;
    await _stopping;
    try {
      await _recorder.stop();
    } catch (_) {
      // Disposal still releases a microphone whose stop failed.
    } finally {
      await _stream?.cancel();
      await _recorder.dispose();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _recording = false;
    _limit?.cancel();
    _pcm.clear();
    _audio = null;
    widget.state.removeListener(_changed);
    widget.state.recording.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    _text.dispose();
    unawaited(_release());
    super.dispose();
  }

  Future<void> _start() async {
    if (!_valid || _working || _recording) return;
    setState(() {
      _error = null;
      _audio = null;
      _pcm.clear();
      _starting = _capture();
    });
    await _starting;
    _starting = null;
    if (mounted && !_closed) setState(() {});
  }

  Future<void> _capture() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (_valid) {
          _error =
              'Enable microphone permission in device settings, then retry.';
        }
        return;
      }
      if (!_valid) return;
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.mic,
          ),
        ),
      );
      if (!_valid) {
        await _recorder.stop();
        return;
      }
      _recording = true;
      _stream = stream.listen(
        (chunk) {
          if (!_valid) return;
          final remaining = _maxBytes - _pcm.length;
          _pcm.add(
            chunk.length > remaining
                ? Uint8List.sublistView(chunk, 0, remaining)
                : chunk,
          );
          if (_pcm.length >= _maxBytes) unawaited(_stop());
        },
        onError: (Object _) {
          if (!_valid) return;
          _error = 'Microphone interrupted. Retake the sentence.';
          unawaited(_stop());
        },
        onDone: () {
          if (_recording) unawaited(_stop());
        },
      );
      _limit = Timer(const Duration(minutes: 2), () => unawaited(_stop()));
    } catch (_) {
      if (_valid) {
        _error = 'Could not record. Check microphone permission and retry.';
      }
      await _recorder.stop();
    }
  }

  Future<void> _stop() async {
    if (!_valid || !_recording || _stopping != null) return;
    setState(() {
      _recording = false;
      _limit?.cancel();
      _stopping = _finish();
    });
    await _stopping;
    _stopping = null;
    if (mounted && !_closed) setState(() {});
  }

  Future<void> _finish() async {
    try {
      await _recorder.stop();
      await _stream?.cancel();
      if (!_valid) return;
      final pcm = _pcm.takeBytes();
      final length = pcm.length - pcm.length % 2;
      if (_error == null && length > 0) {
        _audio = encodeWav(Uint8List.sublistView(pcm, 0, length));
      } else {
        _error ??= 'No audio captured. Check your microphone and retry.';
      }
    } catch (_) {
      if (_valid) _error = 'Could not finish recording. Retake the sentence.';
    } finally {
      await _stream?.cancel();
      _stream = null;
      _pcm.clear();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop && !_closed) _clear();
    },
    child: AlertDialog(
      title: const Text('Record a replacement sentence'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Write a non-private sentence containing the corrected word, then read it aloud. Audio stays in memory until you choose whether to submit it.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                minLines: 2,
                maxLines: 4,
                maxLength: 10000,
                enabled: !_recording && !_working,
                decoration: const InputDecoration(
                  labelText: 'Exact sentence to read',
                  counterText: '',
                ),
                onChanged: (_) => setState(() => _audio = null),
              ),
              const SizedBox(height: 12),
              if (_conflict)
                const Text(
                  'Finish your current recording in Capture, then retry here.',
                ),
              if (_audio case final audio?) ...[
                RecordingAudioPlayer(
                  state: widget.state,
                  loader: () async => RecordingAudio(bytes: audio),
                ),
                TextButton(
                  onPressed: () => setState(() => _audio = null),
                  child: const Text('Retake'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: _working || _conflict || _text.text.trim().isEmpty
                      ? null
                      : _recording
                      ? _stop
                      : _start,
                  icon: Icon(_recording ? Icons.stop : Icons.mic),
                  label: Text(
                    _recording ? 'Stop recording' : 'Start recording',
                  ),
                ),
              const Text('Maximum two minutes.'),
              if (_error case final error?)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _close, child: const Text('Cancel')),
        FilledButton(
          onPressed: _audio == null || _text.text.trim().isEmpty || !_valid
              ? null
              : () => Navigator.pop(context, (
                  audio: _audio!,
                  text: _text.text.trim(),
                )),
          child: const Text('Use this recording'),
        ),
      ],
    ),
  );
}
