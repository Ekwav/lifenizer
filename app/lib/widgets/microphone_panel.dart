import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_state.dart';

class MicrophonePanel extends StatefulWidget {
  const MicrophonePanel({required this.state, super.key});
  final LifenizerAppState state;

  @override
  State<MicrophonePanel> createState() => _MicrophonePanelState();
}

class _MicrophonePanelState extends State<MicrophonePanel> {
  final _title = TextEditingController();
  final _people = TextEditingController();
  bool _working = false;
  bool _disposing = false;

  @override
  void initState() {
    super.initState();
    widget.state.recording.addListener(_recordingChanged);
  }

  void _recordingChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposing = true;
    widget.state.recording.removeListener(_recordingChanged);
    if (!widget.state.recording.supportsBackground) {
      unawaited(widget.state.recording.stop());
    }
    _title.dispose();
    _people.dispose();
    super.dispose();
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
    final recording = widget.state.recording;
    final seconds = recording.startedAt == null
        ? 0
        : DateTime.now().difference(recording.startedAt!).inSeconds;
    final disabled = _working || recording.working || widget.state.busy;
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
            Text(
              recording.supportsBackground
                  ? 'Recording continues when you leave this page or lock the screen. Stop here or from the notification, then send to Whisper. Recordings are saved encrypted on this device.'
                  : 'Record here, then send to your Whisper server to transcribe. The transcript is encrypted before sync.',
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
            if (recording.recording) ...[
              Text(
                'Recording · ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} · maximum 30 minutes',
              ),
              FilledButton.icon(
                onPressed: disabled ? null : recording.stop,
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
                onPressed: disabled ? null : recording.start,
                icon: const Icon(Icons.mic),
                label: const Text('Start microphone recording'),
              ),
            if (_working || recording.working) const LinearProgressIndicator(),
            if (recording.error != null)
              Text(
                recording.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}
