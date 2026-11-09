import 'package:flutter/material.dart';
import '../../widgets/recording_context_editor.dart';
import '../../app_state.dart';
import '../../image_widgets.dart';
import '../../models.dart';
import '../../services/source_categories.dart';
import '../../services/transcript_enrichment.dart';
import '../../services/source_links.dart';
import '../../widgets/transcription_correction_dialog.dart';
import '../../widgets/recording_audio_player.dart';

/// Lazy sliver list of search results for the page's single scroll viewport.
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
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              state.searchDetailsLoading
                  ? 'Searching…'
                  : state.conversations.isEmpty
                  ? 'No conversations yet. Capture or import something to get started.'
                  : 'No matches. Try a different query or clear the filters.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              hasMore
                  ? 'Showing first ${results.length} results'
                  : '${results.length} result${results.length == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ),
        SliverList.builder(
          itemCount: results.length,
          itemBuilder: (context, index) {
            final conversation = results[index];
            return Padding(
              key: ValueKey(conversation.id),
              padding: const EdgeInsets.only(bottom: 12),
              child: ConversationCard(state: state, conversation: conversation),
            );
          },
        ),
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
    final preview = conversation.previewText;
    final category = categoryForSource(conversation.source);
    final (typeLabel, typeIcon) = switch (category) {
      SourceCategory.consumed => ('Consumed', Icons.visibility_outlined),
      SourceCategory.documents => ('Documents', Icons.description_outlined),
      SourceCategory.personal when conversation.source == 'audio' => (
        'Recording',
        Icons.mic_none,
      ),
      SourceCategory.personal
          when ['email', 'imap', 'mbox'].contains(conversation.source) =>
        ('Email', Icons.mail_outline),
      SourceCategory.personal when conversation.source.startsWith('manual') => (
        'Note',
        Icons.notes,
      ),
      _ => ('Chat', Icons.chat_bubble_outline),
    };
    final sourceIcon = switch (conversation.source) {
      'discord' => Icons.discord,
      'telegram' => Icons.telegram,
      'whatsapp' => Icons.phone_in_talk_outlined,
      'tiktok-watch-history' => Icons.tiktok,
      'youtube-watch-history' ||
      'youtube-transcript' => Icons.smart_display_outlined,
      'email' || 'imap' || 'mbox' => Icons.mail_outline,
      'browser-history' || 'bookmarks' || 'browser-capture' => Icons.language,
      'audio' || 'live-recording' => Icons.graphic_eq,
      _ => Icons.forum_outlined,
    };
    final tags = conversation.tags
        .where(
          (tag) =>
              tag.toLowerCase() != conversation.source.toLowerCase() &&
              tag.toLowerCase() != typeLabel.toLowerCase() &&
              !(typeLabel == 'Recording' && tag == 'recordings'),
        )
        .toList();
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
              Row(
                children: [
                  Tooltip(
                    message: conversation.source,
                    child: Icon(
                      sourceIcon,
                      size: 16,
                      semanticLabel: conversation.source,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    key: category == SourceCategory.consumed
                        ? const Key('consumed-badge')
                        : null,
                    message: typeLabel,
                    child: Icon(typeIcon, size: 16, semanticLabel: typeLabel),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      participants.isNotEmpty
                          ? participants
                          : watchHistoryLine(conversation) ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                conversation.startedAt.toCompactLocalString(),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in tags)
                      Chip(
                        label: Text(tag),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Text(preview, maxLines: 3, overflow: TextOverflow.ellipsis),
              TranscriptAction(state: state, conversation: conversation),
            ],
          ),
        ),
      ),
    );
  }
}

/// "YouTube • Channel • watched 3×" for watch-history conversations, or null.
String? watchHistoryLine(Conversation conversation) {
  final platform = switch (conversation.source) {
    'youtube-watch-history' => 'YouTube',
    'tiktok-watch-history' => 'TikTok',
    _ => null,
  };
  if (platform == null) return null;
  final channel = conversation.metadata['channel']?.trim();
  final count = int.tryParse(conversation.metadata['watchCount'] ?? '');
  return [
    platform,
    if (channel != null && channel.isNotEmpty) channel,
    if (count != null) 'watched $count×',
  ].join(' • ');
}

/// Per-conversation transcript action for watched videos: a "Fetch
/// transcript" button for YouTube, a short explanation for TikTok.
class TranscriptAction extends StatefulWidget {
  const TranscriptAction({
    required this.state,
    required this.conversation,
    super.key,
  });

  final LifenizerAppState state;
  final Conversation conversation;

  @override
  State<TranscriptAction> createState() => _TranscriptActionState();
}

class _TranscriptActionState extends State<TranscriptAction> {
  bool _loading = false;
  String? _message;

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    final result = await widget.state.enrichWatchedVideo(
      widget.conversation.id,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _message = switch (result.outcome) {
        TranscriptOutcome.merged => 'Transcript added.',
        TranscriptOutcome.unavailable => 'This video has no public captions.',
        TranscriptOutcome.rateLimited ||
        TranscriptOutcome.blocked => 'YouTube is rate limiting; try later.',
        _ => result.message ?? 'Could not fetch the transcript.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final conversation =
        widget.state.conversations
            .where((item) => item.id == widget.conversation.id)
            .firstOrNull ??
        widget.conversation;
    if (conversation.source == 'tiktok-watch-history') {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Tooltip(
          message:
              'TikTok exports contain only video links. Reading or '
              'transcribing the video needs a video download and speech/OCR '
              'pipeline, which Lifenizer does not have.',
          child: Text(
            'No transcript available for TikTok',
            key: Key('tiktok-no-transcript'),
          ),
        ),
      );
    }
    if (conversation.source != 'youtube-watch-history') {
      return const SizedBox.shrink();
    }
    final status = conversation.metadata['transcript'] ?? 'none';
    if (status == 'youtube-captions') {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('Transcript available', key: Key('transcript-present')),
      );
    }
    if (status == 'unavailable') {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'No public captions for this video',
          key: Key('transcript-unavailable'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          TextButton.icon(
            key: const Key('fetch-transcript'),
            onPressed: _loading || widget.state.busy ? null : _fetch,
            icon: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.subtitles_outlined, size: 18),
            label: const Text('Fetch transcript'),
          ),
          if (_message != null) Text(_message!),
        ],
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
class _ConversationDetailSheet extends StatefulWidget {
  const _ConversationDetailSheet({
    required this.state,
    required this.conversation,
  });

  final LifenizerAppState state;
  final Conversation conversation;

  @override
  State<_ConversationDetailSheet> createState() =>
      _ConversationDetailSheetState();
}

class _ConversationDetailSheetState extends State<_ConversationDetailSheet> {
  Future<Conversation>? _conversation;
  Conversation? _catalogConversation;
  Animation<double>? _entrance;
  late final bool _openedUnlocked;
  bool _locked = false;

  LifenizerAppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _openedUnlocked = state.isAuthenticated;
    _catalogConversation = _currentConversation;
    if (widget.conversation.isLoaded) _conversation = _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_conversation != null || _entrance != null) return;
    _entrance = ModalRoute.of(context)?.animation;
    if (_entrance == null || _entrance!.isCompleted) {
      _conversation = _load();
    } else {
      _entrance!.addStatusListener(_afterEntrance);
    }
  }

  void _afterEntrance(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _entrance?.removeStatusListener(_afterEntrance);
    if (!mounted || _locked || (_openedUnlocked && !state.isAuthenticated)) {
      return;
    }
    setState(() {
      _conversation = _load();
    });
  }

  @override
  void dispose() {
    _entrance?.removeStatusListener(_afterEntrance);
    super.dispose();
  }

  Conversation? get _currentConversation => state.conversations
      .where((item) => item.id == widget.conversation.id)
      .firstOrNull;

  Future<Conversation> _load() {
    final current = _currentConversation ?? widget.conversation;
    return current.isLoaded
        ? Future.value(current)
        : state.loadConversation(current.id);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      if (_openedUnlocked && !state.isAuthenticated) _locked = true;
      if (_locked) return const SizedBox.shrink();
      final current = _currentConversation;
      if (current != null && !identical(current, _catalogConversation)) {
        _catalogConversation = current;
        _conversation = _load();
      }
      return FutureBuilder<Conversation>(
        future: _conversation,
        initialData: widget.conversation.isLoaded ? widget.conversation : null,
        builder: (context, snapshot) {
          final failed =
              snapshot.connectionState == ConnectionState.done &&
              snapshot.hasError;
          return _buildDetail(
            context,
            snapshot.data ?? widget.conversation,
            loading: !snapshot.hasData && !failed,
            failed: failed,
          );
        },
      );
    },
  );

  Widget _buildDetail(
    BuildContext context,
    Conversation loaded, {
    bool loading = false,
    bool failed = false,
  }) {
    final conversation =
        state.conversations
            .where((item) => item.id == loaded.id && item.isLoaded)
            .firstOrNull ??
        loaded;
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
        return Scrollbar(
          controller: scrollController,
          thickness: 6,
          trackVisibility: false,
          radius: const Radius.circular(3),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: CustomScrollView(
              controller: scrollController,
              scrollBehavior: ScrollConfiguration.of(
                ctx,
              ).copyWith(scrollbars: false),
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
                      participants.isEmpty
                          ? watchHistoryLine(conversation) ??
                                '${conversation.source} • $participants'
                          : '${conversation.source} • $participants',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TranscriptAction(
                      state: state,
                      conversation: conversation,
                    ),
                  ),
                ),
                if (conversation.source == 'audio')
                  SliverToBoxAdapter(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: state.busy
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                barrierDismissible: false,
                                builder: (_) => RecordingContextEditor(
                                  state: state,
                                  conversation: conversation,
                                ),
                              ),
                        icon: const Icon(Icons.edit_location_alt_outlined),
                        label: Text(
                          conversation.location?.displayName.isNotEmpty == true
                              ? conversation.location!.displayName
                              : 'Edit people and location',
                        ),
                      ),
                    ),
                  ),
                if (conversation.source == 'audio')
                  SliverToBoxAdapter(
                    child: RecordingAudioPlayer(
                      state: state,
                      conversationId: conversation.id,
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
                if (!loading && !failed)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: ImageGallery(
                        state: state,
                        conversationId: conversation.id,
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Text(
                    'Transcript',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (failed)
                  SliverToBoxAdapter(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Could not load this conversation.'),
                        TextButton(
                          onPressed: () => setState(() {
                            _conversation = _load();
                          }),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                else if (loading)
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (conversation.previewText.isNotEmpty)
                          Text(conversation.previewText),
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ],
                    ),
                  )
                else if (conversation.segments.isEmpty)
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
                                if (conversation.source == 'audio' &&
                                    segment.text.trim().isNotEmpty)
                                  TextButton.icon(
                                    onPressed: () =>
                                        showTranscriptionCorrection(
                                          context,
                                          state,
                                          conversation,
                                          segment,
                                        ),
                                    icon: const Icon(Icons.edit_note, size: 16),
                                    label: const Text('Correct for TAB'),
                                  ),
                                if (link != null)
                                  TextButton.icon(
                                    onPressed: () => _openLink(link),
                                    icon: const Icon(
                                      Icons.open_in_new,
                                      size: 16,
                                    ),
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
