import 'dart:math' as math;

/// Encapsulates all search scoring logic for ranked result ordering.
///
/// This class computes relevance scores for conversations based on multiple
/// factors: lexical match, semantic vectors, temporal alignment, and search
/// continuity. Designed to be instantiated once per search and reused across
/// all document scoring.
class SearchScorer {
  /// Creates a [SearchScorer] with session-aware scoring parameters.
  ///
  /// Parameters:
  /// - [temporalIntent]: Parsed temporal query intent (e.g., "today", "last week")
  /// - [normalizedQuery]: The normalized (lowercase) search query
  /// - [now]: Current UTC time for relative computations
  /// - [previousQuery]: The last search query from this session
  /// - [lastSearchAt]: Timestamp of the last search
  /// - [lastSearchTopIds]: Top 5 conversation IDs from previous search
  /// - [sessionQueryFrequency]: Map of query -> search count in current session
  SearchScorer({
    required this.temporalIntent,
    required this.normalizedQuery,
    required this.now,
    this.previousQuery,
    this.lastSearchAt,
    this.lastSearchTopIds = const [],
    this.sessionQueryFrequency = const {},
  }) : _alignmentScore = _resolveAlignmentScore(temporalIntent),
       _currentTokens = _tokenize(normalizedQuery),
       _previousTokens = previousQuery == null
           ? const <String>[]
           : _tokenize(previousQuery),
       _recentTopConversationIds = lastSearchTopIds.toSet(),
       _queryFrequencyBoost = sessionQueryFrequency[normalizedQuery] ?? 0 {
    _initializeContinuityState();
  }

  /// Parsed temporal intent from the query (e.g., "today", "last year").
  /// This is typically a _TemporalIntent from app_state, but we keep it generic.
  final dynamic temporalIntent;

  /// The normalized search query string.
  final String normalizedQuery;

  /// Current UTC timestamp for relative calculations.
  final DateTime now;

  /// The previous search query from this session (if any).
  final String? previousQuery;

  /// Timestamp of the previous search (if any).
  final DateTime? lastSearchAt;

  /// Top conversation IDs from the previous search (first 5 results).
  final List<String> lastSearchTopIds;

  /// Query frequency counter for the current session.
  final Map<String, int> sessionQueryFrequency;

  final double Function(DateTime)? _alignmentScore;
  final List<String> _currentTokens;
  final List<String> _previousTokens;
  final Set<String> _recentTopConversationIds;
  final int _queryFrequencyBoost;
  final Map<int, double> _freshnessByHalfDayBucket = <int, double>{};

  double _continuityBaseScore = 0.0;
  double _continuityRecentScore = 0.0;
  bool _continuityEnabled = false;

  static double Function(DateTime)? _resolveAlignmentScore(dynamic intent) {
    if (intent == null) {
      return null;
    }
    return (DateTime documentTime) {
      try {
        final score = intent.alignmentScore(documentTime);
        return score is num ? score.toDouble() : 0.0;
      } catch (_) {
        return 0.0;
      }
    };
  }

  void _initializeContinuityState() {
    if (normalizedQuery.isEmpty ||
        lastSearchAt == null ||
        _currentTokens.isEmpty ||
        _previousTokens.isEmpty) {
      return;
    }

    final elapsedMinutes = now.difference(lastSearchAt!).inMinutes;
    if (elapsedMinutes > 30) {
      return;
    }

    final previousTokenSet = _previousTokens.toSet();
    final currentTokenSet = _currentTokens.toSet();
    if (previousTokenSet.isEmpty || currentTokenSet.isEmpty) {
      return;
    }

    final overlap = currentTokenSet.intersection(previousTokenSet).length;
    final overlapRatio = overlap / math.max(1, currentTokenSet.length);
    final decay = math.exp(-(elapsedMinutes / 20.0));

    _continuityBaseScore = overlapRatio * 1.6 * decay;
    _continuityRecentScore = decay;
    _continuityEnabled =
        _continuityBaseScore > 0 || _recentTopConversationIds.isNotEmpty;
  }

  /// Computes a relevance score for a document based on query match quality.
  ///
  /// The score combines:
  /// - Freshness decay (for empty queries)
  /// - Temporal alignment with the query intent
  /// - Search continuity boost (related to previous query)
  /// - Session query frequency boost
  ///
  /// Note: Lexical and vector scoring are handled by the search index;
  /// this scorer focuses on session/temporal/continuity boosts.
  ///
  /// Parameters:
  /// - [documentTime]: The conversation's start time
  /// - [conversationId]: The conversation's unique identifier
  /// - [haystackContains]: Lambda to check if haystack contains normalized query
  /// - [useVector]: Whether vector scoring is enabled (for consistency)
  ///
  /// Returns: A floating-point relevance score (boost to add to base score)
  double score({
    required DateTime documentTime,
    required String conversationId,
    bool Function(String)? haystackContains,
    bool? haystackHasNormalizedQuery,
    required bool useVector,
  }) {
    if (normalizedQuery.isEmpty) {
      // Empty query: favor recency
      return _freshnessDecayScore(documentTime) * 2.0;
    }

    var totalScore = 0.0;

    // Temporal boost
    totalScore += _temporalBoost(documentTime);

    // Continuity boost
    totalScore += _continuityBoost(conversationId);

    // Frequency boost from session query history
    final containsQuery =
        haystackHasNormalizedQuery ??
        (haystackContains != null && haystackContains(normalizedQuery));
    if (_queryFrequencyBoost > 0 && containsQuery) {
      totalScore += math.min(1.2, _queryFrequencyBoost * 0.2);
    }

    return totalScore;
  }

  /// Computes temporal alignment boost based on query intent.
  ///
  /// Returns a score reflecting how well the document's timestamp aligns
  /// with the temporal query intent (e.g., "today", "same time last year").
  /// For non-temporal queries, applies freshness decay.
  double _temporalBoost(DateTime documentTime) {
    var boost = _freshnessDecayScore(documentTime) * 1.0;
    final alignmentScore = _alignmentScore;
    if (alignmentScore == null) {
      return boost;
    }
    boost += alignmentScore(documentTime);
    return boost;
  }

  /// Computes search continuity boost for related queries.
  ///
  /// If the current query is semantically related to the previous query
  /// (based on token overlap and time proximity), this method boosts the score
  /// for conversations that were in the previous result set, encouraging
  /// drill-down exploration patterns.
  double _continuityBoost(String conversationId) {
    if (!_continuityEnabled) {
      return 0;
    }
    final recentBoost = _recentTopConversationIds.contains(conversationId)
        ? _continuityRecentScore
        : 0.0;
    final score = _continuityBaseScore + recentBoost;
    if (score <= 0) {
      return 0;
    }
    return score;
  }

  /// Computes freshness decay score for timeline browsing.
  ///
  /// Implements exponential decay with a half-life of ~180 days, keeping
  /// recent items favored without completely overwhelming semantic scores.
  double _freshnessDecayScore(DateTime documentTime) {
    final ageDays = now.difference(documentTime).inHours / 24.0;
    if (ageDays <= 0) {
      return 1.0;
    }
    final bucket = now.difference(documentTime).inHours ~/ 12;
    final cached = _freshnessByHalfDayBucket[bucket];
    if (cached != null) {
      return cached;
    }
    final value = math.exp(-(ageDays / 180.0));
    _freshnessByHalfDayBucket[bucket] = value;
    return value;
  }

  /// Tokenizes text using the same logic as the search index.
  ///
  /// Splits on non-alphanumeric characters and filters empty tokens.
  static List<String> _tokenize(String text) {
    return text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
  }

  /// Determines if the previous query should carry over its tokens.
  ///
  /// Returns true if the user's query explicitly references continuity
  /// (e.g., "again", "same as before") or if a short query is issued
  /// within 5 minutes of the previous search, suggesting drill-down.
  bool shouldCarryPreviousQuery(
    List<String> previousTokens,
    List<String> currentTokens,
  ) {
    if (normalizedQuery.isEmpty || previousTokens.isEmpty) {
      return false;
    }

    // Explicit continuity hints in the query
    final hasCarryHint =
        normalizedQuery.contains('last search') ||
        normalizedQuery.contains('previous search') ||
        normalizedQuery.contains('same as before') ||
        normalizedQuery.contains('again') ||
        normalizedQuery.contains('same time');
    if (hasCarryHint) {
      return true;
    }

    // Short query within 5 minutes suggests drill-down
    if (currentTokens.length <= 2 && lastSearchAt != null) {
      final minutes = now.difference(lastSearchAt!).inMinutes;
      if (minutes <= 5) {
        return true;
      }
    }

    return false;
  }
}
