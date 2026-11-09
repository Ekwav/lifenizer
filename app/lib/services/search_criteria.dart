import '../models.dart';
import 'conversation_search_index.dart';
import 'search_source_groups.dart';

/// Encapsulates search parameters and provides computed properties.
///
/// This class normalizes and validates search criteria, reducing parameter
/// passing throughout the search pipeline.
class SearchCriteria {
  /// Creates a [SearchCriteria] with the given search parameters.
  SearchCriteria({
    required this._query,
    this.source,
    this.participantId,
    this.tag,
    this.location,
    this.favoritesOnly = false,
    this.useVector = true,
    this.from,
    this.to,
    this.includeConsumed = true,
  });

  final String _query;
  final String? source;
  final String? participantId;
  final String? tag;
  final String? location;
  final bool favoritesOnly;
  final bool useVector;

  /// When false, consumed media (watch/browsing history) is filtered out.
  final bool includeConsumed;

  /// Inclusive start of an optional date-range filter (calendar date, as
  /// picked by the user in their local timezone).
  final DateTime? from;

  /// Inclusive end of an optional date-range filter (calendar date, as
  /// picked by the user in their local timezone). Treated as end-of-day.
  final DateTime? to;

  static final _locationPattern = RegExp(
    r'(?:^|\s)(town|location):(?:"([^"]+)"(?=\s|$)|([^\s"]+)(?=\s|$))',
    caseSensitive: false,
  );

  static String withoutLocationFilters(String query) =>
      query.replaceAll(_locationPattern, ' ').trim();

  /// Lexical query after explicit location filters have been removed.
  String get normalized => withoutLocationFilters(_query).toLowerCase();

  List<String> get locationLabels => [
    if (_cleanFilter(location) case final String value) value,
    for (final match in _locationPattern.allMatches(_query))
      match.group(2) ?? match.group(3)!,
  ];

  late final _locationFilters = [
    if (_cleanFilter(location) case final String value)
      (townOnly: false, tokens: ConversationSearchIndex.tokenize(value)),
    for (final match in _locationPattern.allMatches(_query))
      (
        townOnly: match.group(1)!.toLowerCase() == 'town',
        tokens: ConversationSearchIndex.tokenize(
          match.group(2) ?? match.group(3)!,
        ),
      ),
  ];

  bool matchesLocation(RecordingLocation? value) =>
      _locationFilters.every((filter) {
        if (value == null) return false;
        final words = ConversationSearchIndex.tokenize(
          filter.townOnly ? value.town : value.searchableText,
        );
        return filter.tokens.every(
          (token) => words.any((word) => word.startsWith(token)),
        );
      });

  /// Returns the normalized source filter, or null if empty/invalid.
  String? get normalizedSource => _cleanFilter(source);

  bool matchesSource(String actualSource) =>
      matchesSourceFilter(normalizedSource, actualSource);

  /// Returns the normalized participant ID filter, or null if empty/invalid.
  String? get normalizedParticipantId => _cleanFilter(participantId);

  /// Returns the normalized tag filter (lowercase), or null if empty/invalid.
  String? get normalizedTag => _cleanFilter(tag)?.toLowerCase();

  /// Returns true if this is an empty query (timeline browsing mode).
  bool get isEmptyQuery => normalized.isEmpty;

  /// The inclusive range start, normalized for comparison against stored
  /// (UTC) conversation timestamps.
  ///
  /// [from] is treated as a calendar date picked in the user's local
  /// timezone (e.g. from a date-range picker or a quick preset like "Last 7
  /// days"), so it is snapped to local midnight before converting to UTC.
  /// Conversation timestamps are always stored as UTC internally (see
  /// [DateTimeSerializationX] in models.dart), so comparing in UTC keeps the
  /// filter consistent regardless of where the query originates.
  DateTime? get normalizedFrom {
    final value = from;
    if (value == null) return null;
    final local = value.isUtc ? value.toLocal() : value;
    return DateTime(local.year, local.month, local.day).toUtc();
  }

  /// The inclusive range end, normalized the same way as [normalizedFrom]
  /// but snapped to the last millisecond of the local calendar day, so a
  /// single-day range still captures every conversation from that day.
  DateTime? get normalizedTo {
    final value = to;
    if (value == null) return null;
    final local = value.isUtc ? value.toLocal() : value;
    return DateTime(
      local.year,
      local.month,
      local.day,
      23,
      59,
      59,
      999,
    ).toUtc();
  }

  /// True when either end of the date-range filter is set.
  bool get hasDateRange => from != null || to != null;

  /// Cleans a filter value by trimming and returning null if empty.
  static String? _cleanFilter(String? value) {
    final cleaned = value?.trim();
    return cleaned == null || cleaned.isEmpty ? null : cleaned;
  }

  @override
  String toString() =>
      'SearchCriteria(query=$normalized, source=$normalizedSource, '
      'participantId=$normalizedParticipantId, tag=$normalizedTag, '
      'favoritesOnly=$favoritesOnly, useVector=$useVector, '
      'from=$normalizedFrom, to=$normalizedTo, '
      'includeConsumed=$includeConsumed)';
}
