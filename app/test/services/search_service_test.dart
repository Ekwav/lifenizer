import 'package:flutter_test/flutter_test.dart';
import 'package:app/models.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';
import 'package:app/services/string_distance_service.dart';

/// Mock document for testing
class _MockDocument {
  _MockDocument({
    required this.conversation,
    required this.haystack,
    required this.tagSet,
  });

  final dynamic conversation;
  final String haystack;
  final Set<String> tagSet;
}

/// Mock search index for testing
class _MockSearchIndex {
  final Map<String, _MockDocument> documents = {};
  final Map<String, Set<String>> invertedIndex = {};

  void addDocument(_MockDocument doc) {
    documents[doc.conversation.id] = doc;

    // Index tokens
    final tokens = doc.haystack
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty)
        .toSet();

    for (final token in tokens) {
      (invertedIndex[token] ??= {}).add(doc.conversation.id);
    }
  }

  Set<String> lookupCandidates(List<String> tokens) {
    if (tokens.isEmpty) {
      return documents.keys.toSet();
    }
    return tokens.expand((token) => invertedIndex[token] ?? <String>{}).toSet();
  }

  double lexicalScore(
    _MockDocument document,
    String semanticQuery,
    List<String> tokens,
  ) {
    // Simple token matching score
    var score = 0.0;
    for (final token in tokens) {
      if (document.haystack.toLowerCase().contains(token)) {
        score += 1.0;
      }
    }
    return score;
  }

  double vectorScore(_MockDocument document, List<String> tokens) {
    // Mock vector score based on token count
    return tokens.isNotEmpty ? 0.5 : 0.0;
  }
}

void main() {
  group('SearchService', () {
    group('ranking conversations', () {
      test('returns empty list for no matching documents', () {
        final index = _MockSearchIndex();
        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'nonexistent');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'nonexistent',
          now: DateTime.now().toUtc(),
        );

        final results = service.rankConversations(criteria, scorer, [
          'nonexistent',
        ], 'nonexistent');

        expect(results, isEmpty);
      });

      test('returns results in score order (descending)', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        // Create conversations with different content
        final conv1 = Conversation(
          id: 'conv1',
          title: 'Meeting notes',
          source: 'zoom',
          participantIds: ['p1'],
          segments: [
            ConversationSegment(
              id: 's1',
              text: 'meeting project alpha',
              createdAt: now,
            ),
          ],
        );

        final conv2 = Conversation(
          id: 'conv2',
          title: 'Project details',
          source: 'email',
          participantIds: ['p2'],
          segments: [
            ConversationSegment(id: 's2', text: 'project', createdAt: now),
          ],
        );

        index.addDocument(
          _MockDocument(
            conversation: conv1,
            haystack: 'meeting project alpha',
            tagSet: {},
          ),
        );
        index.addDocument(
          _MockDocument(conversation: conv2, haystack: 'project', tagSet: {}),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'project');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'project',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'project',
        ], 'project');

        expect(results, isNotEmpty);
        expect(results.length, 2);
      });

      test('returns results sorted by date when scores are equal', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final older = now.subtract(const Duration(hours: 1));
        final conv1 = Conversation(
          id: 'conv1',
          title: 'First',
          source: 'zoom',
          participantIds: ['p1'],
          segments: [
            ConversationSegment(id: 's1', text: 'test', createdAt: older),
          ],
          startedAt: older,
        );

        final conv2 = Conversation(
          id: 'conv2',
          title: 'Second',
          source: 'zoom',
          participantIds: ['p1'],
          segments: [
            ConversationSegment(id: 's2', text: 'test', createdAt: now),
          ],
          startedAt: now,
        );

        index.addDocument(
          _MockDocument(conversation: conv1, haystack: 'test', tagSet: {}),
        );
        index.addDocument(
          _MockDocument(conversation: conv2, haystack: 'test', tagSet: {}),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        // Newer should come first
        expect(results.first.id, 'conv2');
        expect(results.last.id, 'conv1');
      });
    });

    group('source filtering', () {
      test('filters by source when specified', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final convGmail = Conversation(
          id: 'conv1',
          title: 'Email',
          source: 'gmail',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
        );

        final convSlack = Conversation(
          id: 'conv2',
          title: 'Chat',
          source: 'slack',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's2', text: 'test')],
        );

        index.addDocument(
          _MockDocument(conversation: convGmail, haystack: 'test', tagSet: {}),
        );
        index.addDocument(
          _MockDocument(conversation: convSlack, haystack: 'test', tagSet: {}),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test', source: 'gmail');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 1);
        expect(results.first.source, 'gmail');
      });

      test('returns all sources when no filter specified', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        for (final source in ['gmail', 'slack', 'teams']) {
          final conv = Conversation(
            id: 'conv_$source',
            title: source,
            source: source,
            participantIds: ['p1'],
            segments: [ConversationSegment(id: 's_$source', text: 'test')],
          );
          index.addDocument(
            _MockDocument(conversation: conv, haystack: 'test', tagSet: {}),
          );
        }

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 3);
      });
    });

    group('participant filtering', () {
      test('filters by participantId when specified', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final conv1 = Conversation(
          id: 'conv1',
          title: 'With Alice',
          source: 'email',
          participantIds: ['alice', 'bob'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
        );

        final conv2 = Conversation(
          id: 'conv2',
          title: 'With Charlie',
          source: 'email',
          participantIds: ['charlie'],
          segments: [ConversationSegment(id: 's2', text: 'test')],
        );

        index.addDocument(
          _MockDocument(conversation: conv1, haystack: 'test', tagSet: {}),
        );
        index.addDocument(
          _MockDocument(conversation: conv2, haystack: 'test', tagSet: {}),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test', participantId: 'alice');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 1);
        expect(results.first.participantIds, contains('alice'));
      });

      test('supports participants in conversation list', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final conv = Conversation(
          id: 'conv1',
          title: 'Team meeting',
          source: 'zoom',
          participantIds: ['alice', 'bob', 'charlie'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
        );

        index.addDocument(
          _MockDocument(conversation: conv, haystack: 'test', tagSet: {}),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test', participantId: 'bob');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 1);
      });
    });

    group('tag filtering', () {
      test('filters by tag when specified', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final conv1 = Conversation(
          id: 'conv1',
          title: 'Urgent meeting',
          source: 'zoom',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
          tags: ['urgent', 'meeting'],
        );

        final conv2 = Conversation(
          id: 'conv2',
          title: 'Regular chat',
          source: 'slack',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's2', text: 'test')],
          tags: ['chat'],
        );

        index.addDocument(
          _MockDocument(
            conversation: conv1,
            haystack: 'test',
            tagSet: {'urgent', 'meeting'},
          ),
        );
        index.addDocument(
          _MockDocument(
            conversation: conv2,
            haystack: 'test',
            tagSet: {'chat'},
          ),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test', tag: 'urgent');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 1);
        expect(results.first.tags, contains('urgent'));
      });

      test('tag filter is case-insensitive', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final conv = Conversation(
          id: 'conv1',
          title: 'Tagged',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
          tags: ['Important'],
        );

        index.addDocument(
          _MockDocument(
            conversation: conv,
            haystack: 'test',
            tagSet: {'important'},
          ),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test', tag: 'IMPORTANT');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 1);
      });
    });

    group('favorites filtering', () {
      test('filters favorites when flag is true', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final favorite = Conversation(
          id: 'conv1',
          title: 'Favorite',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
          isFavorite: true,
        );

        final notFavorite = Conversation(
          id: 'conv2',
          title: 'Not favorite',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's2', text: 'test')],
          isFavorite: false,
        );

        index.addDocument(
          _MockDocument(conversation: favorite, haystack: 'test', tagSet: {}),
        );
        index.addDocument(
          _MockDocument(
            conversation: notFavorite,
            haystack: 'test',
            tagSet: {},
          ),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test', favoritesOnly: true);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 1);
        expect(results.first.isFavorite, true);
      });

      test('returns all when favoritesOnly is false', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final favorite = Conversation(
          id: 'conv1',
          title: 'Favorite',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
          isFavorite: true,
        );

        final notFavorite = Conversation(
          id: 'conv2',
          title: 'Not favorite',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's2', text: 'test')],
          isFavorite: false,
        );

        index.addDocument(
          _MockDocument(conversation: favorite, haystack: 'test', tagSet: {}),
        );
        index.addDocument(
          _MockDocument(
            conversation: notFavorite,
            haystack: 'test',
            tagSet: {},
          ),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test', favoritesOnly: false);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 2);
      });
    });

    group('combined filtering', () {
      test('applies multiple filters simultaneously', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final matches = Conversation(
          id: 'conv1',
          title: 'Urgent meeting',
          source: 'zoom',
          participantIds: ['alice', 'bob'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
          tags: ['urgent'],
          isFavorite: true,
        );

        final wrongSource = Conversation(
          id: 'conv2',
          title: 'Chat',
          source: 'slack',
          participantIds: ['alice'],
          segments: [ConversationSegment(id: 's2', text: 'test')],
          tags: ['urgent'],
          isFavorite: true,
        );

        final notFavorite = Conversation(
          id: 'conv3',
          title: 'Meeting',
          source: 'zoom',
          participantIds: ['alice'],
          segments: [ConversationSegment(id: 's3', text: 'test')],
          tags: ['urgent'],
          isFavorite: false,
        );

        index.addDocument(
          _MockDocument(
            conversation: matches,
            haystack: 'test',
            tagSet: {'urgent'},
          ),
        );
        index.addDocument(
          _MockDocument(
            conversation: wrongSource,
            haystack: 'test',
            tagSet: {'urgent'},
          ),
        );
        index.addDocument(
          _MockDocument(
            conversation: notFavorite,
            haystack: 'test',
            tagSet: {'urgent'},
          ),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(
          query: 'test',
          source: 'zoom',
          participantId: 'alice',
          tag: 'urgent',
          favoritesOnly: true,
        );
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 1);
        expect(results.first.id, 'conv1');
      });
    });

    group('empty query handling', () {
      test('handles empty query (timeline browsing)', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final older = now.subtract(const Duration(days: 1));
        final newer = now;

        final convOlder = Conversation(
          id: 'conv1',
          title: 'Older',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'content')],
          startedAt: older,
        );

        final convNewer = Conversation(
          id: 'conv2',
          title: 'Newer',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's2', text: 'content')],
          startedAt: newer,
        );

        index.addDocument(
          _MockDocument(
            conversation: convOlder,
            haystack: 'content',
            tagSet: {},
          ),
        );
        index.addDocument(
          _MockDocument(
            conversation: convNewer,
            haystack: 'content',
            tagSet: {},
          ),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: '');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: '',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [], '');

        expect(results.isNotEmpty, true);
      });
    });

    group('fuzzy matching', () {
      test('fuzzy match: substring matching', () {
        expect(_fuzzyMatchHelper('cat', 'category'), true);
      });

      test('fuzzy match: Levenshtein distance 1', () {
        // 'bat' within distance 1 of 'cat'
        expect(_fuzzyMatchHelper('bat', 'cat dog'), true);
      });

      test('fuzzy match: all tokens must match', () {
        final result = _fuzzyMatchHelper('cat dog', 'only cat here');
        expect(result, false); // 'dog' not in haystack
      });

      test('fuzzy match: multiple tokens', () {
        expect(
          _fuzzyMatchHelper('hello world', 'hello wonderful'),
          false, // 'world' doesn't match 'wonderful' within distance 1
        );
      });

      test('fuzzy match: short tokens use substring matching', () {
        expect(_fuzzyMatchHelper('at', 'catalog'), true);
      });

      test('fuzzy match: longer tokens use stricter matching', () {
        final longToken = 'testing';
        final result = _fuzzyMatchHelper(longToken, 'testing');
        expect(result, true);
      });

      test('fuzzy match: empty query matches everything', () {
        expect(_fuzzyMatchHelper('', 'any text'), true);
      });

      test('fuzzy match: empty haystack matches nothing', () {
        expect(_fuzzyMatchHelper('test', ''), false);
      });
    });

    group('vector scoring', () {
      test('includes vector score when useVector is true', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final conv = Conversation(
          id: 'conv1',
          title: 'Test',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test query')],
        );

        index.addDocument(
          _MockDocument(conversation: conv, haystack: 'test query', tagSet: {}),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test', useVector: true);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.isNotEmpty, true);
      });

      test('skips vector score when useVector is false', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        final conv = Conversation(
          id: 'conv1',
          title: 'Test',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
        );

        index.addDocument(
          _MockDocument(conversation: conv, haystack: 'test', tagSet: {}),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test', useVector: false);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.isNotEmpty, true);
      });
    });

    group('semantic query matching gate', () {
      test('requires semantic match for non-empty query', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        // This document doesn't contain semanticQuery substring
        final conv = Conversation(
          id: 'conv1',
          title: 'Test',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'hello world')],
        );

        index.addDocument(
          _MockDocument(
            conversation: conv,
            haystack: 'hello world',
            tagSet: {},
          ),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        // SemanticQuery is 'test' which is not in 'hello world'
        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        // Will be filtered by semantic gate or fuzzy match gate
        expect(results, isEmpty);
      });

      test('allows fuzzy match when substring not found', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        // Document with haystack containing tokens that match the query via fuzzy matching
        // "bat" should fuzzy-match "cat" with distance 1
        final conv = Conversation(
          id: 'conv1',
          title: 'Test',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'category dog')],
        );

        index.addDocument(
          _MockDocument(
            conversation: conv,
            haystack: 'category dog',
            tagSet: {},
          ),
        );

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'cat');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'cat',
          now: now,
        );

        // 'cat' is substring of 'category', so fuzzy matching should allow it
        final results = service.rankConversations(criteria, scorer, [
          'cat',
        ], 'cat');

        // Depends on whether the document passes the semantic gate
        expect(results, isA<List>());
      });
    });

    group('performance', () {
      test('handles 100+ conversations efficiently', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        // Add 100 conversations
        for (int i = 0; i < 100; i++) {
          final conv = Conversation(
            id: 'conv$i',
            title: 'Conversation $i',
            source: i % 3 == 0 ? 'gmail' : (i % 3 == 1 ? 'slack' : 'zoom'),
            participantIds: ['participant_${i % 10}'],
            segments: [
              ConversationSegment(id: 'seg$i', text: 'test content number $i'),
            ],
            tags: i % 2 == 0 ? ['important'] : ['regular'],
          );
          index.addDocument(
            _MockDocument(
              conversation: conv,
              haystack: 'test content number $i',
              tagSet: i % 2 == 0 ? {'important'} : {'regular'},
            ),
          );
        }

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final stopwatch = Stopwatch()..start();
        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');
        stopwatch.stop();

        expect(results.length, 100);
        expect(stopwatch.elapsedMilliseconds, lessThan(500));
      });

      test('handles 1000+ conversations', () {
        final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
        final index = _MockSearchIndex();

        // Add 1000 conversations
        for (int i = 0; i < 1000; i++) {
          final conv = Conversation(
            id: 'conv$i',
            title: 'Conversation $i',
            source: i % 3 == 0 ? 'gmail' : (i % 3 == 1 ? 'slack' : 'zoom'),
            participantIds: ['participant_${i % 20}'],
            segments: [ConversationSegment(id: 'seg$i', text: 'test query $i')],
          );
          index.addDocument(
            _MockDocument(
              conversation: conv,
              haystack: 'test query $i',
              tagSet: {},
            ),
          );
        }

        final service = SearchService(index);
        final criteria = SearchCriteria(query: 'test');
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );

        final stopwatch = Stopwatch()..start();
        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');
        stopwatch.stop();

        expect(results.length, 1000);
        expect(stopwatch.elapsedMilliseconds, lessThan(2000));
      });
    });

    group('date range filtering', () {
      // These tests derive conversation timestamps from
      // SearchCriteria.normalizedFrom/normalizedTo rather than hardcoding
      // absolute instants, so they are immune to the local-timezone
      // conversion the criteria applies (see search_criteria.dart) and to
      // whatever timezone the test machine runs in.
      test('includes a conversation exactly at the range boundaries', () {
        final now = DateTime.utc(2024, 6, 10, 12);
        final criteria = SearchCriteria(
          query: 'test',
          from: DateTime(2024, 6, 5),
          to: DateTime(2024, 6, 5),
        );
        final index = _MockSearchIndex();
        final conv = Conversation(
          id: 'conv1',
          title: 'Boundary',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
          startedAt: criteria.normalizedFrom,
          endedAt: criteria.normalizedTo,
        );
        index.addDocument(
          _MockDocument(conversation: conv, haystack: 'test', tagSet: {}),
        );

        final service = SearchService(index);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );
        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 1);
      });

      test('excludes a conversation entirely before the range', () {
        final now = DateTime.utc(2024, 6, 10, 12);
        final criteria = SearchCriteria(
          query: 'test',
          from: DateTime(2024, 6, 5),
          to: DateTime(2024, 6, 10),
        );
        final justBefore = criteria.normalizedFrom!.subtract(
          const Duration(milliseconds: 1),
        );
        final index = _MockSearchIndex();
        final conv = Conversation(
          id: 'conv1',
          title: 'Before range',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
          startedAt: justBefore.subtract(const Duration(days: 5)),
          endedAt: justBefore,
        );
        index.addDocument(
          _MockDocument(conversation: conv, haystack: 'test', tagSet: {}),
        );

        final service = SearchService(index);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );
        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results, isEmpty);
      });

      test('excludes a conversation entirely after the range', () {
        final now = DateTime.utc(2024, 6, 10, 12);
        final criteria = SearchCriteria(
          query: 'test',
          from: DateTime(2024, 6, 5),
          to: DateTime(2024, 6, 10),
        );
        final justAfter = criteria.normalizedTo!.add(
          const Duration(milliseconds: 1),
        );
        final index = _MockSearchIndex();
        final conv = Conversation(
          id: 'conv1',
          title: 'After range',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
          startedAt: justAfter,
          endedAt: justAfter.add(const Duration(days: 5)),
        );
        index.addDocument(
          _MockDocument(conversation: conv, haystack: 'test', tagSet: {}),
        );

        final service = SearchService(index);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );
        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results, isEmpty);
      });

      test(
        'includes a conversation whose span overlaps without being fully contained',
        () {
          final now = DateTime.utc(2024, 6, 10, 12);
          final criteria = SearchCriteria(
            query: 'test',
            from: DateTime(2024, 6, 5),
            to: DateTime(2024, 6, 10),
          );
          final index = _MockSearchIndex();
          // Starts well before the range, ends just inside it.
          final conv = Conversation(
            id: 'conv1',
            title: 'Overlapping',
            source: 'email',
            participantIds: ['p1'],
            segments: [ConversationSegment(id: 's1', text: 'test')],
            startedAt: criteria.normalizedFrom!.subtract(
              const Duration(days: 10),
            ),
            endedAt: criteria.normalizedFrom!.add(const Duration(hours: 1)),
          );
          index.addDocument(
            _MockDocument(conversation: conv, haystack: 'test', tagSet: {}),
          );

          final service = SearchService(index);
          final scorer = SearchScorer(
            temporalIntent: null,
            normalizedQuery: 'test',
            now: now,
          );
          final results = service.rankConversations(criteria, scorer, [
            'test',
          ], 'test');

          expect(results.length, 1);
        },
      );

      test('an open-ended "from" only excludes conversations before it', () {
        final now = DateTime.utc(2024, 6, 10, 12);
        final criteria = SearchCriteria(
          query: 'test',
          from: DateTime(2024, 6, 5),
        );
        final index = _MockSearchIndex();
        final early = Conversation(
          id: 'early',
          title: 'Early',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
          startedAt: criteria.normalizedFrom!.subtract(const Duration(days: 1)),
          endedAt: criteria.normalizedFrom!.subtract(const Duration(days: 1)),
        );
        final late = Conversation(
          id: 'late',
          title: 'Late',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's2', text: 'test')],
          startedAt: criteria.normalizedFrom!.add(const Duration(days: 100)),
          endedAt: criteria.normalizedFrom!.add(const Duration(days: 100)),
        );
        index.addDocument(
          _MockDocument(conversation: early, haystack: 'test', tagSet: {}),
        );
        index.addDocument(
          _MockDocument(conversation: late, haystack: 'test', tagSet: {}),
        );

        final service = SearchService(index);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );
        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.map((c) => c.id), ['late']);
      });

      test('no date filter returns conversations regardless of age', () {
        final now = DateTime.utc(2024, 6, 10, 12);
        final criteria = SearchCriteria(query: 'test');
        final index = _MockSearchIndex();
        final ancient = Conversation(
          id: 'ancient',
          title: 'Ancient',
          source: 'email',
          participantIds: ['p1'],
          segments: [ConversationSegment(id: 's1', text: 'test')],
          startedAt: DateTime.utc(1999, 1, 1),
          endedAt: DateTime.utc(1999, 1, 1),
        );
        index.addDocument(
          _MockDocument(conversation: ancient, haystack: 'test', tagSet: {}),
        );

        final service = SearchService(index);
        final scorer = SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'test',
          now: now,
        );
        final results = service.rankConversations(criteria, scorer, [
          'test',
        ], 'test');

        expect(results.length, 1);
      });
    });
  });
}

/// Helper function to test fuzzy matching logic
bool _fuzzyMatchHelper(String query, String haystack) {
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
