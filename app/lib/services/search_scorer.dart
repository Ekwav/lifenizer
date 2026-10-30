import 'dart:math' as math;

import 'temporal_intent.dart';

/// Recency and relative-date boosts complement lexical relevance. Previous
/// results are used only when the query explicitly requests them.
class SearchScorer {
  SearchScorer({
    required this.temporalIntent,
    required this.normalizedQuery,
    required this.now,
    this.previousQuery,
    this.lastSearchAt,
    this.lastSearchTopIds = const [],
    this.sessionQueryFrequency = const {},
  });

  final TemporalIntent? temporalIntent;
  final String normalizedQuery;
  final DateTime now;
  final String? previousQuery;
  final DateTime? lastSearchAt;
  final List<String> lastSearchTopIds;
  final Map<String, int> sessionQueryFrequency;
  late final _nowMicroseconds = now.microsecondsSinceEpoch;
  late final _referencesPrevious = TemporalIntent.referencesPrevious(
    normalizedQuery,
  );

  double score({
    required DateTime documentTime,
    required String conversationId,
    bool Function(String)? haystackContains,
    bool? haystackHasNormalizedQuery,
    required bool useVector,
  }) => scoreTimestamp(
    utcMicroseconds: documentTime.microsecondsSinceEpoch,
    previousResult:
        _referencesPrevious && lastSearchTopIds.contains(conversationId),
  );

  /// Scores packed disk-index timestamps without allocating a date per match.
  double scoreTimestamp({
    required int utcMicroseconds,
    required bool previousResult,
  }) {
    final hours =
        (_nowMicroseconds - utcMicroseconds) ~/ Duration.microsecondsPerHour;
    final age = math.max(0.0, hours / 24);
    final freshness = math.exp(-age / 180);
    if (normalizedQuery.isEmpty) return freshness * 2;
    final continuation = _referencesPrevious && previousResult ? 1.0 : 0.0;
    return freshness +
        (temporalIntent?.alignmentScore(
              DateTime.fromMicrosecondsSinceEpoch(utcMicroseconds, isUtc: true),
            ) ??
            0) +
        continuation;
  }

  bool shouldCarryPreviousQuery(
    List<String> previousTokens,
    List<String> currentTokens,
  ) {
    return previousTokens.isNotEmpty && _referencesPrevious;
  }
}
