import 'package:flutter/material.dart';

import '../app_state.dart';
import 'page_frame.dart';

class RelationsPage extends StatelessWidget {
  const RelationsPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'Relations',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final relation in state.relations) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(
                  '${relation.subject} ${relation.relation} ${relation.object}',
                ),
                subtitle: Text(relation.evidence),
                trailing: Text('${(relation.confidence * 100).round()}%'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
