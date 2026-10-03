import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models.dart';
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
  const SearchPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late SearchViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = SearchViewModel(
      queryController: TextEditingController(),
      sourceFilter: '',
      participantFilter: '',
      tagFilter: '',
    );
  }

  @override
  void dispose() {
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
              onChanged: () => setState(() {}),
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
              onFilterChanged: () => setState(() {}),
              onClearFilters: () => setState(() {
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
            SearchResultsList(results: results, state: widget.state),
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
