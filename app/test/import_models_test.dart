import 'package:flutter_test/flutter_test.dart';

import 'package:app/models.dart';

void main() {
  test('decodes normalized import responses from backend JSON', () {
    final result = NormalizedImportResult.fromJson({
      'source': 'whatsapp',
      'plaintextCompute': true,
      'message': 'Normalized 2 whatsapp messages.',
      'participants': [
        {'displayName': 'Alice'},
        {'displayName': 'Bob'},
      ],
      'conversations': [
        {
          'title': 'Project chat',
          'source': 'whatsapp',
          'participantNames': ['Alice', 'Bob'],
          'artifactNames': ['chat.txt'],
          'segments': [
            {
              'text': 'Person X works with Person Z.',
              'participantName': 'Alice',
              'offsetMs': 0,
            },
            {
              'text': 'Person Y is Person X\'s sister.',
              'participantName': 'Bob',
              'offsetMs': 1000,
            },
          ],
        },
      ],
    });

    expect(result.source, 'whatsapp');
    expect(result.plaintextCompute, isTrue);
    expect(result.participants.map((p) => p.displayName), contains('Alice'));
    expect(result.conversations.single.segments, hasLength(2));
    expect(result.conversations.single.artifactNames, contains('chat.txt'));
  });

  test('decodes optional conversation tags and saved searches', () {
    final conversation = Conversation.fromJson({
      'id': 'conversation-1',
      'title': 'Email import',
      'source': 'email',
      'participantIds': ['participant-1'],
      'segments': [
        {'id': 'segment-1', 'text': 'Encrypted body'},
      ],
      'artifactNames': ['message.eml'],
      'tags': ['email', 'documents'],
      'isFavorite': true,
      'startedAt': '2026-05-01T00:00:00.000Z',
      'endedAt': '2026-05-01T00:00:00.000Z',
    });
    final legacyConversation = Conversation.fromJson({
      'id': 'conversation-2',
      'title': 'Legacy import',
      'source': 'manual-text',
      'participantIds': <String>[],
      'segments': <Map<String, Object>>[],
      'startedAt': '2026-05-01T00:00:00.000Z',
      'endedAt': '2026-05-01T00:00:00.000Z',
    });
    final savedSearch = SavedSearch.fromJson({
      'id': 'search-1',
      'title': 'Alice documents',
      'query': 'Alice',
      'source': 'email',
      'participantId': 'participant-1',
      'tag': 'documents',
      'createdAt': '2026-05-01T00:00:00.000Z',
    });

    expect(conversation.tags, ['email', 'documents']);
    expect(conversation.isFavorite, isTrue);
    expect(legacyConversation.tags, isEmpty);
    expect(legacyConversation.isFavorite, isFalse);
    expect(savedSearch.toJson()['tag'], 'documents');
  });
}
