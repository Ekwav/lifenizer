import 'package:flutter/material.dart';
import '../../models.dart';
import 'search_input_field.dart';

/// Filter controls widget for search page.
///
/// Displays three filter dropdowns (source, participant, tag), along with
/// clear and save search buttons. Triggers [onFilterChanged] when any filter
/// is modified.
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
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        SizedBox(
          width: 220,
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
        SizedBox(
          width: 260,
          child: _FilterDropdown(
            label: 'Participant',
            value: viewModel.participantFilter,
            items: availableParticipants,
            itemLabel: participantName,
            onChanged: (value) {
              viewModel.participantFilter = value;
              onFilterChanged();
            },
          ),
        ),
        SizedBox(
          width: 220,
          child: _FilterDropdown(
            label: 'Tag',
            value: viewModel.tagFilter,
            items: availableTags,
            onChanged: (value) {
              viewModel.tagFilter = value;
              onFilterChanged();
            },
          ),
        ),
        _WhenFilter(
          from: viewModel.fromFilter,
          to: viewModel.toFilter,
          onChanged: (from, to) {
            viewModel.fromFilter = from;
            viewModel.toFilter = to;
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
    );
  }
}

/// Reusable dropdown widget for filtering.
///
/// Displays a dropdown with "All" as the first option, followed by
/// the provided items. Optionally transforms item display names using [itemLabel].
class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.itemLabel,
  });

  final String label;
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;
  final String Function(String value)? itemLabel;

  @override
  Widget build(BuildContext context) {
    final selectedValue = items.contains(value) ? value : '';
    return DropdownButtonFormField<String>(
      key: ValueKey('$label-$selectedValue-${items.length}'),
      initialValue: selectedValue,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: '', child: Text('All')),
        for (final item in items)
          DropdownMenuItem(
            value: item,
            child: Text(itemLabel?.call(item) ?? item),
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
    return SizedBox(
      width: 240,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: PopupMenuButton<_WhenPreset>(
              key: const Key('search-when-filter'),
              tooltip: 'Filter by date',
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
      ),
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
