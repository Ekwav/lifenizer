import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import 'recording_details_sheet.dart';
import 'recording_audio_player.dart';
import 'transcription_progress.dart';
import '../models.dart';
import '../services/audio_format.dart';
import '../services/recording_location_service.dart';

class MicrophonePanel extends StatefulWidget {
  const MicrophonePanel({required this.state, super.key});
  final LifenizerAppState state;

  @override
  State<MicrophonePanel> createState() => _MicrophonePanelState();
}

class _MicrophonePanelState extends State<MicrophonePanel> {
  bool _working = false;
  bool _disposing = false;
  String? _locationError;

  @override
  void initState() {
    super.initState();
    widget.state.recording.addListener(_recordingChanged);
    unawaited(RecordingLocationService.instance.load());
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

  Future<RecordingAudio> _loadDraftRecording() async {
    final bytes = await widget.state.loadAudioDraftPayload();
    if (bytes == null) throw StateError('Recording unavailable.');
    return RecordingAudio(bytes: bytes);
  }

  Future<void> _discard() async {
    final identity = widget.state.recordingIdentity;
    final draft = widget.state.audioDraft;
    if (draft == null || !await confirmRecordingDiscard(context)) return;
    if (!mounted ||
        widget.state.recordingIdentity != identity ||
        !identical(widget.state.audioDraft, draft)) {
      return;
    }
    try {
      await widget.state.discardAudioDraft();
    } catch (_) {
      if (mounted) {
        widget.state.reportError('Could not discard the recording. Try again.');
      }
    }
  }

  Future<void> _transcribe() async {
    final draft = widget.state.audioDraft!;
    final title = (draft['title'] as String? ?? '').trim();
    setState(() => _working = true);
    try {
      final bytes = await widget.state.loadAudioDraftPayload();
      if (bytes == null) {
        widget.state.reportError(
          'The saved recording could not be read. Record it again.',
        );
        return;
      }
      final format = RecordingFormat.detect(bytes) ?? RecordingFormat.wav;
      final imported = await widget.state.importAudioBytes(
        bytes: bytes,
        fileName: format.fileName,
        mimeType: format.contentType,
        title: title.isEmpty ? 'Recorded conversation' : title,
        participantNames: draftPeople(draft).join(', '),
        participantIds: (draft['participantIds'] as List? ?? const [])
            .cast<String>(),
        location: draft['location'] is Map
            ? RecordingLocation.fromJson(
                Map<String, dynamic>.from(draft['location'] as Map),
              )
            : null,
        recordedAt: DateTime.parse(draft['recordedAt'] as String),
      );
      // A cancelled or failed transcription keeps the draft for a retry.
      if (imported) await widget.state.discardAudioDraft();
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
                  ? 'Recording continues when you leave this page or lock the screen. Stopped recordings are saved encrypted in your library after unlock. Open a recording to send it to Whisper for transcription.'
                  : 'Record here, then send to your Whisper server to transcribe. The transcript is encrypted before sync.',
            ),
            const SizedBox(height: 8),
            const RecordingStorageNote(),
            if (RecordingLocationService.instance.supported)
              AnimatedBuilder(
                animation: RecordingLocationService.instance,
                builder: (context, _) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include recording location'),
                  subtitle: Text(
                    _locationError ??
                        'Save one location snapshot when recording starts. Town and venue can be edited later.',
                  ),
                  value: RecordingLocationService.instance.enabled,
                  onChanged: disabled || recording.recording
                      ? null
                      : (value) async {
                          final locations = RecordingLocationService.instance;
                          if (value && !await locations.requestPermission()) {
                            if (mounted) {
                              setState(
                                () => _locationError =
                                    'Location access was not granted. You can still enter a town and venue manually.',
                              );
                            }
                            return;
                          }
                          try {
                            await locations.setEnabled(value);
                          } catch (_) {
                            if (mounted) {
                              setState(
                                () => _locationError =
                                    'Could not save the location preference. Try again.',
                              );
                            }
                            return;
                          }
                          if (mounted) setState(() => _locationError = null);
                        },
                ),
              ),
            const SizedBox(height: 12),
            if (recording.recording) ...[
              Text(
                'Recording · ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} · maximum 30 minutes',
              ),
              FilledButton.icon(
                onPressed: _working || recording.working
                    ? null
                    : recording.stop,
                icon: const Icon(Icons.stop),
                label: const Text('Stop and save recording'),
              ),
            ] else if (draft != null) ...[
              const Text(
                'Recording saved encrypted on this device. Ready to transcribe.',
              ),
              _DraftDetails(
                state: widget.state,
                draft: draft,
                onEdit: disabled ? null : _editDetails,
              ),
              RecordingAudioPlayer(
                key: ValueKey(draft['recordedAt']),
                state: widget.state,
                loader: _loadDraftRecording,
              ),
              OutlinedButton.icon(
                onPressed: disabled ? null : widget.state.retainAudioDraft,
                icon: const Icon(Icons.library_music_outlined),
                label: const Text('Save recording to library'),
              ),
              FilledButton.icon(
                onPressed: disabled ? null : _transcribe,
                icon: const Icon(Icons.transcribe),
                label: const Text('Send to Whisper and transcribe'),
              ),
              TextButton(
                onPressed: disabled ? null : _discard,
                child: const Text('Discard recording'),
              ),
            ] else
              FilledButton.icon(
                onPressed: disabled ? null : recording.start,
                icon: const Icon(Icons.mic),
                label: const Text('Start microphone recording'),
              ),
            if (_working)
              TranscriptionProgress(state: widget.state)
            else if (recording.working)
              const LinearProgressIndicator(),
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
  const _DraftDetails({
    required this.state,
    required this.draft,
    required this.onEdit,
  });
  final LifenizerAppState state;
  final Map<String, dynamic> draft;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final title = (draft['title'] as String? ?? '').trim();
    final people = [
      ...(draft['participantIds'] as List? ?? const []).cast<String>().map(
        state.participantName,
      ),
      ...draftPeople(draft),
    ];
    final location = draft['location'] is Map
        ? RecordingLocation.fromJson(
            Map<String, dynamic>.from(draft['location'] as Map),
          )
        : null;
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
        if (location?.displayName.isNotEmpty == true)
          Text(location!.displayName),
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
