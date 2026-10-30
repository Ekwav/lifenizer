import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';
import 'package:app/services/search_source_groups.dart';
import 'package:flutter_test/flutter_test.dart';

const _sources = {
  SearchSourceGroup.consumed: [
    'youtube-watch-history',
    'tiktok-watch-history',
    'youtube-transcript',
    'browser-history',
    'google-search-history',
    'bookmarks',
    'browser-capture',
  ],
  SearchSourceGroup.documents: ['scanned-pdf', 'paperless', 'photo'],
  SearchSourceGroup.email: ['email', 'imap', 'mbox'],
  SearchSourceGroup.chat: [
    'discord',
    'slack',
    'teams',
    'whatsapp',
    'telegram',
    'signal',
    'facebook-messenger',
    'instagram',
    'imessage',
    'sms',
  ],
  SearchSourceGroup.other: ['manual-text', 'live-recording', 'git', 'unknown'],
};

void main() {
  test(
    'known import sources share logical groups and preserve raw filters',
    () {
      for (final entry in _sources.entries) {
        final filter = sourceGroupFilter(entry.key);
        expect(groupFromSourceFilter(filter), entry.key);
        for (final source in entry.value) {
          expect(groupForSource(source), entry.key, reason: source);
          expect(groupForSource(' ${source.toUpperCase()} '), entry.key);
          expect(matchesSourceFilter(filter, source), isTrue);
          expect(
            SearchCriteria(query: '', source: filter).matchesSource(source),
            isTrue,
          );
          expect(matchesSourceFilter(source, source), isTrue);
          expect(matchesSourceFilter(source.toUpperCase(), source), isFalse);
          expect(matchesSourceFilter(null, source), isTrue);
          expect(sourceFilterLabel(source), source);
        }
      }
      expect(groupFromSourceFilter('group:unknown'), isNull);
      expect(groupFromSourceFilter(null), isNull);
      expect(
        SearchCriteria(query: '', source: ' ').matchesSource('email'),
        isTrue,
      );
      expect(matchesSourceFilter('group:email', 'discord'), isFalse);
    },
  );

  test('logical source filters agree between indexed and fallback search', () {
    final previousLimit = LifenizerAppState.synchronousIndexLimit;
    LifenizerAppState.synchronousIndexLimit = 0;
    addTearDown(() => LifenizerAppState.synchronousIndexLimit = previousLimit);
    final now = DateTime.utc(2026, 10, 28);
    final conversations = [
      for (final source in _sources.values.expand((sources) => sources))
        Conversation(
          id: source,
          title: 'Archive',
          source: source,
          participantIds: const [],
          startedAt: now,
          endedAt: now,
          segments: [ConversationSegment(id: '$source-body', text: 'archive')],
        ),
    ];
    final state = LifenizerAppState()..conversations.addAll(conversations);
    addTearDown(state.dispose);
    final service = SearchService(
      ConversationSearchIndex.build(
        conversations: conversations,
        participantById: const {},
        relationTextByConversation: const {},
      ),
    );
    for (final filter in [
      for (final group in SearchSourceGroup.values) sourceGroupFilter(group),
      'email',
      'discord',
      'scanned-pdf',
    ]) {
      final expected = conversations
          .where((c) => matchesSourceFilter(filter, c.source))
          .map((c) => c.id);
      for (final query in ['', 'archive']) {
        final criteria = SearchCriteria(query: query, source: filter);
        final found = service.rankConversations(
          criteria,
          SearchScorer(temporalIntent: null, normalizedQuery: query, now: now),
          ConversationSearchIndex.tokenize(query),
          query,
        );
        expect(
          found.map((c) => c.id),
          unorderedEquals(expected),
          reason: '$filter $query',
        );
        expect(
          state.search(query, source: filter).map((c) => c.id),
          unorderedEquals(expected),
          reason: 'fallback $filter $query',
        );
      }
    }
    expect(
      state.search('archive', source: 'group:consumed', includeConsumed: false),
      isEmpty,
    );
    expect(
      state.search('archive', source: 'group:email', includeConsumed: false),
      hasLength(3),
    );
    expect(state.fullSearchBuilds, 0);
  });
}
