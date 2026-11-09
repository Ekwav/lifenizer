import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'page_frame.dart';

class ParticipantsPage extends StatefulWidget {
  const ParticipantsPage({required this.state, super.key});
  final LifenizerAppState state;

  @override
  State<ParticipantsPage> createState() => _ParticipantsPageState();
}

class _ParticipantsPageState extends State<ParticipantsPage> {
  LifenizerAppState get state => widget.state;
  String _query = '';
  int _page = 0;
  static const _pageSize = 50;

  Future<void> _addIdentity(BuildContext context, Participant person) async {
    final controller = TextEditingController();
    final identity = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Link identity to ${person.displayName}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Email or provider:id',
            hintText: 'alice@example.org or discord:123456789',
            helperText:
                'If already linked to another person, the people are merged.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Link identity'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (identity?.isNotEmpty == true) {
      await state.addParticipantIdentity(person.id, identity!);
    }
  }

  Future<void> _merge(BuildContext context, Participant person) async {
    final others = state.activeParticipants
        .where((item) => item.id != person.id)
        .toList();
    if (others.isEmpty) return;
    var target = others.first.id;
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Merge ${person.displayName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose the person to keep. Both sets of identities, names and conversations will be connected, including future imports.',
              ),
              const SizedBox(height: 12),
              DropdownButton<String>(
                value: target,
                isExpanded: true,
                items: [
                  for (final other in others)
                    DropdownMenuItem(
                      value: other.id,
                      child: Text(
                        '${other.displayName} · ${other.identifiers.join(', ')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => update(() => target = value!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, target),
              child: const Text('Merge people'),
            ),
          ],
        ),
      ),
    );
    if (selected != null) {
      await state.mergeParticipants(person.id, selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = state.activeParticipants
        .where(
          (person) => person.searchableText.toLowerCase().contains(
            _query.toLowerCase(),
          ),
        )
        .toList();
    final pages = (people.length + _pageSize - 1) ~/ _pageSize;
    final page = pages == 0 ? 0 : (_page < pages ? _page : pages - 1);
    return PageFrame(
      title: 'People',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Names and identities are detected from imports. Link an email or merge a Discord identity with an existing person to connect future conversations.',
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Find a person, alias or identity',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() {
              _query = value;
              _page = 0;
            }),
          ),
          const SizedBox(height: 12),
          Text('${people.length} ${people.length == 1 ? 'person' : 'people'}'),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final person
                  in people.skip(page * _pageSize).take(_pageSize))
                SizedBox(
                  width: 320,
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(person.displayName),
                      subtitle: Text(
                        [
                          ...person.identifiers,
                          if (person.aliases.isNotEmpty)
                            'Also: ${person.aliases.join(', ')}',
                        ].join('\n'),
                      ),
                      trailing: PopupMenuButton<String>(
                        enabled: !state.busy,
                        tooltip: 'Manage ${person.displayName}',
                        onSelected: (value) => value == 'merge'
                            ? _merge(context, person)
                            : _addIdentity(context, person),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'identity',
                            child: Text('Link identity'),
                          ),
                          if (state.activeParticipants.length > 1)
                            const PopupMenuItem(
                              value: 'merge',
                              child: Text('Merge people'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (pages > 1)
            Row(
              children: [
                TextButton(
                  onPressed: page == 0
                      ? null
                      : () => setState(() => _page = page - 1),
                  child: const Text('Previous'),
                ),
                Text('${page + 1} / $pages'),
                TextButton(
                  onPressed: page + 1 >= pages
                      ? null
                      : () => setState(() => _page = page + 1),
                  child: const Text('Next'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
