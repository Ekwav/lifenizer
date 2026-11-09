import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models.dart';
import '../services/quick_action_service.dart';
import '../services/sync_progress.dart';
import '../widgets/sync_progress_indicator.dart';
import 'page_frame.dart';
import 'search/search_filters.dart';
import 'search/search_input_field.dart';
import 'search/search_results_list.dart';

/// Refactored search page with composable widgets.
///
/// Provides a clean, organized search interface with:
/// - Search input field
/// - Filters (source, participant, tag)
/// - Saved searches
/// - Search results list
///
/// Significantly reduced nesting (from 11 levels to ~6) and improved maintainability.
class SearchPage extends StatefulWidget {
  const SearchPage({
    required this.state,
    this.action,
    this.actionRevision = 0,
    super.key,
  });

  final LifenizerAppState state;
  final QuickAction? action;
  final int actionRevision;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late SearchViewModel _viewModel;
  final _searchFocus = FocusNode();
  int _resultLimit = 50;

  @override
  void initState() {
    super.initState();
    _viewModel = SearchViewModel(
      queryController: TextEditingController(text: widget.action?.query ?? ''),
      sourceFilter: '',
      participantFilter: '',
      tagFilter: '',
    );
    _applyAction();
    _adoptLockScreenSearch();
  }

  /// Continues the search typed on the lock screen with the same text, cursor
  /// and IME composing range. Focusing before the first frame lets the
  /// keyboard move to this field without closing in between.
  void _adoptLockScreenSearch() {
    final pending = widget.state.pendingSearch;
    widget.state.pendingSearch = TextEditingValue.empty;
    if (widget.action?.conversationId != null) return;
    if (widget.action == null) _viewModel.queryController.value = pending;
    _searchFocus.requestFocus();
  }

  @override
  void didUpdateWidget(SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actionRevision != widget.actionRevision) _applyAction();
  }

  void _applyAction() {
    _resultLimit = 50;
    _viewModel.clearFilters();
    _viewModel.setQuery(widget.action?.query ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final id = widget.action?.conversationId;
      final conversation = id == null
          ? null
          : widget.state.conversations
                .where((item) => item.id == id)
                .firstOrNull;
      if (conversation != null) {
        openConversationDetail(context, widget.state, conversation);
      } else {
        _searchFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    _viewModel.queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_viewModel.participantFilter.isNotEmpty) {
      _viewModel.participantFilter = widget.state.resolveParticipantId(
        _viewModel.participantFilter,
      );
    }
    // Compute search results based on current filters
    final results = widget.state.search(
      _viewModel.queryController.text,
      source: _viewModel.sourceFilter,
      participantId: _viewModel.participantFilter,
      tag: _viewModel.tagFilter,
      from: _viewModel.fromFilter,
      to: _viewModel.toFilter,
      includeConsumed: !_viewModel.hideConsumed,
      maxResults: _resultLimit + 1,
    );

    return RefreshIndicator(
      onRefresh: widget.state.pullSync,
      child: PageFrame.slivers(
        title: 'Search',
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.state.syncProgress?.stage == SyncStage.indexing)
                  SyncProgressIndicator(progress: widget.state.syncProgress),
                if (widget.state.searchIndexPreparing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Search index still preparing · showing quick matches',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (widget.state.searchDetailsLoading)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: LinearProgressIndicator(),
                  ),
                if (widget.state.searchError case final String message)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(child: Text(message)),
                        TextButton(
                          onPressed: widget.state.busy
                              ? null
                              : widget.state.retrySearch,
                          child: const Text('Rebuild search'),
                        ),
                      ],
                    ),
                  ),
                // Search input field
                SearchInputField(
                  viewModel: _viewModel,
                  focusNode: _searchFocus,
                  onChanged: () => setState(() => _resultLimit = 50),
                ),
                const SizedBox(height: 8),

                // Filter controls and action buttons
                SearchFilters(
                  viewModel: _viewModel,
                  availableSources: widget.state.availableSources,
                  availableParticipants: widget.state.activeParticipants
                      .map((item) => item.id)
                      .toList(),
                  availableTags: widget.state.allTags,
                  availableLocations: widget.state.availableLocations,
                  locationOptions: widget.state.locationFilterOptions,
                  participantName: widget.state.participantName,
                  onFilterChanged: () => setState(() => _resultLimit = 50),
                  onClearFilters: () => setState(() {
                    _resultLimit = 50;
                    _viewModel.clearFilters();
                  }),
                  onSaveSearch: _saveCurrentSearch,
                  isBusy: widget.state.busy,
                ),

                // Saved searches chips
                if (widget.state.savedSearches.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final savedSearch in widget.state.savedSearches)
                        ActionChip(
                          avatar: const Icon(Icons.bookmark_outline),
                          label: Text(savedSearch.title),
                          onPressed: () => setState(() {
                            _resultLimit = 50;
                            _viewModel.applySavedSearch(
                              query: savedSearch.query,
                              source: savedSearch.source,
                              participantId: savedSearch.participantId,
                              tag: savedSearch.tag,
                              from: savedSearch.from,
                              to: savedSearch.to,
                              hideConsumed: savedSearch.hideConsumed,
                            );
                          }),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
          SearchResultsList(
            results: results.take(_resultLimit).toList(growable: false),
            state: widget.state,
            hasMore: results.length > _resultLimit,
          ),
          if (results.length > _resultLimit)
            SliverToBoxAdapter(
              child: OutlinedButton(
                onPressed: () => setState(
                  () => _resultLimit = (_resultLimit + 50).clamp(50, 100),
                ),
                child: const Text('Show more conversations'),
              ),
            ),
        ],
      ), // PageFrame
    ); // RefreshIndicator
  }

  /// Saves the current search configuration.
  Future<void> _saveCurrentSearch() async {
    final parts = <String>[
      if (_viewModel.queryController.text.trim().isNotEmpty)
        _viewModel.queryController.text.trim(),
      if (_viewModel.sourceFilter.isNotEmpty) _viewModel.sourceFilter,
      if (_viewModel.tagFilter.isNotEmpty) '#${_viewModel.tagFilter}',
      if (_viewModel.participantFilter.isNotEmpty)
        widget.state.participantName(_viewModel.participantFilter),
      if (_viewModel.hideConsumed) 'no consumed media',
      if (_viewModel.hasDateRange)
        'when: '
            '${_viewModel.fromFilter?.toCompactLocalDateString() ?? '…'} – '
            '${_viewModel.toFilter?.toCompactLocalDateString() ?? '…'}',
    ];
    await widget.state.addSavedSearch(
      title: parts.isEmpty ? 'All conversations' : parts.join(' / '),
      query: _viewModel.queryController.text,
      source: _viewModel.sourceFilter,
      participantId: _viewModel.participantFilter,
      tag: _viewModel.tagFilter,
      from: _viewModel.fromFilter,
      to: _viewModel.toFilter,
      hideConsumed: _viewModel.hideConsumed,
    );
  }
}
