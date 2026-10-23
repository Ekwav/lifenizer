import 'package:flutter/material.dart';
import '../../models.dart';
import 'search_input_field.dart';

/// Compact search filters with searchable participant and tag pickers.
class SearchFilters extends StatelessWidget {
  const SearchFilters({
    required this.viewModel,
    required this.availableSources,
    required this.availableParticipants,
    required this.availableTags,
    required this.participantName,
    required this.onFilterChanged,
    required this.onClearFilters,
    required this.onSaveSearch,
    required this.isBusy,
    super.key,
  });

  /// View model containing search state.
  final SearchViewModel viewModel;

  /// List of available source filters.
  final List<String> availableSources;

  /// List of available participant IDs for filtering.
  final List<String> availableParticipants;

  /// List of available tags for filtering.
  final List<String> availableTags;

  /// Function to resolve participant ID to display name.
  final String Function(String id) participantName;

  /// Callback invoked when any filter changes.
  final VoidCallback onFilterChanged;

  /// Callback invoked when clear filters button is pressed.
  final VoidCallback onClearFilters;

  /// Callback invoked when save search button is pressed.
  final VoidCallback onSaveSearch;

  /// Whether the app is currently busy (affects button states).
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _FilterDropdown(
                label: 'Source',
                value: viewModel.sourceFilter,
                items: availableSources,
                onChanged: (value) {
                  viewModel.sourceFilter = value;
                  onFilterChanged();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _WhenFilter(
                from: viewModel.fromFilter,
                to: viewModel.toFilter,
                onChanged: (from, to) {
                  viewModel.fromFilter = from;
                  viewModel.toFilter = to;
                  onFilterChanged();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _FilterDropdown(
                label: 'Participant',
                value: viewModel.participantFilter,
                items: availableParticipants,
                itemLabel: participantName,
                searchable: true,
                onChanged: (value) {
                  viewModel.participantFilter = value;
                  onFilterChanged();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _FilterDropdown(
                label: 'Tag',
                value: viewModel.tagFilter,
                items: availableTags,
                searchable: true,
                onChanged: (value) {
                  viewModel.tagFilter = value;
                  onFilterChanged();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilterChip(
              key: const Key('search-hide-consumed'),
              avatar: const Icon(Icons.visibility_off_outlined, size: 18),
              label: const Text('Hide consumed media'),
              selected: viewModel.hideConsumed,
              onSelected: (value) {
                viewModel.hideConsumed = value;
                onFilterChanged();
              },
            ),
            OutlinedButton.icon(
              onPressed: onClearFilters,
              icon: const Icon(Icons.filter_alt_off_outlined),
              label: const Text('Clear'),
            ),
            FilledButton.icon(
              onPressed: isBusy ? null : onSaveSearch,
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('Save search'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Selects a filter, optionally searching its display labels before selection.
class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.itemLabel,
    this.searchable = false,
  });

  final String label;
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;
  final String Function(String value)? itemLabel;
  final bool searchable;

  String _label(String item) =>
      item.isEmpty ? 'All' : itemLabel?.call(item) ?? item;

  Future<void> _pick(BuildContext context) async {
    var query = '';
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final matches = items
              .where((item) => _label(item).toLowerCase().contains(query))
              .toList();
          return AlertDialog(
            title: Text('Select ${label.toLowerCase()}'),
            content: SizedBox(
              width: 400,
              height: 360,
              child: Column(
                children: [
                  TextField(
                    key: const Key('search-filter-query'),
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Search ${label.toLowerCase()}s',
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (text) =>
                        setState(() => query = text.trim().toLowerCase()),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: matches.length + 1,
                      itemBuilder: (context, index) {
                        final item = index == 0 ? '' : matches[index - 1];
                        return ListTile(
                          key: ValueKey('filter-option-$item'),
                          title: Text(_label(item)),
                          selected: item == value,
                          onTap: () => Navigator.pop(context, item),
                        );
                      },
                    ),
                  ),
                  if (matches.isEmpty) const Text('No matches'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
    if (selected != null && context.mounted) onChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final selectedValue = items.contains(value) ? value : '';
    final decoration = InputDecoration(
      labelText: label,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: const OutlineInputBorder(),
    );
    if (searchable) {
      return Semantics(
        button: true,
        child: InkWell(
          key: ValueKey('search-${label.toLowerCase()}-filter'),
          onTap: () => _pick(context),
          child: InputDecorator(
            decoration: decoration,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _label(selectedValue),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.search, size: 20),
              ],
            ),
          ),
        ),
      );
    }
    return DropdownButtonFormField<String>(
      key: ValueKey('$label-$selectedValue-${items.length}'),
      initialValue: selectedValue,
      isExpanded: true,
      decoration: decoration,
      items: [
        const DropdownMenuItem(value: '', child: Text('All')),
        for (final item in items)
          DropdownMenuItem(
            value: item,
            child: Text(_label(item), overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (nextValue) => onChanged(nextValue ?? ''),
    );
  }
}

/// Quick presets offered by the "When" date-range control.
enum _WhenPreset { today, last7Days, last30Days, thisYear, lastYear, custom }

/// Compact date-range filter control ("When").
///
/// Offers quick presets (Today, Last 7 days, Last 30 days, This year, Last
/// year) plus a "Custom range…" option backed by [showDateRangePicker]. The
/// active range (if any) is shown directly on the control, with a small
/// clear button to reset it.
class _WhenFilter extends StatelessWidget {
  const _WhenFilter({
    required this.from,
    required this.to,
    required this.onChanged,
  });

  /// Inclusive start of the active range, or null.
  final DateTime? from;

  /// Inclusive end of the active range, or null.
  final DateTime? to;

  /// Called with the new (from, to) pair whenever the range changes or is
  /// cleared.
  final void Function(DateTime? from, DateTime? to) onChanged;

  bool get _hasRange => from != null || to != null;

  String get _valueLabel {
    if (!_hasRange) return 'Any time';
    final fromLabel = from == null ? '…' : from!.toCompactLocalDateString();
    final toLabel = to == null ? '…' : to!.toCompactLocalDateString();
    return '$fromLabel – $toLabel';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: PopupMenuButton<_WhenPreset>(
            key: const Key('search-when-filter'),
            tooltip: _hasRange ? _valueLabel : 'Filter by date',
            onSelected: (preset) => _applyPreset(context, preset),
            itemBuilder: (context) => const [
              PopupMenuItem(value: _WhenPreset.today, child: Text('Today')),
              PopupMenuItem(
                value: _WhenPreset.last7Days,
                child: Text('Last 7 days'),
              ),
              PopupMenuItem(
                value: _WhenPreset.last30Days,
                child: Text('Last 30 days'),
              ),
              PopupMenuItem(
                value: _WhenPreset.thisYear,
                child: Text('This year'),
              ),
              PopupMenuItem(
                value: _WhenPreset.lastYear,
                child: Text('Last year'),
              ),
              PopupMenuItem(
                value: _WhenPreset.custom,
                child: Text('Custom range…'),
              ),
            ],
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'When',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_month_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_valueLabel, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_hasRange)
          IconButton(
            key: const Key('search-when-clear'),
            tooltip: 'Clear date range',
            icon: const Icon(Icons.close),
            onPressed: () => onChanged(null, null),
          ),
      ],
    );
  }

  Future<void> _applyPreset(BuildContext context, _WhenPreset preset) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (preset) {
      case _WhenPreset.today:
        onChanged(today, today);
      case _WhenPreset.last7Days:
        onChanged(today.subtract(const Duration(days: 6)), today);
      case _WhenPreset.last30Days:
        onChanged(today.subtract(const Duration(days: 29)), today);
      case _WhenPreset.thisYear:
        onChanged(DateTime(today.year, 1, 1), today);
      case _WhenPreset.lastYear:
        onChanged(
          DateTime(today.year - 1, 1, 1),
          DateTime(today.year - 1, 12, 31),
        );
      case _WhenPreset.custom:
        final initialRange = from != null && to != null
            ? DateTimeRange(start: from!, end: to!)
            : DateTimeRange(
                start: today.subtract(const Duration(days: 6)),
                end: today,
              );
        final picked = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2000),
          lastDate: DateTime(today.year + 1, 12, 31),
          initialDateRange: initialRange,
        );
        if (picked != null) {
          onChanged(picked.start, picked.end);
        }
    }
  }
}
