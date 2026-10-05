import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_state.dart';
import 'recording_details_sheet.dart';

class MicrophonePanel extends StatefulWidget {
  const MicrophonePanel({required this.state, super.key});
  final LifenizerAppState state;

  @override
  State<MicrophonePanel> createState() => _MicrophonePanelState();
}

class _MicrophonePanelState extends State<MicrophonePanel> {
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
    super.dispose();
  }

  /// Opens the details sheet once per draft (right after saving, or when a
  /// draft saved in the background is first seen).
  void _maybePrompt() {
    if (!mounted || _disposing || recordingDetailsSheetOpen) return;
    final draft = widget.state.audioDraft;
    final recording = widget.state.recording;
    if (draft == null ||
        draft['detailsPrompted'] == true ||
        recording.recording ||
        recording.working ||
        _working) {
      return;
    }
    unawaited(_editDetails());
  }

  Future<void> _editDetails() async {
    if (widget.state.audioDraft == null || recordingDetailsSheetOpen) return;
    final result = await showRecordingDetailsSheet(context, widget.state);
    if (result == RecordingDetailsResult.transcribe &&
        widget.state.audioDraft != null) {
      await _transcribe();
    }
  }

  Future<void> _transcribe() async {
    final draft = widget.state.audioDraft!;
    final title = (draft['title'] as String? ?? '').trim();
    setState(() => _working = true);
    try {
      await widget.state.importAudioBytes(
        bytes: base64Decode(draft['payload'] as String),
        fileName: 'recording.wav',
        mimeType: 'audio/wav',
        title: title.isEmpty ? 'Recorded conversation' : title,
        participantNames: draftPeople(draft).join(', '),
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
    if (draft != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
    }
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
                  ? 'Recording continues when you leave this page or lock the screen. Stop here or from the notification, then send to Whisper.'
                  : 'Record here, then send to your Whisper server to transcribe. The transcript is encrypted before sync.',
            ),
            const SizedBox(height: 8),
            const RecordingStorageNote(),
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
              _DraftDetails(
                draft: draft,
                onEdit: disabled ? null : _editDetails,
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

class _DraftDetails extends StatelessWidget {
  const _DraftDetails({required this.draft, required this.onEdit});
  final Map<String, dynamic> draft;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final title = (draft['title'] as String? ?? '').trim();
    final people = draftPeople(draft);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.isEmpty ? 'Title: Recorded conversation' : 'Title: $title',
          key: const ValueKey('draft-title'),
        ),
        if (people.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              for (final name in people)
                Chip(label: Text(name), visualDensity: VisualDensity.compact),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit details'),
          ),
        ),
      ],
    );
  }
}
