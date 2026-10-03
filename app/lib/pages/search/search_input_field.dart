import 'package:flutter/material.dart';

/// View model for search page state and logic.
///
/// Encapsulates all search-related state including:
/// - Query text and controller
/// - Active filters (source, participant, tag)
/// - Computed search results
class SearchViewModel {
  SearchViewModel({
    required this.queryController,
    required this.sourceFilter,
    required this.participantFilter,
    required this.tagFilter,
    this.fromFilter,
    this.toFilter,
  });

  /// Controller for the search query text field.
  final TextEditingController queryController;

  /// Currently selected source filter (empty = all).
  String sourceFilter;

  /// Currently selected participant filter (empty = all).
  String participantFilter;

  /// Currently selected tag filter (empty = all).
  String tagFilter;

  /// Inclusive start of the "When" date-range filter (null = open).
  DateTime? fromFilter;

  /// Inclusive end of the "When" date-range filter (null = open).
  DateTime? toFilter;

  /// True when a date-range filter is active.
  bool get hasDateRange => fromFilter != null || toFilter != null;

  /// Clears all filters and query.
  void clearFilters() {
    queryController.clear();
    sourceFilter = '';
    participantFilter = '';
    tagFilter = '';
    fromFilter = null;
    toFilter = null;
  }

  /// Updates the query text.
  void setQuery(String text) {
    queryController.text = text;
  }

  /// Applies a saved search by populating all fields.
  void applySavedSearch({
    required String query,
    String? source,
    String? participantId,
    String? tag,
    DateTime? from,
    DateTime? to,
  }) {
    queryController.text = query;
    sourceFilter = source ?? '';
    participantFilter = participantId ?? '';
    tagFilter = tag ?? '';
    fromFilter = from;
    toFilter = to;
  }
}

/// Input field widget for search queries.
///
/// Provides a searchable text field with customizable styling.
/// Triggers onChanged callback on text modifications.
class SearchInputField extends StatelessWidget {
  const SearchInputField({
    required this.viewModel,
    required this.onChanged,
    this.focusNode,
    super.key,
  });

  /// View model containing search state.
  final SearchViewModel viewModel;

  /// Callback invoked when text changes.
  final VoidCallback onChanged;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: viewModel.queryController,
      focusNode: focusNode,
      onChanged: (_) => onChanged(),
      onSubmitted: (_) {
        FocusScope.of(context).unfocus();
        onChanged();
      },
      textInputAction: TextInputAction.search,
      decoration: const InputDecoration(
        labelText: 'Search text, people, relations',
        prefixIcon: Icon(Icons.search),
        border: OutlineInputBorder(),
      ),
    );
  }
}
