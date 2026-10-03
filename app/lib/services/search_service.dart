import 'search_criteria.dart';
import 'search_scorer.dart';
import 'string_distance_service.dart';

/// Collects coarse-grained timing data for search ranking stages.
class SearchRankProfile {
  Duration candidateLookupTime = Duration.zero;
  Duration filteringAndScoringTime = Duration.zero;
  Duration sortingTime = Duration.zero;
  int candidateCount = 0;
  int matchedCount = 0;
}

/// Helper class for pairing a conversation with its computed score.
class _ScoredItem {
  const _ScoredItem({required this.conversation, required this.score});

  final dynamic conversation;
  final double score;
}

/// Service that orchestrates conversation search, filtering, and ranking.
///
/// Encapsulates the core search loop, applying filters and scoring to produce
/// a ranked list of conversations matching the search criteria.
class SearchService {
  /// Creates a [SearchService] for the given conversation search index.
  SearchService(this._searchIndex);

  final dynamic _searchIndex;

  /// Ranks conversations according to search criteria and scorer.
  ///
  /// This method:
  /// 1. Looks up candidate conversations from the inverted index
  /// 2. Applies source, participant, tag, and favorites filters
  /// 3. Scores remaining conversations using lexical, vector, temporal, and
  ///    continuity signals
  /// 4. Sorts by score (descending) and then by recency
  ///
  /// Parameters:
  /// - [criteria]: Search parameters (query, filters, flags)
  /// - [scorer]: Scoring instance with session context
  /// - [effectiveTokens]: Query tokens (may include carried-over tokens)
  /// - [semanticQuery]: Whitespace-joined query tokens for phrase matching
  ///
  /// Returns: Sorted list of matching conversations
  List rankConversations(
    SearchCriteria criteria,
    SearchScorer scorer,
    List<String> effectiveTokens,
    String semanticQuery, {
    SearchRankProfile? profile,
    int? maxResults,
  }) {
    final lookupStopwatch = Stopwatch()..start();
    final candidateIds = _searchIndex.lookupCandidates(effectiveTokens);
    lookupStopwatch.stop();

    profile?.candidateLookupTime = lookupStopwatch.elapsed;
    profile?.candidateCount = candidateIds.length;

    final scoringStopwatch = Stopwatch()..start();
    final scored = <_ScoredItem>[];

    final hasSemanticQuery = semanticQuery.isNotEmpty;
    final sourceFilter = criteria.normalizedSource;
    final participantFilter = criteria.normalizedParticipantId;
    final tagFilter = criteria.normalizedTag;
    final fromFilter = criteria.normalizedFrom;
    final toFilter = criteria.normalizedTo;
    final hasDateRange = fromFilter != null || toFilter != null;

    for (final conversationId in candidateIds) {
      final document = _searchIndex.documents[conversationId];
      if (document == null) continue;

      final conversation = document.conversation;

      // Apply filters
      if (sourceFilter != null && conversation.source != sourceFilter) {
        continue;
      }
      if (participantFilter != null &&
          !conversation.participantIds.contains(participantFilter)) {
        continue;
      }
      if (tagFilter != null && !document.tagSet.contains(tagFilter)) {
        continue;
      }
      if (criteria.favoritesOnly && !conversation.isFavorite) {
        continue;
      }
      if (hasDateRange &&
          !_matchesDateRange(conversation, fromFilter, toFilter)) {
        continue;
      }

      // Score the conversation
      var score = 0.0;
      if (!criteria.isEmptyQuery) {
        // Semantic matching gate: ensure basic relevance
        if (hasSemanticQuery &&
            !document.haystack.contains(semanticQuery) &&
            !_fuzzyMatch(semanticQuery, document.haystack)) {
          continue;
        }

        // Lexical and vector scoring from the index
        score += _searchIndex.lexicalScore(
          document,
          semanticQuery,
          effectiveTokens,
        );
        if (criteria.useVector) {
          score += _searchIndex.vectorScore(document, effectiveTokens) * 2.5;
        }

        // Temporal, continuity, and frequency boosts
        score += scorer.score(
          documentTime: conversation.startedAt.toUtc(),
          conversationId: conversation.id,
          haystackHasNormalizedQuery: document.haystack.contains(
            scorer.normalizedQuery,
          ),
          useVector: criteria.useVector,
        );
      } else {
        // Empty query: timeline browsing mode
        // Use freshness scoring directly (scorer handles this for empty queries)
        score += scorer.score(
          documentTime: conversation.startedAt.toUtc(),
          conversationId: conversation.id,
          haystackHasNormalizedQuery: false,
          useVector: false,
        );
      }

      scored.add(_ScoredItem(conversation: conversation, score: score));
    }
    scoringStopwatch.stop();
    profile?.filteringAndScoringTime = scoringStopwatch.elapsed;
    profile?.matchedCount = scored.length;

    // Sort by score descending, then by recency
    final sortingStopwatch = Stopwatch()..start();
    final sorted = _sortWithOptionalLimit(scored, maxResults);
    sortingStopwatch.stop();
    profile?.sortingTime = sortingStopwatch.elapsed;

    return sorted.map((item) => item.conversation).toList(growable: false);
  }

  static int _compareScoredItems(_ScoredItem left, _ScoredItem right) {
    final byScore = right.score.compareTo(left.score);
    if (byScore != 0) {
      return byScore;
    }
    return right.conversation.startedAt.compareTo(left.conversation.startedAt);
  }

  static List<_ScoredItem> _sortWithOptionalLimit(
    List<_ScoredItem> scored,
    int? maxResults,
  ) {
    if (maxResults == null || maxResults <= 0 || scored.length <= maxResults) {
      scored.sort(_compareScoredItems);
      return scored;
    }

    // Keep only top-N entries while scanning to avoid sorting very large tails.
    final topN = <_ScoredItem>[];
    for (final item in scored) {
      if (topN.length < maxResults) {
        _insertSorted(topN, item);
        continue;
      }

      if (_compareScoredItems(item, topN.last) >= 0) {
        continue;
      }

      topN.removeLast();
      _insertSorted(topN, item);
    }

    return topN;
  }

  static void _insertSorted(List<_ScoredItem> list, _ScoredItem item) {
    var low = 0;
    var high = list.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_compareScoredItems(item, list[mid]) < 0) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    list.insert(low, item);
  }

  /// Returns true when [conversation]'s time span overlaps the inclusive
  /// UTC range [from]..[to] (either bound may be null/open-ended).
  ///
  /// The conversation's time span is [startedAt, endedAt]. Those fields are
  /// always populated (they default to "now" when a conversation is
  /// created), so a usable timestamp always exists on the model as it
  /// stands today; conversations imported with real historical per-message
  /// timestamps have their startedAt/endedAt derived from segment
  /// createdAt values at ingestion time (see
  /// LifenizerAppState._ingestNormalizedImport), which is where the
  /// "segment createdAt" fallback described for this filter actually takes
  /// effect.
  bool _matchesDateRange(dynamic conversation, DateTime? from, DateTime? to) {
    final DateTime startedAt = conversation.startedAt.toUtc();
    final DateTime endedAt = conversation.endedAt.toUtc();
    final spanStart = startedAt.isBefore(endedAt) ? startedAt : endedAt;
    final spanEnd = startedAt.isAfter(endedAt) ? startedAt : endedAt;

    if (from != null && spanEnd.isBefore(from)) {
      return false;
    }
    if (to != null && spanStart.isAfter(to)) {
      return false;
    }
    return true;
  }

  /// Fuzzy-match every whitespace-separated token of [query] against [haystack].
  ///
  /// A token matches if:
  /// - It is a substring of any haystack token, OR
  /// - It is within Levenshtein edit distance 1 (or 2 for tokens >= 6 chars)
  ///
  /// All query tokens must match for the overall result to be true.
  bool _fuzzyMatch(String query, String haystack) {
    final queryTokens = query
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    if (queryTokens.isEmpty) {
      return true;
    }
    final haystackTokens = haystack
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    if (haystackTokens.isEmpty) {
      return false;
    }
    for (final token in queryTokens) {
      if (token.length < 3) {
        if (!haystackTokens.any((candidate) => candidate.contains(token))) {
          return false;
        }
        continue;
      }
      final maxDistance = token.length >= 6 ? 2 : 1;
      final matched = haystackTokens.any((candidate) {
        if (candidate.contains(token)) {
          return true;
        }
        if ((candidate.length - token.length).abs() > maxDistance) {
          return false;
        }
        return StringDistance.levenshtein(token, candidate, maxDistance) <=
            maxDistance;
      });
      if (!matched) {
        return false;
      }
    }
    return true;
  }
}
