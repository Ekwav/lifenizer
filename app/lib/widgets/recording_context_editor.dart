import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'participant_picker.dart';
import 'recording_location_fields.dart';

class RecordingContextEditor extends StatefulWidget {
  const RecordingContextEditor({
    required this.state,
    required this.conversation,
    super.key,
  });
  final LifenizerAppState state;
  final Conversation conversation;
  @override
  State<RecordingContextEditor> createState() => _RecordingContextEditorState();
}

class _RecordingContextEditorState extends State<RecordingContextEditor> {
  late final _title = TextEditingController(text: widget.conversation.title);
  final _names = TextEditingController();
  late List<String> _people = List.of(widget.conversation.participantIds);
  late RecordingLocation? _location = widget.conversation.location;
  bool _saving = false;
  bool _dirty = false;
  late final String? _identity;
  String? _error;

  @override
  void initState() {
    super.initState();
    _identity = widget.state.recordingIdentity;
    widget.state.addListener(_libraryChanged);
    _names.addListener(() => _dirty = true);
  }

  void _libraryChanged() {
    if (widget.state.recordingIdentity == _identity) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).removeRoute(ModalRoute.of(context)!);
    });
  }

  Future<void> _cancel() async {
    if (_saving) return;
    final discard =
        !_dirty ||
        await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Discard changes?'),
                content: const Text(
                  'Your recording is safe. The unsaved people and location edits will be discarded.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Keep editing'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Discard changes'),
                  ),
                ],
              ),
            ) ==
            true;
    if (discard && mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    widget.state.removeListener(_libraryChanged);
    _title.dispose();
    _names.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final saved = await widget.state.updateRecordingDetails(
      widget.conversation.id,
      title: _title.text,
      participantNames: _names.text,
      participantIds: _people,
      location: _location,
      expectedIdentity: _identity,
    );
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = false;
      _error =
          widget.state.error ?? 'Could not save the recording details. Retry.';
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _cancel();
    },
    child: AlertDialog(
      title: const Text('Recording details'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _title,
                onChanged: (_) => _dirty = true,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              ParticipantPicker(
                state: widget.state,
                controller: _names,
                selectedIds: _people,
                enabled: !_saving,
                onChanged: (ids) => setState(() {
                  _people = ids;
                  _dirty = true;
                }),
              ),
              RecordingLocationFields(
                location: _location,
                enabled: !_saving,
                onChanged: (value) {
                  _location = value;
                  _dirty = true;
                },
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _cancel,
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save details'),
        ),
      ],
    ),
  );
}
