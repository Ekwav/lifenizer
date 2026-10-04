import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/search_index_worker_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'worker reports both counted passes and preserves lexical and vector results',
    () async {
      final conversations = [
        Conversation(
          id: 'invoice',
          title: 'Quarterly invoice',
          source: 'email',
          participantIds: ['alice'],
          segments: [
            ConversationSegment(
              id: 'one',
              text: 'Invoice payment received',
              participantId: 'alice',
            ),
          ],
        ),
        Conversation(
          id: 'trip',
          title: 'Train itinerary',
          source: 'discord',
          participantIds: ['bob'],
          segments: [
            ConversationSegment(
              id: 'two',
              text: 'Meet at the Berlin station',
              participantId: 'bob',
            ),
          ],
        ),
      ];
      final people = {
        'alice': 'Alice alice@example.test',
        'bob': 'Bob discord:123',
      };
      final relations = {'invoice': 'Alice paid invoice'};
      final expected = ConversationSearchIndex.build(
        conversations: conversations,
        participantById: people,
        relationTextByConversation: relations,
      );
      final progress = <SearchIndexProgress>[];
      final actual = await prepareSearchIndex((
        conversations,
        people,
        relations,
      ), progress.add);
      expect(
        progress.any(
          (value) =>
              !value.finalizing && value.completed == 2 && value.total == 2,
        ),
        isTrue,
      );
      expect(
        progress.any((value) => value.finalizing && value.completed == 0),
        isTrue,
      );
      expect(actual.invertedIndex, expected.invertedIndex);
      expect(actual.idf, expected.idf);
      expect(actual.averageLength, expected.averageLength);
      for (final query in ['invoice', 'alice', 'Berlin']) {
        final tokens = ConversationSearchIndex.tokenize(query);
        expect(
          actual.lookupCandidates(tokens),
          expected.lookupCandidates(tokens),
        );
        for (final id in expected.documents.keys) {
          expect(
            actual.lexicalScore(actual.documents[id]!, query, tokens),
            expected.lexicalScore(expected.documents[id]!, query, tokens),
          );
          expect(
            actual.vectorScore(actual.documents[id]!, tokens),
            expected.vectorScore(expected.documents[id]!, tokens),
          );
        }
      }
    },
  );
}
