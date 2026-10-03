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

  double score({
    required DateTime documentTime,
    required String conversationId,
    bool Function(String)? haystackContains,
    bool? haystackHasNormalizedQuery,
    required bool useVector,
  }) {
    final age = math.max(0.0, now.difference(documentTime).inHours / 24);
    final freshness = math.exp(-age / 180);
    if (normalizedQuery.isEmpty) return freshness * 2;
    final continuation =
        TemporalIntent.referencesPrevious(normalizedQuery) &&
            lastSearchTopIds.contains(conversationId)
        ? 1.0
        : 0.0;
    return freshness +
        (temporalIntent?.alignmentScore(documentTime) ?? 0) +
        continuation;
  }

  bool shouldCarryPreviousQuery(
    List<String> previousTokens,
    List<String> currentTokens,
  ) {
    return previousTokens.isNotEmpty &&
        TemporalIntent.referencesPrevious(normalizedQuery);
  }
}
