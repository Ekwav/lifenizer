import 'package:flutter/material.dart';
import '../../app_state.dart';
import '../../image_widgets.dart';
import '../../models.dart';
import '../../services/source_links.dart';

/// Displays the list of search results.
///
/// Handles empty states, result count display, and conversation cards.
/// Each result can be clicked to show a detail sheet.
class SearchResultsList extends StatelessWidget {
  const SearchResultsList({
    required this.results,
    required this.state,
    this.hasMore = false,
    super.key,
  });

  /// List of conversations matching the search criteria.
  final List<Conversation> results;
  final bool hasMore;

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
            hasMore
                ? 'Showing first ${results.length} results'
                : '${results.length} result${results.length == 1 ? '' : 's'}',
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
    openConversationDetail(context, state, conversation);
  }

  @override
  Widget build(BuildContext context) {
    final participants = conversation.participantIds
        .map(state.participantName)
        .join(', ');
    final preview = _previewText(conversation);
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

void openConversationDetail(
  BuildContext context,
  LifenizerAppState state,
  Conversation conversation,
) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) =>
        _ConversationDetailSheet(state: state, conversation: conversation),
  );
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
    final sourceUrl = externalLinkUri(conversation.sourceUrl);
    final ownMessagesOnly =
        conversation.metadata['messageScope'] == 'own-sent-messages';
    final directMessage = [
      'DM',
      'GROUP_DM',
    ].contains(conversation.metadata['channelType']);

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
              if (sourceUrl != null)
                SliverToBoxAdapter(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _openLink(sourceUrl.toString()),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(
                        conversation.source == 'discord'
                            ? 'Open Discord chat'
                            : 'Open original',
                      ),
                    ),
                  ),
                ),
              if (ownMessagesOnly)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'This export contains only your sent messages; other people’s replies are absent.'
                      '${directMessage ? ' Known recipients are shown above.' : ' Discord did not include this channel’s other members.'}'
                      '${conversation.metadata.containsKey('unidentifiedRecipients') ? ' Some deleted recipients have no usable identity.' : ''}'
                      '${sourceUrl == null ? ' The original channel link is unavailable in this export.' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
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
              if (conversation.segments.isEmpty)
                const SliverToBoxAdapter(child: Text('No transcript.'))
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final segment = conversation.segments[index];
                    final link = discordMessageUrl(conversation, segment);
                    return Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            children: [
                              Text(
                                '${segment.createdAt.toCompactLocalString()}${segment.participantId == null ? '' : ' · ${state.participantName(segment.participantId!)}'}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (link != null)
                                TextButton.icon(
                                  onPressed: () => _openLink(link),
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: const Text('Open message'),
                                ),
                            ],
                          ),
                          if (segment.text.isNotEmpty)
                            SelectableText(
                              _formatSegmentLine(segment),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          for (final attachment in segment.attachmentUrls)
                            if (externalLinkUri(attachment) != null)
                              TextButton.icon(
                                onPressed: () => _openLink(attachment),
                                icon: const Icon(Icons.attach_file, size: 16),
                                label: Text(
                                  Uri.parse(
                                        attachment,
                                      ).pathSegments.lastOrNull ??
                                      'Attachment',
                                ),
                              ),
                        ],
                      ),
                    );
                  }, childCount: conversation.segments.length),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openLink(String url) async {
    if (!await openExternalLink(url)) {
      state.reportError('Could not open the link in another app.');
    }
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

String _previewText(Conversation conversation) {
  final text = StringBuffer();
  for (final segment in conversation.segments) {
    if (segment.text.isEmpty) continue;
    if (text.isNotEmpty) text.write(' ');
    final remaining = 500 - text.length;
    if (remaining <= 0) break;
    text.write(
      segment.text.length > remaining
          ? segment.text.substring(0, remaining)
          : segment.text,
    );
    if (text.length >= 500) break;
  }
  return text.toString();
}
