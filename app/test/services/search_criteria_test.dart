import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/search_criteria.dart';

void main() {
  group('SearchCriteria', () {
    group('query normalization', () {
      test('converts query to lowercase', () {
        final criteria = SearchCriteria(query: 'HELLO World');
        expect(criteria.normalized, 'hello world');
      });

      test('trims whitespace from query', () {
        final criteria = SearchCriteria(query: '  hello world  ');
        expect(criteria.normalized, 'hello world');
      });

      test('handles multiple spaces', () {
        final criteria = SearchCriteria(query: 'hello   world');
        expect(criteria.normalized, 'hello   world');
      });

      test('empty query after normalization', () {
        final criteria = SearchCriteria(query: '   ');
        expect(criteria.normalized, '');
      });

      test('preserves special characters in query', () {
        final criteria = SearchCriteria(query: 'email@example.com');
        expect(criteria.normalized, 'email@example.com');
      });

      test('handles unicode correctly', () {
        final criteria = SearchCriteria(query: 'Café');
        expect(criteria.normalized, 'café');
      });

      test('real-world query examples', () {
        final criteria1 = SearchCriteria(query: 'Project Alpha');
        expect(criteria1.normalized, 'project alpha');

        final criteria2 = SearchCriteria(query: '2024 Q4 Planning');
        expect(criteria2.normalized, '2024 q4 planning');
      });
    });

    group('filter normalization', () {
      test('source filter is trimmed but case-sensitive', () {
        final criteria = SearchCriteria(query: 'test', source: '  GMAIL  ');
        expect(criteria.normalizedSource, 'GMAIL');
      });

      test('trims source filter whitespace', () {
        final criteria = SearchCriteria(query: 'test', source: '  slack  ');
        expect(criteria.normalizedSource, 'slack');
      });

      test('returns null for empty source', () {
        final criteria = SearchCriteria(query: 'test', source: '   ');
        expect(criteria.normalizedSource, isNull);
      });

      test('participantId filter is trimmed but case-sensitive', () {
        final criteria = SearchCriteria(
          query: 'test',
          participantId: '  USER123  ',
        );
        expect(criteria.normalizedParticipantId, 'USER123');
      });

      test('returns null for null participantId', () {
        final criteria = SearchCriteria(query: 'test', participantId: null);
        expect(criteria.normalizedParticipantId, isNull);
      });

      test('normalizes tag filter to lowercase', () {
        final criteria = SearchCriteria(query: 'test', tag: 'IMPORTANT');
        expect(criteria.normalizedTag, 'important');
      });

      test('trims tag filter whitespace', () {
        final criteria = SearchCriteria(query: 'test', tag: '  work  ');
        expect(criteria.normalizedTag, 'work');
      });

      test('returns null for empty tag', () {
        final criteria = SearchCriteria(query: 'test', tag: '');
        expect(criteria.normalizedTag, isNull);
      });

      test(
        'handles mixed case filters - source and participantId are case-sensitive',
        () {
          final criteria = SearchCriteria(
            query: 'test',
            source: 'SlAcK',
            participantId: 'UsEr_123',
            tag: 'ToDo',
          );
          expect(criteria.normalizedSource, 'SlAcK');
          expect(criteria.normalizedParticipantId, 'UsEr_123');
          expect(criteria.normalizedTag, 'todo');
        },
      );
    });

    group('flags and options', () {
      test('defaults favoritesOnly to false', () {
        final criteria = SearchCriteria(query: 'test');
        expect(criteria.favoritesOnly, false);
      });

      test('can set favoritesOnly to true', () {
        final criteria = SearchCriteria(query: 'test', favoritesOnly: true);
        expect(criteria.favoritesOnly, true);
      });

      test('defaults useVector to true', () {
        final criteria = SearchCriteria(query: 'test');
        expect(criteria.useVector, true);
      });

      test('can disable vector scoring', () {
        final criteria = SearchCriteria(query: 'test', useVector: false);
        expect(criteria.useVector, false);
      });

      test('combines multiple flags', () {
        final criteria = SearchCriteria(
          query: 'test',
          favoritesOnly: true,
          useVector: false,
        );
        expect(criteria.favoritesOnly, true);
        expect(criteria.useVector, false);
      });
    });

    group('isEmptyQuery property', () {
      test('returns true for empty query string', () {
        final criteria = SearchCriteria(query: '');
        expect(criteria.isEmptyQuery, true);
      });

      test('returns true for whitespace-only query', () {
        final criteria = SearchCriteria(query: '   ');
        expect(criteria.isEmptyQuery, true);
      });

      test('returns false for non-empty query', () {
        final criteria = SearchCriteria(query: 'hello');
        expect(criteria.isEmptyQuery, false);
      });

      test('returns false for query with content after trim', () {
        final criteria = SearchCriteria(query: '  test  ');
        expect(criteria.isEmptyQuery, false);
      });

      test('timeline browsing mode with filters', () {
        final criteria = SearchCriteria(
          query: '  ',
          source: 'gmail',
          favoritesOnly: true,
        );
        expect(criteria.isEmptyQuery, true);
        expect(criteria.normalizedSource, 'gmail');
      });
    });

    group('filter validation', () {
      test('null filters remain null', () {
        final criteria = SearchCriteria(
          query: 'test',
          source: null,
          participantId: null,
          tag: null,
        );
        expect(criteria.normalizedSource, isNull);
        expect(criteria.normalizedParticipantId, isNull);
        expect(criteria.normalizedTag, isNull);
      });

      test('combining filters with query', () {
        final criteria = SearchCriteria(
          query: 'MEETING',
          source: 'ZOOM',
          participantId: 'USER_A',
          tag: 'IMPORTANT',
          favoritesOnly: true,
        );
        expect(criteria.normalized, 'meeting');
        expect(criteria.normalizedSource, 'ZOOM');
        expect(criteria.normalizedParticipantId, 'USER_A');
        expect(criteria.normalizedTag, 'important');
        expect(criteria.favoritesOnly, true);
      });

      test('partial filters: only source', () {
        final criteria = SearchCriteria(query: 'test', source: 'slack');
        expect(criteria.normalizedSource, 'slack');
        expect(criteria.normalizedParticipantId, isNull);
        expect(criteria.normalizedTag, isNull);
      });

      test('partial filters: only tag', () {
        final criteria = SearchCriteria(query: 'test', tag: 'urgent');
        expect(criteria.normalizedSource, isNull);
        expect(criteria.normalizedParticipantId, isNull);
        expect(criteria.normalizedTag, 'urgent');
      });
    });

    group('edge cases', () {
      test('query with only numbers', () {
        final criteria = SearchCriteria(query: '12345');
        expect(criteria.normalized, '12345');
        expect(criteria.isEmptyQuery, false);
      });

      test('query with special punctuation', () {
        final criteria = SearchCriteria(query: 'hello!@#\$%^&*()');
        expect(criteria.normalized, 'hello!@#\$%^&*()');
      });

      test('very long query', () {
        final longQuery =
            'this is a very long query '
            '* 10'
            '${' '}';
        final criteria = SearchCriteria(
          query:
              'this is a very long query this is a very long query this is a very long query',
        );
        expect(criteria.normalized.length, greaterThan(50));
      });

      test('query with tabs and newlines', () {
        final criteria = SearchCriteria(query: 'hello\t\nworld');
        expect(criteria.normalized, 'hello\t\nworld');
      });

      test('query with leading/trailing special chars', () {
        final criteria = SearchCriteria(query: '***test***');
        expect(criteria.normalized, '***test***');
      });

      test('filter with special characters', () {
        final criteria = SearchCriteria(
          query: 'test',
          source: 'MY-SOURCE_2024',
        );
        expect(criteria.normalizedSource, 'MY-SOURCE_2024');
      });

      test('Unicode in filters', () {
        final criteria = SearchCriteria(
          query: 'test',
          participantId: 'Für Alle',
        );
        // participantId is case-sensitive, only trimmed
        expect(criteria.normalizedParticipantId, 'Für Alle');
      });
    });

    group('toString representation', () {
      test('basic toString', () {
        final criteria = SearchCriteria(query: 'TEST');
        final str = criteria.toString();
        expect(str, contains('test'));
      });

      test('toString includes all filters', () {
        final criteria = SearchCriteria(
          query: 'test',
          source: 'slack',
          participantId: 'user123',
          tag: 'urgent',
          favoritesOnly: true,
        );
        final str = criteria.toString();
        expect(str, contains('test'));
        expect(str, contains('slack'));
        expect(str, contains('user123'));
        expect(str, contains('urgent'));
        expect(str, contains('true'));
      });

      test('toString with null filters', () {
        final criteria = SearchCriteria(query: 'test');
        final str = criteria.toString();
        expect(str.isNotEmpty, true);
      });
    });

    group('filter extraction patterns', () {
      test('extracting all filter types simultaneously', () {
        final criteria = SearchCriteria(
          query: 'project alpha 2024',
          source: 'GOOGLE_MEET',
          participantId: 'TEAM_LEAD',
          tag: 'PLANNING',
          favoritesOnly: false,
          useVector: true,
        );
        expect(criteria.normalized, 'project alpha 2024');
        expect(criteria.normalizedSource, 'GOOGLE_MEET');
        expect(criteria.normalizedParticipantId, 'TEAM_LEAD');
        expect(criteria.normalizedTag, 'planning');
        expect(criteria.favoritesOnly, false);
        expect(criteria.useVector, true);
      });

      test('handling missing optional filters', () {
        final criteria = SearchCriteria(
          query: 'simple search',
          // source, participantId, tag all default to null
        );
        expect(criteria.normalized, 'simple search');
        expect(criteria.normalizedSource, isNull);
        expect(criteria.normalizedParticipantId, isNull);
        expect(criteria.normalizedTag, isNull);
      });

      test('multiline query handling', () {
        final criteria = SearchCriteria(query: 'line1\nline2\nline3');
        expect(criteria.normalized, 'line1\nline2\nline3');
      });
    });

    group('consistency checks', () {
      test('repeated access returns same value', () {
        final criteria = SearchCriteria(query: 'TEST');
        expect(criteria.normalized, 'test');
        expect(criteria.normalized, 'test');
      });

      test('isEmptyQuery is consistent', () {
        final criteria = SearchCriteria(query: '   ');
        expect(criteria.isEmptyQuery, criteria.isEmptyQuery);
      });

      test('filter normalization is consistent', () {
        final criteria = SearchCriteria(query: 'test', source: '  SLACK  ');
        expect(criteria.normalizedSource, criteria.normalizedSource);
      });

      test('multiple instances are independent', () {
        final c1 = SearchCriteria(query: 'TEST1', source: 'SOURCE1');
        final c2 = SearchCriteria(query: 'test2', source: 'source2');
        expect(c1.normalized, 'test1');
        expect(c2.normalized, 'test2');
        expect(c1.normalizedSource, 'SOURCE1');
        expect(c2.normalizedSource, 'source2');
      });
    });

    group('date range filter', () {
      test('from/to default to null and hasDateRange is false', () {
        final criteria = SearchCriteria(query: 'test');
        expect(criteria.normalizedFrom, isNull);
        expect(criteria.normalizedTo, isNull);
        expect(criteria.hasDateRange, isFalse);
      });

      test('hasDateRange is true when only from is set', () {
        final criteria = SearchCriteria(
          query: 'test',
          from: DateTime(2026, 3, 1),
        );
        expect(criteria.hasDateRange, isTrue);
        expect(criteria.normalizedTo, isNull);
      });

      test('hasDateRange is true when only to is set', () {
        final criteria = SearchCriteria(
          query: 'test',
          to: DateTime(2026, 3, 1),
        );
        expect(criteria.hasDateRange, isTrue);
        expect(criteria.normalizedFrom, isNull);
      });

      test('normalizedFrom snaps to local midnight, then converts to UTC', () {
        final local = DateTime(2026, 3, 14, 15, 30);
        final criteria = SearchCriteria(query: 'test', from: local);
        final expectedLocalMidnight = DateTime(2026, 3, 14);
        expect(criteria.normalizedFrom, expectedLocalMidnight.toUtc());
        expect(criteria.normalizedFrom!.isUtc, isTrue);
      });

      test(
        'normalizedTo snaps to the last millisecond of the local day, then '
        'converts to UTC (a date given as "to" is treated as end-of-day)',
        () {
          final local = DateTime(2026, 3, 14, 9);
          final criteria = SearchCriteria(query: 'test', to: local);
          final expectedLocalEndOfDay = DateTime(2026, 3, 14, 23, 59, 59, 999);
          expect(criteria.normalizedTo, expectedLocalEndOfDay.toUtc());
          expect(criteria.normalizedTo!.isUtc, isTrue);
        },
      );

      test('a single-day range still spans the whole day (from == to)', () {
        final day = DateTime(2026, 3, 14);
        final criteria = SearchCriteria(query: 'test', from: day, to: day);
        expect(
          criteria.normalizedTo!.difference(criteria.normalizedFrom!).inHours,
          greaterThanOrEqualTo(23),
        );
      });
    });
  });
}
