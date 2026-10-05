import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/recording_suggestions.dart';
import '../services/storage_location.dart';

enum RecordingDetailsResult { transcribe, saved, discarded }

/// Where the recording is stored, shown permanently in the panel and in the sheet.
class RecordingStorageNote extends StatelessWidget {
  const RecordingStorageNote({this.showExplanation = false, super.key});
  final bool showExplanation;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: '$recordingStorageHeadline. $recordingStorageExplanation',
          triggerMode: TooltipTriggerMode.tap,
          showDuration: const Duration(seconds: 8),
          child: const Padding(
            padding: EdgeInsets.only(right: 8, top: 2),
            child: Icon(Icons.info_outline, size: 18),
          ),
        ),
        Expanded(
          child: FutureBuilder<String>(
            future: describeRecordingStorage(),
            builder: (context, snapshot) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(recordingStorageHeadline, style: style),
                Text(
                  snapshot.hasData
                      ? 'Location: ${snapshot.data}'
                      : 'Location: …',
                  key: const ValueKey('recording-storage-location'),
                  style: style,
                ),
                if (showExplanation)
                  Text(recordingStorageExplanation, style: style),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String recordingLengthLabel(Map<String, dynamic> draft) {
  final bytes = (base64.normalize(draft['payload'] as String).length * 3) ~/ 4;
  final seconds = ((bytes - 44) / 32000).round().clamp(0, 1 << 30);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String recordingTimeLabel(DateTime recordedAt) {
  final local = recordedAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

List<String> draftPeople(Map<String, dynamic> draft) =>
    ((draft['participantNames'] as List?) ?? const [])
        .map((name) => name.toString())
        .toList();

bool _recordingSheetOpen = false;

/// Whether a details sheet is currently showing (guards automatic prompts).
bool get recordingDetailsSheetOpen => _recordingSheetOpen;

/// Shows the details sheet for the pending draft and persists what was entered
/// however it is closed. Returns what the user chose.
Future<RecordingDetailsResult> showRecordingDetailsSheet(
  BuildContext context,
  LifenizerAppState state,
) async {
  final draft = state.audioDraft;
  if (draft == null || _recordingSheetOpen) {
    return RecordingDetailsResult.saved;
  }
  _recordingSheetOpen = true;
  final model = _DetailsModel(
    title: (draft['title'] as String?) ?? '',
    people: draftPeople(draft),
  );
  try {
    final result = await showModalBottomSheet<RecordingDetailsResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => _RecordingDetailsSheet(state: state, model: model),
    );
    if (result == RecordingDetailsResult.discarded) {
      await state.discardAudioDraft();
      return RecordingDetailsResult.discarded;
    }
    if (state.audioDraft != null) {
      await state.updateAudioDraftDetails(
        title: model.title.text.trim(),
        participantNames: model.finalPeople(),
        detailsPrompted: true,
      );
    }
    return result ?? RecordingDetailsResult.saved;
  } finally {
    _recordingSheetOpen = false;
    model.dispose();
  }
}

class _DetailsModel {
  _DetailsModel({required String title, required this.people})
    : title = TextEditingController(text: title);
  final TextEditingController title;
  final List<String> people;
  final ValueNotifier<int> changes = ValueNotifier(0);
  final TextEditingController personField = TextEditingController();

  bool addPerson(String raw) {
    final name = raw.replaceAll(',', ' ').trim();
    if (name.isEmpty) return false;
    final key = RecordingSuggestionService.fold(name);
    if (people.any((p) => RecordingSuggestionService.fold(p) == key)) {
      return false;
    }
    people.add(name);
    changes.value++;
    return true;
  }

  void removePerson(String name) {
    people.remove(name);
    changes.value++;
  }

  /// Includes text typed into the people field but never confirmed.
  List<String> finalPeople() {
    final pending = personField.text;
    if (pending.trim().isNotEmpty) addPerson(pending);
    return List.of(people);
  }

  void dispose() {
    title.dispose();
    personField.dispose();
    changes.dispose();
  }
}

class _PersonOption {
  _PersonOption(this.name, {this.participant});
  final String name;
  final Participant? participant;
  bool get isNew => participant == null;
}

class _RecordingDetailsSheet extends StatefulWidget {
  const _RecordingDetailsSheet({required this.state, required this.model});
  final LifenizerAppState state;
  final _DetailsModel model;

  @override
  State<_RecordingDetailsSheet> createState() => _RecordingDetailsSheetState();
}

class _RecordingDetailsSheetState extends State<_RecordingDetailsSheet> {
  static const _suggestions = RecordingSuggestionService();
  final _titleFocus = FocusNode();
  final _personFocus = FocusNode();
  late final DateTime _recordedAt;
  late final List<PersonSuggestion> _peopleSuggestions;
  late final List<String> _titleSuggestions;

  @override
  void initState() {
    super.initState();
    final draft = widget.state.audioDraft!;
    _recordedAt = DateTime.parse(draft['recordedAt'] as String);
    _peopleSuggestions = _suggestions.suggestPeople(
      conversations: widget.state.conversations,
      participantById: widget.state.participantById,
      recordedAt: _recordedAt,
    );
    _titleSuggestions = _suggestions.suggestTitles(
      conversations: widget.state.conversations,
      recordedAt: _recordedAt,
    );
  }

  @override
  void dispose() {
    _titleFocus.dispose();
    _personFocus.dispose();
    super.dispose();
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard recording?'),
        content: const Text(
          'The saved audio will be deleted from this device and cannot be recovered.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      Navigator.pop(context, RecordingDetailsResult.discarded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final draft = widget.state.audioDraft;
    final theme = Theme.of(context);
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + inset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Recording saved', style: theme.textTheme.titleLarge),
          if (draft != null)
            Text(
              '${recordingLengthLabel(draft)} · ${recordingTimeLabel(_recordedAt)}',
              style: theme.textTheme.bodyMedium,
            ),
          const SizedBox(height: 8),
          const RecordingStorageNote(showExplanation: true),
          const SizedBox(height: 16),
          Text('Title', style: theme.textTheme.titleSmall),
          if (_titleSuggestions.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                for (final title in _titleSuggestions)
                  ActionChip(
                    label: Text(title),
                    onPressed: () => model.title.text = title,
                  ),
              ],
            ),
          _titleField(model),
          const SizedBox(height: 16),
          Text('People', style: theme.textTheme.titleSmall),
          ValueListenableBuilder<int>(
            valueListenable: model.changes,
            builder: (context, _, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (model.people.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final name in model.people)
                        InputChip(
                          label: Text(name),
                          onDeleted: () => model.removePerson(name),
                        ),
                    ],
                  ),
                Builder(
                  builder: (context) {
                    final chosen = model.people
                        .map(RecordingSuggestionService.fold)
                        .toSet();
                    final open = _peopleSuggestions
                        .where(
                          (s) => !chosen.contains(
                            RecordingSuggestionService.fold(
                              s.participant.displayName,
                            ),
                          ),
                        )
                        .toList();
                    if (open.isEmpty) return const SizedBox.shrink();
                    return Wrap(
                      spacing: 8,
                      children: [
                        for (final s in open)
                          Tooltip(
                            message: s.reason,
                            triggerMode: TooltipTriggerMode.longPress,
                            child: ActionChip(
                              avatar: const Icon(Icons.history, size: 16),
                              label: Text(s.participant.displayName),
                              onPressed: () =>
                                  model.addPerson(s.participant.displayName),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          _personField(model),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(context, RecordingDetailsResult.transcribe);
            },
            icon: const Icon(Icons.transcribe),
            label: const Text('Transcribe now'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () =>
                Navigator.pop(context, RecordingDetailsResult.saved),
            child: const Text('Save details'),
          ),
          TextButton(
            onPressed: _confirmDiscard,
            child: const Text('Discard recording'),
          ),
        ],
      ),
    );
  }

  Widget _titleField(_DetailsModel model) => RawAutocomplete<String>(
    textEditingController: model.title,
    focusNode: _titleFocus,
    optionsBuilder: (value) =>
        _suggestions.completeTitles(value.text, widget.state.conversations),
    fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
        TextField(
          controller: controller,
          focusNode: focusNode,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Title (optional)',
            hintText: 'Recorded conversation',
          ),
          onSubmitted: (_) => onSubmitted(),
        ),
    optionsViewBuilder: (context, onSelected, options) => _OptionsList<String>(
      options: options,
      onSelected: onSelected,
      labelOf: (option) => Text(option),
    ),
  );

  Widget _personField(_DetailsModel model) => RawAutocomplete<_PersonOption>(
    textEditingController: model.personField,
    focusNode: _personFocus,
    displayStringForOption: (option) => option.name,
    optionsBuilder: (value) {
      final text = value.text.trim();
      if (text.isEmpty || text.contains(',')) return const [];
      final matches = _suggestions.completePeople(
        text,
        widget.state.activeParticipants,
        exclude: model.people.toSet(),
      );
      final exact = matches.any(
        (p) =>
            RecordingSuggestionService.fold(p.displayName) ==
            RecordingSuggestionService.fold(text),
      );
      return [
        for (final p in matches) _PersonOption(p.displayName, participant: p),
        if (!exact) _PersonOption(text),
      ];
    },
    onSelected: (option) {
      model.addPerson(option.name);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => model.personField.clear(),
      );
    },
    fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
      return TextField(
        controller: controller,
        focusNode: focusNode,
        decoration: const InputDecoration(
          labelText: 'Add person',
          hintText: 'Type a name, then Enter or comma',
        ),
        onChanged: (text) {
          if (!text.contains(',')) return;
          final parts = text.split(',');
          for (final part in parts.take(parts.length - 1)) {
            model.addPerson(part);
          }
          controller.text = parts.last.trimLeft();
          controller.selection = TextSelection.collapsed(
            offset: controller.text.length,
          );
        },
        onSubmitted: (_) {
          // Picks the highlighted suggestion; free text is the fallback.
          onSubmitted();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (controller.text.trim().isNotEmpty &&
                model.addPerson(controller.text)) {
              controller.clear();
            }
          });
          _personFocus.requestFocus();
        },
      );
    },
    optionsViewBuilder: (context, onSelected, options) =>
        _OptionsList<_PersonOption>(
          options: options,
          onSelected: onSelected,
          labelOf: (option) => option.isNew
              ? Text('Add "${option.name}" as new person')
              : Text(option.name),
        ),
  );
}

class _OptionsList<T extends Object> extends StatelessWidget {
  const _OptionsList({
    required this.options,
    required this.onSelected,
    required this.labelOf,
  });
  final Iterable<T> options;
  final AutocompleteOnSelected<T> onSelected;
  final Widget Function(T option) labelOf;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Material(
      elevation: 4,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220, maxWidth: 480),
        child: ListView(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          children: [
            for (final option in options)
              ListTile(
                dense: true,
                title: labelOf(option),
                onTap: () => onSelected(option),
              ),
          ],
        ),
      ),
    ),
  );
}
