/// Encapsulates search parameters and provides computed properties.
///
/// This class normalizes and validates search criteria, reducing parameter
/// passing throughout the search pipeline.
class SearchCriteria {
  /// Creates a [SearchCriteria] with the given search parameters.
  SearchCriteria({
    required String query,
    this.source,
    this.participantId,
    this.tag,
    this.favoritesOnly = false,
    this.useVector = true,
    this.from,
    this.to,
  }) : _query = query;

  final String _query;
  final String? source;
  final String? participantId;
  final String? tag;
  final bool favoritesOnly;
  final bool useVector;

  /// Inclusive start of an optional date-range filter (calendar date, as
  /// picked by the user in their local timezone).
  final DateTime? from;

  /// Inclusive end of an optional date-range filter (calendar date, as
  /// picked by the user in their local timezone). Treated as end-of-day.
  final DateTime? to;

  /// Returns the normalized (trimmed, lowercase) query.
  String get normalized => _query.trim().toLowerCase();

  /// Returns the normalized source filter, or null if empty/invalid.
  String? get normalizedSource => _cleanFilter(source);

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
      'from=$normalizedFrom, to=$normalizedTo)';
}
