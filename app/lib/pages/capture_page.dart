import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'page_frame.dart';

class CapturePage extends StatefulWidget {
  const CapturePage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  final TextEditingController _titleController = TextEditingController(
    text: 'Coffee with Person X',
  );
  final TextEditingController _participantsController = TextEditingController(
    text: 'Person X, Person Y',
  );
  final TextEditingController _textController = TextEditingController(
    text: "Person X is Person Y's brother and Person X works with Person Z.",
  );
  final TextEditingController _recordingTitleController = TextEditingController(
    text: 'Live session',
  );
  final TextEditingController _recordingParticipantsController =
      TextEditingController(text: 'Person X, Person Y');
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
            _ManualTextPanel(
              titleController: _titleController,
              participantsController: _participantsController,
              textController: _textController,
              onSubmit: () => widget.state.addManualText(
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
              onStop: () async {
                await widget.state.addRecordingConversation(
                  title: _recordingTitleController.text,
                  participantNames: _recordingParticipantsController.text,
                  segmentTexts: _segments,
                );
                setState(() => _recording = false);
              },
            ),
            _FilePanel(
              participantsController: _participantsController,
              onPick: () async {
                final result = await FilePicker.pickFiles(withData: true);
                final file = result?.files.single;
                if (file != null) {
                  await widget.state.addFileArtifact(
                    participantNames: _participantsController.text,
                    file: file,
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
  final VoidCallback onSubmit;

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

/// Panel for a manually-typed live session log.
///
/// This is NOT audio recording: no microphone is used. While a session is
/// "started", the user types out lines as they happen (e.g. taking notes
/// during a live conversation) and each typed line becomes one segment.
/// Labelled explicitly as typed notes so it doesn't read as if it captures
/// audio — actual audio capture is imported separately via a file (see
/// ImportsPage's "Import audio recording" action), which is transcribed
/// server-side.
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
  final VoidCallback onStop;

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
              'Type lines live as a conversation happens. This does not use '
              'the microphone — for an actual audio recording, use "Import '
              'audio recording" on the Imports page instead.',
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
  const _FilePanel({
    required this.participantsController,
    required this.onPick,
  });

  final TextEditingController participantsController;
  final VoidCallback onPick;

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
            TextField(
              controller: participantsController,
              decoration: const InputDecoration(
                labelText: 'Participants',
                border: OutlineInputBorder(),
              ),
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
