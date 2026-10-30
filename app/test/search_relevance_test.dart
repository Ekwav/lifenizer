import 'dart:io';

import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/search_relevance_fixtures.dart';

final _now = DateTime.utc(2026, 10, 28, 12);
final _fixture = SearchRelevanceFixture(_now);
final _people = _fixture.participantById;

Conversation _document(
  String id,
  String title,
  String body, {
  String source = 'signal',
  int daysAgo = 1,
}) => Conversation(
  id: id,
  title: title,
  source: source,
  participantIds: const [],
  startedAt: _now.subtract(Duration(days: daysAgo)),
  endedAt: _now.subtract(Duration(days: daysAgo)),
  segments: [ConversationSegment(id: '$id-message', text: body)],
);

// Judgments describe useful destinations, independently of either search
// implementation. Common words occur throughout the archive, and competing
// documents share topics rather than only containing unrelated random tokens.
List<Conversation> _archive() => [
  ..._fixture.conversations,
  for (var i = 0; i < 1050; i++)
    _document(
      'archive-$i',
      [
        'Weekly planning notes',
        'Software release discussion',
        'Family travel updates',
        'Equipment shopping list',
        'Monthly account statement',
      ][i % 5],
      '${List.filled(12, ['The project needs a review of the budget and the schedule.', 'Please review the project update before the next meeting.', 'Travel plans include a train journey and a workshop visit.', 'The account balance and invoice are ready for review.', 'A new battery and charger are on the shopping list.', 'Warranty coverage depends on the receipt and purchase date.', 'Insurance paperwork and renewal reminders arrived in the mail.'][i % 7]).join(' ')} Archive entry $i.',
      source: [
        'youtube-transcript',
        'paperless',
        'imap',
        'discord',
        'manual',
      ][i % 5],
      daysAgo: i % 90,
    ),
];

void main() {
  late Directory directory;
  late DiskSearchIndex disk;
  final key = List<int>.generate(32, (i) => i);
  Future<DiskSearchIndex> open() => DiskSearchIndex.open(
    path: '${directory.path}/relevance.sqlite',
    vaultKey: key,
  );
  Future<List<String>> search(SearchCriteria criteria, {int limit = 8}) async {
    final tokens = ConversationSearchIndex.tokenize(criteria.normalized);
    return (await disk.search(
      criteria,
      SearchScorer(
        temporalIntent: null,
        normalizedQuery: criteria.normalized,
        now: _now,
      ),
      tokens,
      tokens.join(' '),
      maxResults: limit,
    )).map((doc) => doc.id).toList();
  }

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('search-relevance-');
    disk = await open();
    await disk.upsert(
      _archive(),
      participantById: _people,
      relationTextByConversation: const {},
    );
  });
  tearDownAll(() async {
    await disk.close();
    await directory.delete(recursive: true);
  });

  final judgments = _fixture.judgments.where((judgment) => !judgment.heldOut);
  Future<void> verify(SearchRelevanceJudgment judgment) async {
    final hits = await search(judgment.criteria);
    final compared = judgment.requireExactResults
        ? hits
        : hits.take(judgment.expectedTopIds.length);
    expect(
      compared,
      judgment.unordered
          ? unorderedEquals(judgment.expectedTopIds)
          : orderedEquals(judgment.expectedTopIds),
      reason: '${judgment.label}: $hits',
    );
    for (final excluded in judgment.excludedIds) {
      expect(hits, isNot(contains(excluded)), reason: judgment.label);
    }
  }

  for (final judgment in judgments) {
    test(judgment.label, () => verify(judgment));
  }

  test(
    'in-memory ranking also protects common exact titles from rare prefixes',
    () {
      final index = ConversationSearchIndex.build(
        conversations: _archive(),
        participantById: _people,
        relationTextByConversation: const {},
      );
      for (final vector in [true, false]) {
        final results = SearchService(index).rankConversations(
          SearchCriteria(query: 'project', useVector: vector),
          SearchScorer(
            temporalIntent: null,
            normalizedQuery: 'project',
            now: _now,
          ),
          ['project'],
          'project',
          maxResults: 2,
        );
        expect(
          results.map((doc) => doc.id),
          unorderedEquals(['budget-decision', 'budget-bob']),
        );
      }
    },
  );

  test(
    'strict term coverage and filters do not fill results with near misses',
    () async {
      final visible = await search(
        SearchCriteria(query: 'project budget', includeConsumed: false),
        limit: 100,
      );
      expect(visible.first, 'budget-decision');
      expect(visible, isNot(contains('budget-video')));
      expect(
        visible
            .where((id) => id.startsWith('archive-'))
            .map((id) => int.parse(id.substring('archive-'.length)) % 5),
        everyElement(isNot(0)),
      );
    },
  );

  test('ties, top limits and reopening preserve relevance order', () async {
    final criteria = SearchCriteria(query: 'observatory reservation');
    const expected = ['tie-a', 'tie-b', 'tie-c', 'tie-older'];
    expect(await search(criteria), expected);
    expect(await search(criteria, limit: 2), expected.take(2));
    final before = await search(SearchCriteria(query: 'project budget'));
    await search(SearchCriteria(query: 'insurance'));
    expect(await search(SearchCriteria(query: 'project budget')), before);
    await disk.close();
    disk = await open();
    expect(await search(criteria), expected);
    expect(await search(SearchCriteria(query: 'project budget')), before);
    for (final judgment in judgments) {
      await verify(judgment);
    }
  });

  test(
    'held-out topic surfaces after incremental indexing and replacement',
    () async {
      // This distinct topic is absent from the judged fixture set at initial
      // build. Each word already has many background hits in separate records.
      await disk.upsert(
        _fixture.heldOutConversations,
        participantById: _people,
        relationTextByConversation: const {},
      );
      for (final judgment in _fixture.judgments.where((j) => j.heldOut)) {
        await verify(judgment);
      }
      await disk.upsert(
        [
          _document(
            'battery-claim',
            'Bicycle collection',
            'Ready on Friday.',
            source: 'email',
          ),
        ],
        participantById: _people,
        relationTextByConversation: const {},
      );
      expect(await search(SearchCriteria(query: 'battery warranty')), [
        'battery-receipt',
        'battery-review',
      ]);
    },
  );
}
