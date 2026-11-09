import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/recording_suggestions.dart';

typedef _PersonOption = ({Participant person, String prefix});

/// Selected contacts retain their IDs; unselected text remains new-name input.
class ParticipantPicker extends StatefulWidget {
  const ParticipantPicker({
    required this.state,
    required this.controller,
    required this.selectedIds,
    required this.onChanged,
    this.enabled = true,
    this.decoration = const InputDecoration(labelText: 'Participants'),
    super.key,
  });

  final LifenizerAppState state;
  final TextEditingController controller;
  final List<String> selectedIds;
  final ValueChanged<List<String>> onChanged;
  final bool enabled;
  final InputDecoration decoration;

  @override
  State<ParticipantPicker> createState() => _ParticipantPickerState();
}

class _ParticipantPickerState extends State<ParticipantPicker> {
  final _focus = FocusNode();

  String _details(Participant? person) {
    if (person == null) return 'Unknown person';
    final details = [...person.aliases, ...person.identifiers];
    return details.isEmpty ? person.id : details.join(' · ');
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.selectedIds.isNotEmpty)
          Wrap(
            spacing: 4,
            children: [
              for (final id in widget.selectedIds)
                InputChip(
                  key: ValueKey('selected-participant-$id'),
                  label: Text(
                    widget.state.participantById(id)?.displayName ??
                        'Unknown person',
                  ),
                  tooltip: _details(widget.state.participantById(id)),
                  onDeleted: widget.enabled
                      ? () => widget.onChanged([
                          for (final selected in widget.selectedIds)
                            if (selected != id) selected,
                        ])
                      : null,
                ),
            ],
          ),
        RawAutocomplete<_PersonOption>(
          textEditingController: widget.controller,
          focusNode: _focus,
          displayStringForOption: (option) => option.prefix,
          optionsBuilder: (value) {
            if (!widget.enabled) return const [];
            final separator = value.text.lastIndexOf(',');
            final query = value.text.substring(separator + 1).trim();
            final selected = widget.selectedIds
                .map(widget.state.resolveParticipantId)
                .toSet();
            return const RecordingSuggestionService()
                .completePeople(
                  query,
                  widget.state.activeParticipants,
                  excludeIds: selected,
                )
                .map(
                  (person) => (
                    person: person,
                    prefix: separator < 0
                        ? ''
                        : value.text.substring(0, separator + 1),
                  ),
                );
          },
          onSelected: (option) {
            widget.onChanged([...widget.selectedIds, option.person.id]);
            _focus.requestFocus();
          },
          fieldViewBuilder: (context, controller, focus, onSubmitted) => TextField(
            controller: controller,
            focusNode: focus,
            enabled: widget.enabled,
            decoration: widget.decoration.copyWith(
              hintText:
                  'Search names, aliases or email; separate new names with commas',
            ),
            onSubmitted: (_) => onSubmitted(),
          ),
          optionsViewBuilder: (context, onSelected, options) {
            final entries = options.toList();
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                child: SizedBox(
                  width: (MediaQuery.sizeOf(context).width - 40)
                      .clamp(0, 360)
                      .toDouble(),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: entries.length,
                      itemBuilder: (context, index) => ListTile(
                        title: Text(entries[index].person.displayName),
                        subtitle: Text(_details(entries[index].person)),
                        selected:
                            AutocompleteHighlightedOption.of(context) == index,
                        onTap: () => onSelected(entries[index]),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    ),
  );
}
