import 'package:flutter_test/flutter_test.dart';

import 'package:app/app_state.dart';
import 'package:app/models.dart';

Conversation _conv({
  required String id,
  required String title,
  String source = 'manual',
  List<String> tags = const [],
  List<ConversationSegment> segments = const [],
  DateTime? at,
}) {
  return Conversation(
    id: id,
    title: title,
    source: source,
    participantIds: const [],
    tags: tags,
    segments: segments,
    startedAt: at ?? DateTime.utc(2026, 1, 1),
    endedAt: at ?? DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('relevance priorities', () {
    test('prefers same time last year when query asks for it', () {
      final state = LifenizerAppState();
      final now = DateTime.now().toUtc();
      final lastYear = _safeLastYear(now);

      state.conversations.addAll([
        _conv(
          id: 'last-year',
          title: 'Importer retrospective',
          segments: [ConversationSegment(id: 's1', text: 'Importer status')],
          at: lastYear,
        ),
        _conv(
          id: 'recent',
          title: 'Importer retrospective',
          segments: [ConversationSegment(id: 's2', text: 'Importer status')],
          at: now.subtract(const Duration(days: 2)),
        ),
      ]);

      final hits = state.search('importer same time last year');
      expect(hits, hasLength(2));
      expect(hits.first.id, 'last-year');
    });

    test('can reuse last search context with carryover phrase', () {
      final state = LifenizerAppState();
      state.conversations.addAll([
        _conv(
          id: 'atlas',
          title: 'Project Atlas timeline',
          segments: [
            ConversationSegment(id: 's1', text: 'Atlas importer roadmap'),
          ],
        ),
        _conv(
          id: 'zeus',
          title: 'Project Zeus timeline',
          segments: [
            ConversationSegment(id: 's2', text: 'Zeus importer roadmap'),
          ],
        ),
      ]);

      final first = state.search('atlas importer roadmap');
      expect(first.first.id, 'atlas');

      final followUp = state.search('same as before timeline');
      expect(followUp.first.id, 'atlas');
    });
  });

  group('indexed search', () {
    test('picks up conversations added after first query', () {
      final state = LifenizerAppState();
      state.conversations.add(_conv(id: 'a', title: 'First entry'));

      expect(state.search('second'), isEmpty);

      state.conversations.add(_conv(id: 'b', title: 'Second entry'));
      final hits = state.search('second');
      expect(hits.map((item) => item.id), ['b']);
    });

    test('vector scoring can be toggled', () {
      final state = LifenizerAppState();
      state.conversations.addAll([
        _conv(
          id: 'a',
          title: 'Importer plan',
          segments: [
            ConversationSegment(
              id: 's1',
              text: 'search index plan with importer coverage',
            ),
          ],
        ),
        _conv(
          id: 'b',
          title: 'Importer plan plan plan',
          segments: [
            ConversationSegment(id: 's2', text: 'index tuning and ranking'),
          ],
        ),
      ]);

      final lexical = state.search('importer plan', useVector: false);
      final vector = state.search('importer plan', useVector: true);

      expect(lexical, hasLength(2));
      expect(vector, hasLength(2));
      expect(
        vector.map((item) => item.id).toSet(),
        equals(lexical.map((item) => item.id).toSet()),
      );
    });
  });

  group('fuzzy search', () {
    test('matches with single-character typo', () {
      final state = LifenizerAppState();
      state.conversations.add(_conv(id: 'a', title: 'Insurance policy'));

      // "polcy" → 1 edit away from "policy"
      final hits = state.search('polcy');
      expect(hits, hasLength(1));
      expect(hits.first.id, 'a');
    });

    test('matches longer tokens within 2 edits', () {
      final state = LifenizerAppState();
      state.conversations.add(_conv(id: 'a', title: 'September minutes'));

      final hits = state.search('Septmbr');
      expect(hits, hasLength(1));
    });

    test('rejects unrelated terms', () {
      final state = LifenizerAppState();
      state.conversations.add(_conv(id: 'a', title: 'Insurance policy'));

      final hits = state.search('banana');
      expect(hits, isEmpty);
    });

    test('all query tokens must match', () {
      final state = LifenizerAppState();
      state.conversations.addAll([
        _conv(id: 'a', title: 'Insurance policy'),
        _conv(id: 'b', title: 'Vehicle insurance renewal'),
      ]);

      final hits = state.search('insurance vehicle');
      expect(hits.map((c) => c.id), ['b']);
    });

    test('short tokens require substring match', () {
      final state = LifenizerAppState();
      state.conversations.add(_conv(id: 'a', title: 'Receipts only'));

      // "xy" is too short for fuzzy to kick in
      final hits = state.search('xy');
      expect(hits, isEmpty);
    });
  });

  group('searchPaged', () {
    LifenizerAppState buildState(int total) {
      final state = LifenizerAppState();
      for (var i = 0; i < total; i++) {
        state.conversations.add(
          _conv(
            id: 'c-$i',
            title: 'Note $i',
            at: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
          ),
        );
      }
      return state;
    }

    test('returns the first page by default', () {
      final state = buildState(25);
      final page = state.searchPaged('Note');

      expect(page.page, 1);
      expect(page.pageSize, 10);
      expect(page.total, 25);
      expect(page.items, hasLength(10));
      expect(page.totalPages, 3);
      expect(page.hasPrevious, isFalse);
      expect(page.hasNext, isTrue);
    });

    test('returns subsequent pages', () {
      final state = buildState(25);

      final second = state.searchPaged('Note', page: 2);
      expect(second.items, hasLength(10));
      expect(second.hasPrevious, isTrue);
      expect(second.hasNext, isTrue);

      final last = state.searchPaged('Note', page: 3);
      expect(last.items, hasLength(5));
      expect(last.hasNext, isFalse);
    });

    test('clamps out-of-range pages to empty slice with total preserved', () {
      final state = buildState(5);

      final page = state.searchPaged('Note', page: 99, pageSize: 2);
      expect(page.items, isEmpty);
      expect(page.total, 5);
      expect(page.page, 99);
    });

    test('respects custom pageSize', () {
      final state = buildState(12);

      final page = state.searchPaged('Note', pageSize: 5);
      expect(page.items, hasLength(5));
      expect(page.totalPages, 3);
    });
  });
}

DateTime _safeLastYear(DateTime now) {
  final targetYear = now.year - 1;
  final lastDay = DateTime.utc(targetYear, now.month + 1, 0).day;
  final day = now.day > lastDay ? lastDay : now.day;
  return DateTime.utc(targetYear, now.month, day, now.hour);
}
