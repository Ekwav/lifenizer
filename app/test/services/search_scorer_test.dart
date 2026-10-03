import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/temporal_intent.dart';

void main() {
  final now = DateTime(2026, 10, 3, 12);
  double score(SearchScorer scorer, DateTime at, String id) => scorer.score(
    documentTime: at,
    conversationId: id,
    useVector: true,
    haystackHasNormalizedQuery: true,
  );
  test('unrelated and repeated queries produce identical ranking signals', () {
    final plain = SearchScorer(
      temporalIntent: null,
      normalizedQuery: 'insurance',
      now: now,
    );
    final history = SearchScorer(
      temporalIntent: null,
      normalizedQuery: 'insurance',
      now: now,
      previousQuery: 'holiday',
      lastSearchAt: now,
      lastSearchTopIds: ['old'],
      sessionQueryFrequency: {'insurance': 100},
    );
    final at = now.subtract(const Duration(days: 30));
    expect(score(history, at, 'old'), score(plain, at, 'old'));
    expect(
      history.shouldCarryPreviousQuery(['holiday'], ['insurance']),
      isFalse,
    );
    expect(
      history.shouldCarryPreviousQuery(['insurance'], ['insurance']),
      isFalse,
    );
  });
  test('only explicit continuation carries prior context', () {
    for (final query in [
      'same as before timeline',
      'previous search notes',
      'wie zuvor',
    ]) {
      final scorer = SearchScorer(
        temporalIntent: null,
        normalizedQuery: query,
        now: now,
      );
      expect(scorer.shouldCarryPreviousQuery(['atlas'], ['timeline']), isTrue);
    }
    final scorer = SearchScorer(
      temporalIntent: null,
      normalizedQuery: 'same time last year',
      now: now,
    );
    expect(scorer.shouldCarryPreviousQuery(['atlas'], []), isFalse);
  });
  test('empty query browsing favors recent conversations', () {
    final scorer = SearchScorer(
      temporalIntent: null,
      normalizedQuery: '',
      now: now,
    );
    expect(
      score(scorer, now, 'new'),
      greaterThan(score(scorer, DateTime(2020), 'old')),
    );
  });
  test('today and German heute span the local calendar day', () {
    for (final query in ['today', 'heute']) {
      final intent = TemporalIntent.tryParse(query, now.toUtc())!;
      expect(intent.targetStart.toLocal(), DateTime(2026, 10, 3));
      expect(
        intent.targetEnd.toLocal(),
        DateTime(2026, 10, 4).subtract(const Duration(microseconds: 1)),
      );
      expect(
        intent.alignmentScore(DateTime(2026, 10, 3, 23)),
        greaterThan(intent.alignmentScore(DateTime(2026, 10, 2, 23))),
      );
    }
  });
  test('last week and month use previous calendar periods', () {
    final week = TemporalIntent.tryParse('last week', now)!;
    expect(week.targetStart.toLocal(), DateTime(2026, 9, 21));
    expect(
      week.targetEnd.toLocal().add(const Duration(microseconds: 1)),
      DateTime(2026, 9, 28),
    );
    final month = TemporalIntent.tryParse('letzten monat', now)!;
    expect(month.targetStart.toLocal(), DateTime(2026, 9, 1));
    expect(
      month.targetEnd.toLocal().add(const Duration(microseconds: 1)),
      DateTime(2026, 10, 1),
    );
  });
  test(
    'control removal preserves literal topics and respects word boundaries',
    () {
      expect(
        TemporalIntent.lexicalQuery('time travel year search'),
        'time travel year search',
      );
      expect(
        TemporalIntent.lexicalQuery('insurance today morning'),
        'insurance',
      );
      expect(
        TemporalIntent.lexicalQuery('insurance same time last year'),
        'insurance',
      );
      expect(TemporalIntent.lexicalQuery('today'), isEmpty);
      expect(TemporalIntent.lexicalQuery('holidaynight'), 'holidaynight');
      expect(TemporalIntent.tryParse('holidaynight', now), isNull);
    },
  );
  test('same time last year handles leap day', () {
    final leap = TemporalIntent.tryParse(
      'same time last year',
      DateTime(2024, 2, 29, 12),
    )!;
    expect(leap.targetStart.toLocal(), DateTime(2023, 2, 27));
    expect(leap.targetEnd.toLocal().month, 3);
  });
}
