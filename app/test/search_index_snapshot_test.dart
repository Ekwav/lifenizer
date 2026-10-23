import 'dart:convert';

import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation conversation(String id, String text) => Conversation(
  id: id,
  title: 'Überweisung $id',
  source: 'email',
  participantIds: const ['alice'],
  tags: const ['Payment received'],
  metadata: const {'folder': 'finance'},
  segments: [
    ConversationSegment(
      id: 'segment-$id',
      text: text,
      participantId: 'bob',
      createdAt: DateTime.utc(2023, 4, 5),
    ),
  ],
  startedAt: DateTime.utc(2023),
  endedAt: DateTime.utc(2024),
);

ConversationSearchIndex build(List<Conversation> conversations) =>
    ConversationSearchIndex.build(
      conversations: conversations,
      participantById: const {'alice': 'Alice', 'bob': 'Böb'},
      relationTextByConversation: const {'one': 'Invoice paid'},
    );

ConversationSearchIndex roundTrip(ConversationSearchIndex index) =>
    ConversationSearchIndex.fromJson(
      jsonDecode(jsonEncode(index.toJson())) as Map<String, dynamic>,
    );

void main() {
  test(
    'snapshot preserves prepared search results and omits full segments',
    () {
      final original = build([
        conversation('one', 'invoice invoice amount 12345'),
        conversation('two', 'Berlin train ticket'),
      ]);
      final restored = roundTrip(original);
      expect(restored.invertedIndex, original.invertedIndex);
      expect(restored.idf, original.idf);
      expect(restored.averageLength, original.averageLength);
      for (final id in original.documents.keys) {
        final expected = original.documents[id]!;
        final actual = restored.documents[id]!;
        expect(actual.conversation.segments, isEmpty);
        expect(actual.conversation.metadata, expected.conversation.metadata);
        expect(actual.haystack, expected.haystack);
        expect(actual.titleTokens, expected.titleTokens);
        expect(actual.personTokens, expected.personTokens);
        expect(actual.tagSet, expected.tagSet);
        expect(actual.termFrequency, expected.termFrequency);
        expect(actual.vectorNorm, expected.vectorNorm);
        expect(actual.length, expected.length);
      }
      for (final query in [
        'invoice',
        'alice',
        'boeb',
        'ueber',
        'ticket',
        '12345',
      ]) {
        final tokens = ConversationSearchIndex.tokenize(query);
        expect(
          restored.lookupCandidates(tokens),
          original.lookupCandidates(tokens),
        );
        for (final id in original.documents.keys) {
          expect(
            restored.lexicalScore(restored.documents[id]!, query, tokens),
            original.lexicalScore(original.documents[id]!, query, tokens),
          );
          expect(
            restored.vectorScore(restored.documents[id]!, tokens),
            original.vectorScore(original.documents[id]!, tokens),
          );
        }
      }
    },
  );

  test('restored index supports incremental updates and another snapshot', () {
    final original = build([
      conversation('one', 'invoice amount'),
      conversation('two', 'train ticket'),
    ]);
    final restored = roundTrip(original);
    for (final index in [original, restored]) {
      index.remove('one', refresh: false);
      index.upsert(
        conversation('two', 'replacement statement'),
        participantById: const {'alice': 'Alice', 'bob': 'Böb'},
        relationTextByConversation: const {},
      );
    }
    final savedAgain = roundTrip(restored);
    expect(savedAgain.invertedIndex, original.invertedIndex);
    expect(savedAgain.idf, original.idf);
    expect(savedAgain.averageLength, original.averageLength);
    expect(
      savedAgain.documents['two']!.vectorNorm,
      original.documents['two']!.vectorNorm,
    );
    expect(savedAgain.lookupCandidates(['invoice']), isEmpty);
    expect(savedAgain.lookupCandidates(['replacement']), {'two'});
  });

  test('empty snapshots and incompatible versions', () {
    final index = roundTrip(build([]));
    expect(index.documents, isEmpty);
    expect(index.averageLength, 1);
    expect(
      () => ConversationSearchIndex.fromJson({'version': 0}),
      throwsFormatException,
    );
  });

  test('snapshot requires prepared statistics after a deferred update', () {
    final index = build([conversation('one', 'invoice')]);
    index.upsert(
      conversation('two', 'ticket'),
      participantById: const {},
      relationTextByConversation: const {},
      refresh: false,
    );
    expect(index.toJson, throwsStateError);
    index.refreshStatistics();
    expect(roundTrip(index).documents.length, 2);
  });
}
