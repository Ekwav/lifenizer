import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models.dart';
import '../services/quick_action_service.dart';
import 'page_frame.dart';
import 'search/search_filters.dart';
import 'search/search_input_field.dart';
import 'search/search_metrics_bar.dart';
import 'search/search_results_list.dart';

/// Refactored search page with composable widgets.
///
/// Provides a clean, organized search interface with:
/// - Search input field
/// - Filters (source, participant, tag)
/// - Saved searches
/// - Metrics display
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
      final conversation = widget.state.conversations
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
    // Compute search results based on current filters
    final results = widget.state.search(
      _viewModel.queryController.text,
      source: _viewModel.sourceFilter,
      participantId: _viewModel.participantFilter,
      tag: _viewModel.tagFilter,
      from: _viewModel.fromFilter,
      to: _viewModel.toFilter,
      maxResults: _resultLimit + 1,
    );

    return RefreshIndicator(
      onRefresh: widget.state.pullSync,
      child: PageFrame(
        title: 'Search',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Search input field
            SearchInputField(
              viewModel: _viewModel,
              focusNode: _searchFocus,
              onChanged: () => setState(() => _resultLimit = 50),
            ),
            const SizedBox(height: 16),

            // Filter controls and action buttons
            SearchFilters(
              viewModel: _viewModel,
              availableSources: widget.state.availableSources,
              availableParticipants: widget.state.participants
                  .map((item) => item.id)
                  .toList(),
              availableTags: widget.state.allTags,
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
                        );
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),

            // Metrics display
            SearchMetricsBar(state: widget.state),
            const SizedBox(height: 16),

            // Search results.
            //
            // Deliberately not wrapped in Expanded: PageFrame renders this
            // whole page inside a SingleChildScrollView, which gives its
            // content unbounded height. Expanded requires a bounded height
            // from its parent to make sense ("fill the remaining space"),
            // so pairing it with an unbounded-height ancestor throws a
            // RenderFlex layout assertion at runtime ("children have
            // non-zero flex but incoming height constraints are
            // unbounded") — the whole page fails to render. SearchResultsList
            // is a plain Column, which sizes to its own content and scrolls
            // naturally with the rest of the page.
            SearchResultsList(
              results: results.take(_resultLimit).toList(growable: false),
              state: widget.state,
              hasMore: results.length > _resultLimit,
            ),
            if (results.length > _resultLimit)
              OutlinedButton(
                onPressed: () => setState(() => _resultLimit += 50),
                child: const Text('Show more conversations'),
              ),
          ],
        ),
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
    );
  }
}
