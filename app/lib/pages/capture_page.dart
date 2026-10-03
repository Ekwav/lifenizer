import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../widgets/microphone_panel.dart';
import 'page_frame.dart';

class CapturePage extends StatefulWidget {
  const CapturePage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _participantsController = TextEditingController();
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _recordingTitleController = TextEditingController(
    text: 'Live session',
  );
  final TextEditingController _recordingParticipantsController =
      TextEditingController();
  final TextEditingController _segmentController = TextEditingController();
  final List<String> _segments = [];
  bool _recording = false;

  @override
  void dispose() {
    _titleController.dispose();
    _participantsController.dispose();
    _textController.dispose();
    _recordingTitleController.dispose();
    _recordingParticipantsController.dispose();
    _segmentController.dispose();
    super.dispose();
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
              titleController: _titleController,
              participantsController: _participantsController,
              textController: _textController,
              onSubmit: widget.state.busy
                  ? null
                  : () => widget.state.addManualText(
                      title: _titleController.text,
                      participantNames: _participantsController.text,
                      text: _textController.text,
                    ),
            ),
            _RecordingPanel(
              recording: _recording,
              titleController: _recordingTitleController,
              participantsController: _recordingParticipantsController,
              segmentController: _segmentController,
              segments: _segments,
              onStart: () => setState(() {
                _segments.clear();
                _recording = true;
              }),
              onAddSegment: () => setState(() {
                if (_segmentController.text.trim().isNotEmpty) {
                  _segments.add(_segmentController.text.trim());
                  _segmentController.clear();
                }
              }),
              onStop: widget.state.busy
                  ? null
                  : () async {
                      await widget.state.addRecordingConversation(
                        title: _recordingTitleController.text,
                        participantNames: _recordingParticipantsController.text,
                        segmentTexts: _segments,
                      );
                      if (mounted && widget.state.error == null) {
                        setState(() => _recording = false);
                      }
                    },
            ),
            _FilePanel(
              onPick: widget.state.busy
                  ? null
                  : () async {
                      final result = await FilePicker.pickFiles(withData: true);
                      final file = result?.files.single;
                      if (file != null) {
                        await widget.state.importSharedPayload(
                          fileName: file.name,
                          bytes: file.bytes,
                          mimeType: file.extension == 'pdf'
                              ? 'application/pdf'
                              : null,
                        );
                      }
                    },
            ),
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
    required this.titleController,
    required this.participantsController,
    required this.textController,
    required this.onSubmit,
  });

  final TextEditingController titleController;
  final TextEditingController participantsController;
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
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: participantsController,
              decoration: const InputDecoration(
                labelText: 'Participants',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
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
    required this.titleController,
    required this.participantsController,
    required this.segmentController,
    required this.segments,
    required this.onStart,
    required this.onAddSegment,
    required this.onStop,
  });

  final bool recording;
  final TextEditingController titleController;
  final TextEditingController participantsController;
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
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Session title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: participantsController,
              decoration: const InputDecoration(
                labelText: 'Participants',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            if (recording) ...[
              TextField(
                controller: segmentController,
                decoration: const InputDecoration(
                  labelText: 'Typed segment',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onAddSegment,
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
                onPressed: onStart,
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
