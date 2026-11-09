import 'dart:io';

import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'rare-first AND planning preserves ranking and restricts posting reads',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'search-planning-',
      );
      final disk = await DiskSearchIndex.open(
        path: '${directory.path}/search.sqlite',
        vaultKey: List.generate(32, (n) => n),
      );
      final now = DateTime.utc(2026, 10, 29);
      final docs = List.generate(
        4096,
        (n) => Conversation(
          id: 'doc-$n',
          title:
              'alignment alimony alias alike common${n == 2077 || n == 2078 ? ' mueller' : ''}',
          source: 'manual',
          participantIds: const [],
          startedAt: now.subtract(Duration(hours: n)),
          endedAt: now,
          segments: const [],
        ),
      );
      try {
        await disk.upsert(
          docs,
          participantById: const {},
          relationTextByConversation: const {},
        );
        final reference = ConversationSearchIndex.build(
          conversations: docs,
          participantById: const {},
          relationTextByConversation: const {},
        );
        Future<List<String>> check(String query) async {
          final criteria = SearchCriteria(query: query);
          final tokens = ConversationSearchIndex.tokenize(query);
          final scorer = SearchScorer(
            temporalIntent: null,
            normalizedQuery: query,
            now: now,
          );
          final expected = SearchService(reference)
              .rankConversations(
                criteria,
                scorer,
                tokens,
                tokens.join(' '),
                maxResults: 100,
              )
              .map((item) => item.id)
              .toList();
          final actual = await disk.search(
            criteria,
            scorer,
            tokens,
            tokens.join(' '),
          );
          expect(
            actual.map((item) => item.id).toList(),
            expected,
            reason: query,
          );
          return expected;
        }

        await check('ali');
        final commonReads = (await disk.searchProfile)['postingReads']!;
        expect(commonReads, greaterThan(10));
        for (final query in ['ali muell', 'muell ali']) {
          expect(await check(query), ['doc-2077', 'doc-2078']);
          final profile = await disk.searchProfile;
          // One rare posting page, then four common expansions on that page.
          expect(profile['postingReads'], 5, reason: query);
          expect(profile['postingReads'], lessThan(commonReads));
        }
        // A dead dictionary entry must not affect cost planning or intersections.
        await disk.remove(['doc-2077', 'doc-2078']);
        final criteria = SearchCriteria(query: 'ali muell');
        expect(
          await disk.search(
            criteria,
            SearchScorer(
              temporalIntent: null,
              normalizedQuery: criteria.normalized,
              now: now,
            ),
            ['ali', 'muell'],
            'ali muell',
          ),
          isEmpty,
        );
      } finally {
        await disk.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
