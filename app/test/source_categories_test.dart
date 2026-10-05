import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';
import 'package:app/services/source_categories.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 10, 3, 12);

Conversation _conversation(
  String id,
  String source, {
  String text = 'sourdough starter hydration tips',
  DateTime? at,
}) => Conversation(
  id: id,
  title: 'sourdough starter',
  source: source,
  participantIds: const [],
  startedAt: at ?? _now,
  endedAt: at ?? _now,
  segments: [ConversationSegment(id: '$id-s', text: text)],
);

List<String> _rank(
  List<Conversation> items,
  String query, {
  bool includeConsumed = true,
}) {
  final index = ConversationSearchIndex.build(
    conversations: items,
    participantById: const {},
    relationTextByConversation: const {},
  );
  final tokens = ConversationSearchIndex.tokenize(query);
  return SearchService(index)
      .rankConversations(
        SearchCriteria(query: query, includeConsumed: includeConsumed),
        SearchScorer(temporalIntent: null, normalizedQuery: query, now: _now),
        tokens,
        tokens.join(' '),
      )
      .map((c) => c.id)
      .toList();
}

void main() {
  group('categoryForSource', () {
    test('maps consumed, document and personal sources', () {
      for (final source in [
        'youtube-watch-history',
        'tiktok-watch-history',
        'youtube-transcript',
        'browser-history',
        'google-search-history',
        'bookmarks',
        'browser-capture',
      ]) {
        expect(
          categoryForSource(source),
          SourceCategory.consumed,
          reason: source,
        );
      }
      for (final source in ['scanned-pdf', 'paperless', 'photo']) {
        expect(categoryForSource(source), SourceCategory.documents);
      }
      for (final source in ['whatsapp', 'audio', 'manual-text', 'discord']) {
        expect(categoryForSource(source), SourceCategory.personal);
      }
    });

    test('labels and weights', () {
      expect(SourceCategory.consumed.displayLabel, 'Consumed');
      expect(SourceCategory.documents.displayLabel, 'Documents');
      expect(SourceCategory.personal.displayLabel, isNull);
      expect(consumedCategoryWeight, 0.6);
      expect(documentsCategoryWeight, 0.9);
      expect(personalCategoryWeight, 1.0);
      expect(weightForSource('youtube-watch-history'), 0.6);
      expect(weightForSource('photo'), 0.9);
      expect(weightForSource('whatsapp'), 1.0);
    });
  });

  group('ranking', () {
    test('equally matching watched video ranks below personal chat', () {
      final ranked = _rank([
        _conversation('video', 'youtube-watch-history'),
        _conversation('doc', 'scanned-pdf'),
        _conversation('chat', 'whatsapp'),
      ], 'sourdough starter');
      expect(ranked, ['chat', 'doc', 'video']);
    });

    test(
      'a strong video match still loses to an equal personal chat even if newer',
      () {
        final ranked = _rank([
          _conversation('video', 'tiktok-watch-history', at: _now),
          _conversation(
            'chat',
            'whatsapp',
            at: _now.subtract(const Duration(days: 3)),
          ),
        ], 'sourdough starter');
        expect(ranked.first, 'chat');
      },
    );

    test('empty-query timeline puts recent chats above watched videos', () {
      final ranked = _rank([
        _conversation('video', 'youtube-watch-history', at: _now),
        _conversation(
          'chat',
          'whatsapp',
          at: _now.subtract(const Duration(days: 1)),
        ),
      ], '');
      expect(ranked, ['chat', 'video']);
    });

    test('hide-consumed filter removes consumed media only', () {
      final items = [
        _conversation('video', 'youtube-watch-history'),
        _conversation('history', 'browser-history'),
        _conversation('doc', 'photo'),
        _conversation('chat', 'whatsapp'),
      ];
      expect(
        _rank(items, 'sourdough', includeConsumed: false),
        unorderedEquals(['doc', 'chat']),
      );
      expect(_rank(items, 'sourdough'), hasLength(4));
    });
  });

  group('saved search compatibility', () {
    test('old JSON without hideConsumed shows everything', () {
      final old = SavedSearch.fromJson({
        'id': 'a',
        'title': 't',
        'query': 'q',
        'createdAt': '2026-01-01T00:00:00Z',
      });
      expect(old.hideConsumed, isFalse);
      expect(old.toJson().containsKey('hideConsumed'), isFalse);
    });

    test('hideConsumed round-trips', () {
      final saved = SavedSearch(id: 'a', title: 't', hideConsumed: true);
      expect(SavedSearch.fromJson(saved.toJson()).hideConsumed, isTrue);
    });
  });
}
