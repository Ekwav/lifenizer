import 'package:flutter/material.dart';

import '../app_state.dart';
import 'page_frame.dart';

class ParticipantsPage extends StatelessWidget {
  const ParticipantsPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'People',
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final participant in state.participants)
            SizedBox(
              width: 260,
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(participant.displayName),
                  subtitle: Text(
                    participant.identifiers.isEmpty
                        ? participant.id
                        : participant.identifiers.join(', '),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
