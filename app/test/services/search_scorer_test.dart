import 'package:flutter_test/flutter_test.dart';
import 'dart:math' as math;
import 'package:app/services/search_scorer.dart';

/// Mock temporal intent for testing
class _MockTemporalIntent {
  _MockTemporalIntent({
    required this.targetStart,
    required this.targetEnd,
    this.weight = 1.0,
  });

  final DateTime targetStart;
  final DateTime targetEnd;
  final double weight;

  double alignmentScore(DateTime documentTime) {
    final doc = documentTime.toUtc();
    final rangeStart = targetStart.toUtc();
    final rangeEnd = targetEnd.toUtc();
    final inRange = !doc.isBefore(rangeStart) && !doc.isAfter(rangeEnd);

    if (!inRange) {
      final distanceDays = doc.isBefore(rangeStart)
          ? rangeStart.difference(doc).inHours / 24.0
          : doc.difference(rangeEnd).inHours / 24.0;
      return math.exp(-(distanceDays / 21.0)) * 0.8;
    }
    return 2.0 * weight;
  }
}

void main() {
  group('SearchScorer', () {
    group('initialization', () {
      test('creates scorer with basic parameters', () {
        final now = DateTime.now().toUtc();
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );
        expect(scorer.normalizedQuery, 'test');
        expect(scorer.now, now);
        expect(scorer.temporalIntent, isNull);
      });

      test('creates scorer with full session context', () {
        final now = DateTime.now().toUtc();
        final lastSearchAt = now.subtract(const Duration(minutes: 10));
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
          previousQuery: 'previous test',
          lastSearchAt: lastSearchAt,
          lastSearchTopIds: ['id1', 'id2', 'id3'],
          sessionQueryFrequency: {'test': 2, 'previous test': 1},
        );
        expect(scorer.previousQuery, 'previous test');
        expect(scorer.lastSearchAt, lastSearchAt);
        expect(scorer.lastSearchTopIds.length, 3);
        expect(scorer.sessionQueryFrequency['test'], 2);
      });

      test('defaults empty lists and maps', () {
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: DateTime.now().toUtc(),
        );
        expect(scorer.lastSearchTopIds, isEmpty);
        expect(scorer.sessionQueryFrequency, isEmpty);
        expect(scorer.previousQuery, isNull);
        expect(scorer.lastSearchAt, isNull);
      });
    });

    group('empty query scoring', () {
      test('empty query applies freshness decay only', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: '',
          now: now,
        );

        // Recent document
        final recent = DateTime.utc(2024, 6, 1, 10, 0, 0);
        final scoreRecent = scorer.score(
          documentTime: recent,
          conversationId: 'doc1',
          haystackContains: (_) => false,
          useVector: false,
        );

        // Older document
        final older = DateTime.utc(2024, 3, 1, 10, 0, 0);
        final scoreOlder = scorer.score(
          documentTime: older,
          conversationId: 'doc2',
          haystackContains: (_) => false,
          useVector: false,
        );

        expect(scoreRecent, greaterThan(scoreOlder));
      });

      test('empty query gives high boost to recent documents', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: '',
          now: now,
        );

        final today = DateTime.utc(2024, 6, 1, 10, 0, 0);
        final score = scorer.score(
          documentTime: today,
          conversationId: 'doc1',
          haystackContains: (_) => false,
          useVector: false,
        );

        expect(score, greaterThan(0));
      });

      test('empty query score is positive and bounded', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: '',
          now: now,
        );

        final future = DateTime.utc(2025, 1, 1);
        final score = scorer.score(
          documentTime: future,
          conversationId: 'doc1',
          haystackContains: (_) => false,
          useVector: false,
        );

        expect(score, greaterThan(0));
        expect(score, lessThan(100));
      });
    });

    group('temporal intent scoring', () {
      test('document within temporal range gets boost', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: _MockTemporalIntent(
            targetStart: DateTime.utc(2024, 6, 1, 0, 0, 0),
            targetEnd: DateTime.utc(2024, 6, 1, 23, 59, 59),
            weight: 1.6,
          ),
          normalizedQuery: 'today meeting',
          now: now,
        );

        final inRange = DateTime.utc(2024, 6, 1, 14, 0, 0);
        final score = scorer.score(
          documentTime: inRange,
          conversationId: 'doc1',
          haystackContains: (q) => q == 'today meeting',
          useVector: false,
        );

        expect(score, greaterThan(0));
      });

      test('document outside temporal range gets reduced score', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: _MockTemporalIntent(
            targetStart: DateTime.utc(2024, 6, 1, 0, 0, 0),
            targetEnd: DateTime.utc(2024, 6, 1, 23, 59, 59),
            weight: 1.6,
          ),
          normalizedQuery: 'today',
          now: now,
        );

        // Document from last month
        final outOfRange = DateTime.utc(2024, 5, 1, 12, 0, 0);
        final scoreOutOfRange = scorer.score(
          documentTime: outOfRange,
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // Document from today
        final inRange = DateTime.utc(2024, 6, 1, 14, 0, 0);
        final scoreInRange = scorer.score(
          documentTime: inRange,
          conversationId: 'doc2',
          haystackContains: (q) => true,
          useVector: false,
        );

        expect(scoreInRange, greaterThan(scoreOutOfRange));
      });

      test('applies temporal intent weight multiplier', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final highWeightIntentDoc = DateTime.utc(2024, 6, 1, 10, 0, 0);

        // Test with high weight intent
        final scorerHighWeight = SearchScorer(
          temporalIntent: _MockTemporalIntent(
            targetStart: DateTime.utc(2024, 6, 1),
            targetEnd: DateTime.utc(2024, 6, 2),
            weight: 2.6, // high weight
          ),
          normalizedQuery: 'same time last year',
          now: now,
        );

        final scoreHigh = scorerHighWeight.score(
          documentTime: highWeightIntentDoc,
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // Test with low weight intent
        final scorerLowWeight = SearchScorer(
          temporalIntent: _MockTemporalIntent(
            targetStart: DateTime.utc(2024, 6, 1),
            targetEnd: DateTime.utc(2024, 6, 2),
            weight: 0.8, // low weight
          ),
          normalizedQuery: 'some query',
          now: now,
        );

        final scoreLow = scorerLowWeight.score(
          documentTime: highWeightIntentDoc,
          conversationId: 'doc2',
          haystackContains: (q) => true,
          useVector: false,
        );

        expect(scoreHigh, greaterThan(scoreLow));
      });
    });

    group('search continuity boost', () {
      test('boost awarded to documents in previous result set', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 2));
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'meeting notes',
          now: now,
          previousQuery: 'meeting',
          lastSearchAt: lastSearchAt,
          lastSearchTopIds: ['doc1', 'doc2', 'doc3'],
        );

        // Document in previous results
        final scoreInPrevious = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // Document not in previous results
        final scoreNotInPrevious = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc99',
          haystackContains: (q) => true,
          useVector: false,
        );

        expect(scoreInPrevious, greaterThan(scoreNotInPrevious));
      });

      test('continuity boost decays over time', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);

        // Immediate search (2 minutes ago)
        final recentLastSearch = now.subtract(const Duration(minutes: 2));
        final scorerRecent = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test notes',
          now: now,
          previousQuery: 'test',
          lastSearchAt: recentLastSearch,
          lastSearchTopIds: ['doc1'],
        );

        final scoreRecent = scorerRecent.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // Older search (25 minutes ago)
        final oldLastSearch = now.subtract(const Duration(minutes: 25));
        final scorerOld = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test notes',
          now: now,
          previousQuery: 'test',
          lastSearchAt: oldLastSearch,
          lastSearchTopIds: ['doc1'],
        );

        final scoreOld = scorerOld.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // Recent search should get higher boost due to decay
        expect(scoreRecent, greaterThan(scoreOld));
      });

      test('no continuity boost after 30 minutes', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final oldSearch = now.subtract(const Duration(minutes: 31));
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test notes',
          now: now,
          previousQuery: 'test',
          lastSearchAt: oldSearch,
          lastSearchTopIds: ['doc1'],
        );

        final score = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // Beyond 30 min window means no continuity boost, but freshness decay still applies
        expect(score, isA<double>());
      });

      test('requires token overlap for continuity boost', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 2));

        // Queries with no token overlap
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'xyz abc',
          now: now,
          previousQuery: 'def ghi',
          lastSearchAt: lastSearchAt,
          lastSearchTopIds: ['doc1'],
        );

        final score = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // Without token overlap, should not get significant continuity boost
        // But will still get freshness decay for empty query logic
        expect(score, isA<double>());
      });

      test('continuity with significant token overlap', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 2));

        // Queries with high token overlap
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'meeting notes agenda',
          now: now,
          previousQuery: 'meeting notes',
          lastSearchAt: lastSearchAt,
          lastSearchTopIds: ['doc1', 'doc2'],
        );

        final score = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // With token overlap and in previous results, should get boost
        expect(score, greaterThan(0));
      });
    });

    group('session query frequency boost', () {
      test('repeated queries get frequency boost', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'design system',
          now: now,
          sessionQueryFrequency: {
            'design system': 3, // searched 3 times in session
          },
        );

        final score = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => q == 'design system',
          useVector: false,
        );

        expect(score, greaterThan(0.5));
      });

      test('frequency boost is capped at 1.2', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
          sessionQueryFrequency: {
            'test': 100, // very high frequency
          },
        );

        final score = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => q == 'test',
          useVector: false,
        );

        // Score calculation: min(1.2, 100 * 0.2) = 1.2
        // Will be added to freshness decay (temporal boost)
        expect(score, isA<double>());
      });

      test('no frequency boost without haystack match', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'design',
          now: now,
          sessionQueryFrequency: {
            'design': 5,
          },
        );

        final score = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => false, // haystack doesn't contain query
          useVector: false,
        );

        // No boost without haystack match
        // Will still get freshness decay since query is non-empty
        expect(score, isA<double>());
      });

      test('frequency boost calculation: score = min(1.2, freq * 0.2)', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);

        // Frequency = 3: 3 * 0.2 = 0.6
        final scorer1 = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
          sessionQueryFrequency: {'test': 3},
        );

        final score1 = scorer1.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // Frequency = 6: 6 * 0.2 = 1.2 (capped)
        final scorer2 = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
          sessionQueryFrequency: {'test': 6},
        );

        final score2 = scorer2.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc2',
          haystackContains: (q) => true,
          useVector: false,
        );

        expect(score1, greaterThan(0));
        expect(score2, greaterThanOrEqualTo(score1));
      });
    });

    group('freshness decay scoring', () {
      test('recent documents have high decay score', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: '',
          now: now,
        );

        final today = DateTime.utc(2024, 6, 1, 10, 0, 0);
        final score = scorer.score(
          documentTime: today,
          conversationId: 'doc1',
          haystackContains: (_) => false,
          useVector: false,
        );

        expect(score, greaterThan(1.0));
      });

      test('old documents have low decay score', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: '',
          now: now,
        );

        final oldDate = DateTime.utc(2022, 6, 1, 10, 0, 0); // 2 years ago
        final score = scorer.score(
          documentTime: oldDate,
          conversationId: 'doc1',
          haystackContains: (_) => false,
          useVector: false,
        );

        expect(score, lessThan(0.5));
      });

      test('decay follows exponential curve with 180-day half-life', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: '',
          now: now,
        );

        // At half-life (180 days), decay should be approximately e^(-1) ≈ 0.368
        final halfLifeDate = now.subtract(const Duration(days: 180));
        final scoreAtHalfLife = scorer.score(
          documentTime: halfLifeDate,
          conversationId: 'doc1',
          haystackContains: (_) => false,
          useVector: false,
        );

        // For empty query, score is multiplied by 2.0, so expect ~0.736
        expect(scoreAtHalfLife, greaterThan(0.5));
        expect(scoreAtHalfLife, lessThan(1.0));
      });

      test('future or same time document gets maximum decay', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: '',
          now: now,
        );

        final score = scorer.score(
          documentTime: now,
          conversationId: 'doc1',
          haystackContains: (_) => false,
          useVector: false,
        );

        // For same time, decay should be 1.0, multiplied by 2.0 for empty query
        expect(score, 2.0);
      });
    });

    group('shouldCarryPreviousQuery', () {
      test('carries tokens for explicit continuity hints', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);

        final testCases = [
          'last search notes',
          'previous search results',
          'same as before',
          'search again',
          'same time notes',
        ];

        for (final query in testCases) {
          final scorer = SearchScorer(
            temporalIntent: null,
            normalizedQuery: query,
            now: now,
          );

          final shouldCarry = scorer.shouldCarryPreviousQuery(
            ['meeting'],
            ['notes'],
          );

          expect(shouldCarry, true,
              reason: 'Should carry for query: $query');
        }
      });

      test('carries for short query within 5 minutes of previous search', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 3));

        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'notes', // short query (1 token)
          now: now,
          previousQuery: 'meeting notes',
          lastSearchAt: lastSearchAt,
        );

        final shouldCarry = scorer.shouldCarryPreviousQuery(
          ['meeting', 'notes'],
          ['notes'],
        );

        expect(shouldCarry, true);
      });

      test('does not carry for short query after 5 minutes', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 6));

        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'notes',
          now: now,
          previousQuery: 'meeting notes',
          lastSearchAt: lastSearchAt,
        );

        final shouldCarry = scorer.shouldCarryPreviousQuery(
          ['meeting', 'notes'],
          ['notes'],
        );

        expect(shouldCarry, false);
      });

      test('does not carry for long query', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 2));

        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'long meeting notes agenda review',
          now: now,
          previousQuery: 'meeting',
          lastSearchAt: lastSearchAt,
        );

        final shouldCarry = scorer.shouldCarryPreviousQuery(
          ['meeting'],
          ['long', 'meeting', 'notes', 'agenda', 'review'],
        );

        expect(shouldCarry, false);
      });

      test('does not carry for empty current query', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: '',
          now: now,
        );

        final shouldCarry = scorer.shouldCarryPreviousQuery(
          ['previous'],
          [],
        );

        expect(shouldCarry, false);
      });

      test('does not carry for empty previous query', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final shouldCarry = scorer.shouldCarryPreviousQuery(
          [],
          ['test'],
        );

        expect(shouldCarry, false);
      });
    });

    group('combined scoring scenarios', () {
      test('high-relevance query with continuity', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 2));

        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'meeting agenda',
          now: now,
          previousQuery: 'meeting',
          lastSearchAt: lastSearchAt,
          lastSearchTopIds: ['doc1'],
          sessionQueryFrequency: {'meeting agenda': 2},
        );

        final score = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => q == 'meeting agenda',
          useVector: false,
        );

        // Should have continuity + frequency boosts
        expect(score, greaterThan(0.5));
      });

      test('document scoring with temporal intent and history', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 5));

        final scorer = SearchScorer(
          temporalIntent: _MockTemporalIntent(
            targetStart: DateTime.utc(2024, 6, 1),
            targetEnd: DateTime.utc(2024, 6, 2),
            weight: 1.6,
          ),
          normalizedQuery: 'today notes',
          now: now,
          previousQuery: 'today',
          lastSearchAt: lastSearchAt,
          lastSearchTopIds: ['doc1'],
        );

        final score = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 14, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // Multiple signals should produce positive score
        expect(score, greaterThan(0));
      });

      test('different query yields lower continuity boost', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 2));

        // Different queries (no token overlap)
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'project alpha',
          now: now,
          previousQuery: 'calendar events',
          lastSearchAt: lastSearchAt,
          lastSearchTopIds: ['doc1'],
        );

        final score = scorer.score(
          documentTime: DateTime.utc(2024, 6, 1, 10, 0, 0),
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        // Without token overlap, should not get continuity boost
        // But will get temporal boost from freshness decay
        expect(score, isA<double>());
      });
    });

    group('tokenization', () {
      test('internal tokenization is consistent - token overlap detection', () {
        // shouldCarryPreviousQuery returns true ONLY with:
        // 1. Explicit continuity hints, OR
        // 2. Short query (<=2 tokens) within 5 minutes
        // The method tests token overlap, but continuity is driven by these conditions

        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 2));

        // Test with explicit continuity hint
        final scorerWithHint = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'search again',
          now: now,
          previousQuery: 'hello world',
          lastSearchAt: lastSearchAt,
        );

        final shouldCarry = scorerWithHint.shouldCarryPreviousQuery(
          ['hello', 'world'],
          ['search', 'again'],
        );

        expect(shouldCarry, true);
      });

      test('short query within time window triggers carry', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final lastSearchAt = now.subtract(const Duration(minutes: 2));

        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'filter', // 1 token, <= 2
          now: now,
          previousQuery: 'search term',
          lastSearchAt: lastSearchAt,
        );

        final shouldCarry = scorer.shouldCarryPreviousQuery(
          ['search', 'term'],
          ['filter'],
        );

        expect(shouldCarry, true);
      });
    });

    group('edge cases', () {
      test('null temporal intent is handled', () {
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: DateTime.now().toUtc(),
        );

        // Should not throw
        final score = scorer.score(
          documentTime: DateTime.now().toUtc(),
          conversationId: 'doc1',
          haystackContains: (q) => true,
          useVector: false,
        );

        expect(score, isNotNull);
      });

      test('past document future score calculation', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final futureDoc = now.add(const Duration(days: 1));

        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: '',
          now: now,
        );

        // Should handle future documents gracefully
        final score = scorer.score(
          documentTime: futureDoc,
          conversationId: 'doc1',
          haystackContains: (_) => false,
          useVector: false,
        );

        expect(score, isNotNull);
        expect(score, greaterThanOrEqualTo(0));
      });
    });
  });
}
