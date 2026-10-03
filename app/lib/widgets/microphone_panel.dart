import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import '../services/wav_audio.dart';

class MicrophonePanel extends StatefulWidget {
  const MicrophonePanel({required this.state, super.key});
  final LifenizerAppState state;

  @override
  State<MicrophonePanel> createState() => _MicrophonePanelState();
}

class _MicrophonePanelState extends State<MicrophonePanel>
    with WidgetsBindingObserver {
  final _recorder = AudioRecorder();
  final _title = TextEditingController();
  final _people = TextEditingController();
  final _pcm = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _stream;
  Timer? _clock;
  DateTime? _startedAt;
  bool _recording = false;
  bool _working = false;
  bool _disposing = false;
  Future<void>? _starting;
  Future<void>? _stopping;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.stopRecording = _finish;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_finish());
    }
  }

  Future<void> _finish() async {
    await _starting;
    await _stop();
  }

  Future<void> _finishAndDispose() async {
    await _finish();
    await _stream?.cancel();
    await _recorder.dispose();
    if (widget.state.stopRecording == _finish) {
      widget.state.stopRecording = null;
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _clock?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_finishAndDispose());
    _title.dispose();
    _people.dispose();
    super.dispose();
  }

  Future<void> _start() =>
      _starting ??= _startImpl().whenComplete(() => _starting = null);

  Future<void> _startImpl() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError(
          'Microphone permission was denied. Enable it in your device settings.',
        );
      }
      _pcm.clear();
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      if (!mounted || _disposing) {
        await _recorder.stop();
        return;
      }
      _startedAt = DateTime.now();
      _recording = true;
      _stream = stream.listen(
        (chunk) {
          _pcm.add(chunk);
          if (_pcm.length >= 16000 * 2 * 60 * 30 && !_working) _stop();
        },
        onError: (Object error) {
          if (mounted && !_disposing) {
            _error = 'Microphone interrupted: $error';
            _stop();
          }
        },
        onDone: () {
          if (_recording && !_working) unawaited(_stop());
        },
      );
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && !_disposing) setState(() {});
      });
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted && !_disposing) setState(() => _working = false);
    }
  }

  Future<void> _stop() =>
      _stopping ??= _stopImpl().whenComplete(() => _stopping = null);

  Future<void> _stopImpl() async {
    if (!_recording) return;
    _working = true;
    if (mounted && !_disposing) setState(() {});
    try {
      await _recorder.stop();
      await _stream?.cancel();
      _clock?.cancel();
      if (_pcm.length == 0) {
        throw StateError('No audio was captured. Check your microphone.');
      }
      await widget.state.saveAudioDraft(
        encodeWav(_pcm.takeBytes()),
        _startedAt!,
      );
    } catch (error) {
      _error = error.toString();
      widget.state.reportError('Could not save the recording: $error');
    } finally {
      _recording = false;
      _working = false;
      if (mounted && !_disposing) setState(() {});
    }
  }

  Future<void> _transcribe() async {
    final draft = widget.state.audioDraft!;
    setState(() => _working = true);
    try {
      await widget.state.importAudioBytes(
        bytes: base64Decode(draft['payload'] as String),
        fileName: 'recording.wav',
        mimeType: 'audio/wav',
        title: _title.text.isEmpty ? 'Recorded conversation' : _title.text,
        participantNames: _people.text,
        recordedAt: DateTime.parse(draft['recordedAt'] as String),
      );
      if (widget.state.error == null) await widget.state.discardAudioDraft();
    } finally {
      if (mounted && !_disposing) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.state.audioDraft;
    final seconds = _startedAt == null
        ? 0
        : DateTime.now().difference(_startedAt!).inSeconds;
    final disabled = _working || widget.state.busy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Record a conversation',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Record here, then send to your Whisper server to transcribe. The transcript is encrypted before sync.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title (optional)'),
            ),
            TextField(
              controller: _people,
              decoration: const InputDecoration(
                labelText: 'People (optional, comma separated)',
              ),
            ),
            const SizedBox(height: 12),
            if (_recording) ...[
              Text(
                'Recording · ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} · maximum 30 minutes',
              ),
              FilledButton.icon(
                onPressed: disabled ? null : _stop,
                icon: const Icon(Icons.stop),
                label: const Text('Stop and save recording'),
              ),
            ] else if (draft != null) ...[
              const Text(
                'Recording saved encrypted on this device. Ready to transcribe.',
              ),
              FilledButton.icon(
                onPressed: disabled ? null : _transcribe,
                icon: const Icon(Icons.transcribe),
                label: const Text('Send to Whisper and transcribe'),
              ),
              TextButton(
                onPressed: disabled ? null : widget.state.discardAudioDraft,
                child: const Text('Discard recording'),
              ),
            ] else
              FilledButton.icon(
                onPressed: disabled ? null : _start,
                icon: const Icon(Icons.mic),
                label: const Text('Start microphone recording'),
              ),
            if (_working) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}
