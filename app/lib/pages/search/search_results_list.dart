import 'package:flutter/material.dart';
import '../../app_state.dart';
import '../../image_widgets.dart';
import '../../models.dart';

/// Displays the list of search results.
///
/// Handles empty states, result count display, and conversation cards.
/// Each result can be clicked to show a detail sheet.
class SearchResultsList extends StatelessWidget {
  const SearchResultsList({
    required this.results,
    required this.state,
    super.key,
  });

  /// List of conversations matching the search criteria.
  final List<Conversation> results;

  /// App state for accessing data and performing actions.
  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            state.conversations.isEmpty
                ? 'No conversations yet. Capture or import something to get started.'
                : 'No matches. Try a different query or clear the filters.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '${results.length} result${results.length == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
        for (final conversation in results) ...[
          ConversationCard(state: state, conversation: conversation),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

/// Card widget for displaying a single conversation in search results.
///
/// Shows conversation title, source, participants, tags, and a preview.
/// Tappable to view full details in a modal sheet.
class ConversationCard extends StatelessWidget {
  const ConversationCard({
    required this.state,
    required this.conversation,
    super.key,
  });

  final LifenizerAppState state;
  final Conversation conversation;

  void _openDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          _ConversationDetailSheet(state: state, conversation: conversation),
    );
  }

  @override
  Widget build(BuildContext context) {
    final participants = conversation.participantIds
        .map(state.participantName)
        .join(', ');
    final preview = conversation.segments
        .map((segment) => segment.text)
        .join(' ');
    return Card(
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        onTap: () => _openDetail(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      conversation.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Detect relations',
                    onPressed: () => state.extractRelations(conversation),
                    icon: const Icon(Icons.account_tree_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('${conversation.source} • $participants'),
              const SizedBox(height: 2),
              Text(
                conversation.startedAt.toCompactLocalString(),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (conversation.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in conversation.tags)
                      Chip(
                        label: Text(tag),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Text(preview, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

/// Detail sheet for viewing full conversation information.
///
/// Displays conversation title, metadata, tags, images, and full transcript
/// in a draggable modal sheet.
class _ConversationDetailSheet extends StatelessWidget {
  const _ConversationDetailSheet({
    required this.state,
    required this.conversation,
  });

  final LifenizerAppState state;
  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    final participants = conversation.participantIds
        .map(state.participantName)
        .join(', ');
    final fullText = conversation.segments.map(_formatSegmentLine).join('\n\n');

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 1.0,
      expand: false,
      builder: (ctx, scrollController) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Text(
                  conversation.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Text(
                    '${conversation.source} • $participants',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              if (conversation.tags.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final tag in conversation.tags)
                          Chip(
                            label: Text(tag),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: AnimatedBuilder(
                    animation: state,
                    builder: (_, _) => ImageGallery(
                      state: state,
                      conversationId: conversation.id,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Text(
                  'Transcript',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    fullText.isEmpty ? 'No transcript.' : fullText,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Formats a segment for the transcript view, prefixing it with its
/// `[mm:ss]` offset when the segment carries a non-zero [offsetMs] (e.g. a
/// transcribed audio recording), so a long recording stays skimmable.
/// Segments without a meaningful offset (typed text, single-shot imports)
/// are shown unprefixed.
String _formatSegmentLine(ConversationSegment segment) {
  if (segment.offsetMs <= 0) {
    return segment.text;
  }
  final totalSeconds = segment.offsetMs ~/ 1000;
  final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '[$minutes:$seconds] ${segment.text}';
}
