import 'package:flutter/material.dart';

import '../app_state.dart';
import 'page_frame.dart';

class InsightsPage extends StatelessWidget {
  const InsightsPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    final insights = state.insights;
    return PageFrame(
      title: 'Insights',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _Metric(
                label: 'Conversations',
                value: '${insights.totalConversations}',
              ),
              _Metric(label: 'Segments', value: '${insights.totalSegments}'),
              _Metric(label: 'Artifacts', value: '${insights.totalArtifacts}'),
              _Metric(label: 'Tags', value: '${insights.tags.length}'),
            ],
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final panels = [
                _FacetPanel(
                  title: 'Sources',
                  icon: Icons.source_outlined,
                  rows: insights.sourceFacets
                      .map((facet) => _FacetRow(facet.source, facet.count))
                      .toList(),
                ),
                _FacetPanel(
                  title: 'People',
                  icon: Icons.people_outline,
                  rows: insights.participantFacets
                      .map(
                        (facet) => _FacetRow(
                          facet.participant.displayName,
                          facet.count,
                        ),
                      )
                      .toList(),
                ),
                _FacetPanel(
                  title: 'Timeline',
                  icon: Icons.calendar_month_outlined,
                  rows: insights.timeline
                      .map(
                        (bucket) =>
                            _FacetRow(_formatDay(bucket.day), bucket.count),
                      )
                      .toList(),
                ),
                _TagsPanel(tags: insights.tags),
              ];
              if (!wide) {
                return Column(
                  children: panels
                      .expand((panel) => [panel, const SizedBox(height: 12)])
                      .toList(),
                );
              }
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: panels
                    .map(
                      (panel) => SizedBox(
                        width: (constraints.maxWidth - 16) / 2,
                        child: panel,
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  String _formatDay(DateTime day) {
    final month = day.month.toString().padLeft(2, '0');
    final date = day.day.toString().padLeft(2, '0');
    return '${day.year}-$month-$date';
  }
}

class _FacetRow {
  const _FacetRow(this.label, this.count);

  final String label;
  final int count;
}

class _FacetPanel extends StatelessWidget {
  const _FacetPanel({
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<_FacetRow> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              const Text('No data yet')
            else
              for (final row in rows.take(8))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(row.label, overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 12),
                      Text('${row.count}'),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _TagsPanel extends StatelessWidget {
  const _TagsPanel({required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sell_outlined),
                const SizedBox(width: 8),
                Text('Tags', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 12),
            if (tags.isEmpty)
              const Text('No data yet')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final tag in tags) Chip(label: Text(tag))],
              ),
          ],
        ),
      ),
    );
  }
}

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
