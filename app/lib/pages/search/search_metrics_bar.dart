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
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 480
            ? 1
            : constraints.maxWidth < 768
            ? 2
            : 4;
        final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _Metric(
              label: 'Conversations',
              value: '${state.conversations.length}',
            ),
            _Metric(
              label: 'Participants',
              value: '${state.participants.length}',
            ),
            _Metric(label: 'Relations', value: '${state.relations.length}'),
            _Metric(label: 'Saved', value: '${state.savedSearches.length}'),
          ].map((metric) => SizedBox(width: width, child: metric)).toList(),
        );
      },
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
