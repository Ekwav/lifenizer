import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/export_file_reader.dart';
import '../widgets/microphone_panel.dart';
import '../widgets/participant_picker.dart';
import 'page_frame.dart';

class CapturePage extends StatefulWidget {
  const CapturePage({required this.state, this.draft, super.key});

  final LifenizerAppState state;
  final CaptureDraft? draft;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class CaptureDraft {
  final TextEditingController titleController = TextEditingController();
  final TextEditingController participantsController = TextEditingController();
  final TextEditingController textController = TextEditingController();
  final TextEditingController recordingTitleController = TextEditingController(
    text: 'Live session',
  );
  final TextEditingController recordingParticipantsController =
      TextEditingController();
  final TextEditingController segmentController = TextEditingController();
  final List<String> segments = [];
  List<String> participantIds = [];
  List<String> recordingParticipantIds = [];
  bool recording = false;

  void dispose() {
    titleController.dispose();
    participantsController.dispose();
    textController.dispose();
    recordingTitleController.dispose();
    recordingParticipantsController.dispose();
    segmentController.dispose();
  }
}

class _CapturePageState extends State<CapturePage> {
  late final CaptureDraft draft = widget.draft ?? CaptureDraft();

  @override
  void dispose() {
    if (widget.draft == null) draft.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final identity = widget.state.recordingIdentity;
    if (identity == null) return;
    try {
      final result = await FilePicker.pickFiles(
        withData: false,
        withReadStream: true,
      );
      final file = result?.files.single;
      if (file == null ||
          !mounted ||
          widget.state.recordingIdentity != identity)
        return;
      final bytes = await readExportBytes(file);
      if (!mounted || widget.state.recordingIdentity != identity) return;
      if (widget.state.busy) {
        widget.state.reportError(
          'Wait for the current operation, then select the file again.',
        );
        return;
      }
      await widget.state.importSharedPayload(
        fileName: file.name,
        bytes: bytes,
        mimeType: file.extension?.toLowerCase() == 'pdf'
            ? 'application/pdf'
            : null,
      );
    } catch (failure) {
      if (mounted && widget.state.recordingIdentity == identity) {
        widget.state.reportError('Could not import the file: $failure');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'Capture',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumns = constraints.maxWidth >= 900;
          final children = [
            MicrophonePanel(state: widget.state),
            _ManualTextPanel(
              enabled: !widget.state.busy,
              titleController: draft.titleController,
              participantsField: ParticipantPicker(
                state: widget.state,
                controller: draft.participantsController,
                selectedIds: draft.participantIds,
                onChanged: (ids) => setState(() => draft.participantIds = ids),
                enabled: !widget.state.busy,
                decoration: const InputDecoration(
                  labelText: 'Participants',
                  border: OutlineInputBorder(),
                ),
              ),
              textController: draft.textController,
              onSubmit: widget.state.busy
                  ? null
                  : () async {
                      if (draft.textController.text.trim().isEmpty) {
                        widget.state.reportError('Enter some text to save.');
                        return;
                      }
                      final session = widget.state.session;
                      await widget.state.addManualText(
                        title: draft.titleController.text,
                        participantNames: draft.participantsController.text,
                        participantIds: draft.participantIds,
                        text: draft.textController.text,
                      );
                      if (identical(session, widget.state.session) &&
                          widget.state.error == null) {
                        draft.titleController.clear();
                        draft.participantsController.clear();
                        draft.textController.clear();
                        draft.participantIds = [];
                        if (mounted) setState(() {});
                      }
                    },
            ),
            _RecordingPanel(
              enabled: !widget.state.busy,
              recording: draft.recording,
              titleController: draft.recordingTitleController,
              participantsField: ParticipantPicker(
                state: widget.state,
                controller: draft.recordingParticipantsController,
                selectedIds: draft.recordingParticipantIds,
                onChanged: (ids) =>
                    setState(() => draft.recordingParticipantIds = ids),
                enabled: !widget.state.busy,
                decoration: const InputDecoration(
                  labelText: 'Participants',
                  border: OutlineInputBorder(),
                ),
              ),
              segmentController: draft.segmentController,
              segments: draft.segments,
              onStart: () => setState(() {
                draft.segments.clear();
                draft.recording = true;
              }),
              onAddSegment: () => setState(() {
                if (draft.segmentController.text.trim().isNotEmpty) {
                  draft.segments.add(draft.segmentController.text.trim());
                  draft.segmentController.clear();
                }
              }),
              onStop: widget.state.busy
                  ? null
                  : () async {
                      final segments = [
                        ...draft.segments,
                        if (draft.segmentController.text.trim().isNotEmpty)
                          draft.segmentController.text.trim(),
                      ];
                      if (segments.isEmpty) {
                        widget.state.reportError(
                          'Add a note before saving the session.',
                        );
                        return;
                      }
                      final session = widget.state.session;
                      await widget.state.addRecordingConversation(
                        title: draft.recordingTitleController.text,
                        participantNames:
                            draft.recordingParticipantsController.text,
                        participantIds: draft.recordingParticipantIds,
                        segmentTexts: segments,
                      );
                      if (identical(session, widget.state.session) &&
                          widget.state.error == null) {
                        draft.recording = false;
                        draft.segments.clear();
                        draft.segmentController.clear();
                        draft.recordingTitleController.text = 'Live session';
                        draft.recordingParticipantsController.clear();
                        draft.recordingParticipantIds = [];
                        if (mounted) setState(() {});
                      }
                    },
            ),
            _FilePanel(onPick: widget.state.busy ? null : _pickFile),
          ];
          if (twoColumns) {
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: children
                  .map(
                    (child) => SizedBox(
                      width: (constraints.maxWidth - 16) / 2,
                      child: child,
                    ),
                  )
                  .toList(),
            );
          }
          return Column(
            children: children
                .expand((child) => [child, const SizedBox(height: 16)])
                .toList(),
          );
        },
      ),
    );
  }
}

class _ManualTextPanel extends StatelessWidget {
  const _ManualTextPanel({
    required this.enabled,
    required this.titleController,
    required this.participantsField,
    required this.textController,
    required this.onSubmit,
  });

  final bool enabled;
  final TextEditingController titleController;
  final Widget participantsField;
  final TextEditingController textController;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Manual text', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              enabled: enabled,
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            participantsField,
            const SizedBox(height: 8),
            TextField(
              enabled: enabled,
              controller: textController,
              minLines: 5,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Text',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onSubmit,
              icon: const Icon(Icons.lock),
              label: const Text('Encrypt import'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Typed notes captured as individual conversation segments.
class _RecordingPanel extends StatelessWidget {
  const _RecordingPanel({
    required this.recording,
    required this.enabled,
    required this.titleController,
    required this.participantsField,
    required this.segmentController,
    required this.segments,
    required this.onStart,
    required this.onAddSegment,
    required this.onStop,
  });

  final bool recording;
  final bool enabled;
  final TextEditingController titleController;
  final Widget participantsField;
  final TextEditingController segmentController;
  final List<String> segments;
  final VoidCallback onStart;
  final VoidCallback onAddSegment;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Typed session notes',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Type notes as a conversation happens, or use the microphone '
              'panel above to record audio.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              enabled: enabled,
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Session title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            participantsField,
            const SizedBox(height: 8),
            if (recording) ...[
              TextField(
                enabled: enabled,
                controller: segmentController,
                decoration: const InputDecoration(
                  labelText: 'Typed segment',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: enabled ? onAddSegment : null,
                icon: const Icon(Icons.playlist_add_outlined),
                label: const Text('Add segment'),
              ),
              const SizedBox(height: 8),
              Text('${segments.length} segment(s)'),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop session'),
              ),
            ] else
              FilledButton.icon(
                onPressed: enabled ? onStart : null,
                icon: const Icon(Icons.edit_note_outlined),
                label: const Text('Start session'),
              ),
          ],
        ),
      ),
    );
  }
}

class _FilePanel extends StatelessWidget {
  const _FilePanel({required this.onPick});

  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'File or audio',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.upload_file),
              label: const Text('Choose file'),
            ),
          ],
        ),
      ),
    );
  }
}
