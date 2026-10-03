import 'package:flutter/material.dart';
import '../../app_state.dart';

/// Displays search metrics including total conversations, participants, relations, and saved searches.
///
/// Shows key statistics at a glance using metric cards in a flexible wrap layout.
class SearchMetricsBar extends StatelessWidget {
  const SearchMetricsBar({required this.state, super.key});

  /// App state containing metrics data.
  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _Metric(label: 'Conversations', value: '${state.conversations.length}'),
        _Metric(label: 'Participants', value: '${state.participants.length}'),
        _Metric(label: 'Relations', value: '${state.relations.length}'),
        _Metric(label: 'Saved', value: '${state.savedSearches.length}'),
      ],
    );
  }
}

/// Displays a single metric value with a label.
///
/// Renders a bordered card with headline-sized value and smaller label text.
class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.headlineSmall),
          Text(label),
        ],
      ),
    );
  }
}
