import 'search_criteria.dart';
import 'search_scorer.dart';
import '../models.dart';
import 'conversation_search_index.dart';

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

  final Conversation conversation;
  final double score;
}

/// Service that orchestrates conversation search, filtering, and ranking.
///
/// Encapsulates the core search loop, applying filters and scoring to produce
/// a ranked list of conversations matching the search criteria.
class SearchService {
  /// Creates a [SearchService] for the given conversation search index.
  SearchService(this._searchIndex);

  final ConversationSearchIndex _searchIndex;

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
  List<Conversation> rankConversations(
    SearchCriteria criteria,
    SearchScorer scorer,
    List<String> effectiveTokens,
    String semanticQuery, {
    SearchRankProfile? profile,
    int? maxResults,
  }) {
    final lookupStopwatch = Stopwatch()..start();
    final expansions = _searchIndex.expandTokens(effectiveTokens);
    final candidateIds = _searchIndex.lookupCandidates(
      effectiveTokens,
      expansions: expansions,
    );
    lookupStopwatch.stop();

    profile?.candidateLookupTime = lookupStopwatch.elapsed;
    profile?.candidateCount = candidateIds.length;

    final scoringStopwatch = Stopwatch()..start();
    final scored = <_ScoredItem>[];

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
        // Lexical and vector scoring from the index
        score += _searchIndex.lexicalScore(
          document,
          semanticQuery,
          effectiveTokens,
          expansions: expansions,
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
    final byDate = right.conversation.startedAt.compareTo(
      left.conversation.startedAt,
    );
    return byDate != 0
        ? byDate
        : left.conversation.id.compareTo(right.conversation.id);
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
  bool _matchesDateRange(
    Conversation conversation,
    DateTime? from,
    DateTime? to,
  ) {
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
}
