import 'package:flutter_test/flutter_test.dart';
import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';

final now = DateTime.utc(2026, 10, 3, 12);
Conversation conversation(
  String id,
  String title, {
  String text = '',
  List<String> people = const [],
  DateTime? at,
}) => Conversation(
  id: id,
  title: title,
  source: 'manual',
  participantIds: people,
  startedAt: at ?? now,
  endedAt: at ?? now,
  segments: [ConversationSegment(id: '$id-segment', text: text)],
);
ConversationSearchIndex index(
  List<Conversation> items, {
  Map<String, String> people = const {},
}) => ConversationSearchIndex.build(
  conversations: items,
  participantById: people,
  relationTextByConversation: const {},
);
List<String> search(
  ConversationSearchIndex index,
  String query, {
  int? maxResults,
  SearchRankProfile? profile,
}) {
  final tokens = ConversationSearchIndex.tokenize(query);
  return SearchService(index)
      .rankConversations(
        SearchCriteria(query: query),
        SearchScorer(temporalIntent: null, normalizedQuery: query, now: now),
        tokens,
        tokens.join(' '),
        maxResults: maxResults,
        profile: profile,
      )
      .map((conversation) => conversation.id)
      .toList();
}

void main() {
  test('exact tokens retain prefix names; short words exclude typo noise', () {
    final vault = index(
      [
        conversation('name', 'Review', people: ['alice']),
        conversation('exact', 'Ali'),
        conversation('partial', 'Alignment'),
        conversation('noise', 'All'),
      ],
      people: {'alice': 'Alice'},
    );
    final hits = search(vault, 'ali');
    expect(hits, containsAll(['exact', 'name', 'partial']));
    expect(hits.first, 'exact');
    expect(hits, isNot(contains('noise')));
  });
  test('Unicode and accent-insensitive multilingual names', () {
    final vault = index(
      [
        conversation('german', 'Versicherung', people: ['p']),
        conversation('japanese', '東京 旅行'),
        conversation('french', 'Café résumé'),
      ],
      people: {'p': 'Jörg Müller'},
    );
    expect(search(vault, 'Jorg Muller'), ['german']);
    expect(search(vault, 'Joerg Muell'), ['german']);
    expect(search(vault, '東京'), ['japanese']);
    expect(search(vault, 'cafe resume'), ['french']);
  });
  test('all topic and person terms are required even with typos', () {
    final vault = index(
      [
        conversation('alice', 'Insurance renewal', people: ['a']),
        conversation('bob', 'Insurance renewal', people: ['b']),
        conversation('holiday', 'Holiday planning', people: ['a']),
      ],
      people: {'a': 'Alice', 'b': 'Bob'},
    );
    expect(search(vault, 'insuranc alice'), ['alice']);
    expect(search(vault, 'insurance banana'), isEmpty);
  });
  test(
    'titles and actual participants outrank repetitive transcript mentions',
    () {
      final vault = index(
        [
          conversation('title', 'Insurance renewal'),
          conversation(
            'repetition',
            'Miscellaneous',
            text: List.filled(500, 'insurance renewal').join(' '),
          ),
          conversation('participant', 'Review', people: ['a']),
          conversation('mention', 'Alice biography'),
        ],
        people: {'a': 'Alice'},
      );
      expect(search(vault, 'insurance renewal').first, 'title');
      expect(search(vault, 'alice').first, 'participant');
    },
  );
  test('exact phrase beats scattered words with equal field relevance', () {
    final vault = index([
      conversation('phrase', 'Renewal', text: 'insurance policy renewal'),
      conversation(
        'scattered',
        'Renewal',
        text: 'policy requires careful insurance review',
      ),
    ]);
    expect(search(vault, 'insurance policy').first, 'phrase');
  });
  test('top-N agrees with full ranking and results stay deterministic', () {
    final vault = index(
      List.generate(
        100,
        (i) => conversation(
          'id-${99 - i}',
          'Shared note',
          at: now.subtract(Duration(days: i ~/ 2)),
        ),
      ),
    );
    final all = search(vault, 'shared');
    expect(search(vault, 'shared', maxResults: 8), all.take(8));
    expect(search(vault, 'shared'), all);
  });
  test('10,000 conversation benchmark scores only matching candidates', () {
    final vault = index(
      List.generate(
        10000,
        (i) => conversation(
          'c$i',
          'Archive $i',
          text: i % 100 == 0 ? 'insurance renewal' : 'grocery shopping',
        ),
      ),
    );
    final profile = SearchRankProfile();
    expect(
      search(vault, 'insurance renewal', maxResults: 8, profile: profile),
      hasLength(8),
    );
    expect(profile.candidateCount, 100);
    expect(profile.matchedCount, 100);
    final miss = SearchRankProfile();
    expect(search(vault, 'zzzzunfindable', profile: miss), isEmpty);
    expect(miss.candidateCount, 0);
    expect(
      profile.filteringAndScoringTime,
      lessThan(const Duration(seconds: 5)),
    );
  });
}
