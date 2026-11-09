import 'package:flutter_test/flutter_test.dart';

import 'package:app/app_state.dart';
import 'package:app/models.dart';

void main() {
  test('filters search results by source, participant, and tag', () {
    final state = LifenizerAppState();
    state.participants.addAll([
      Participant(id: 'alice', displayName: 'Alice'),
      Participant(id: 'bob', displayName: 'Bob'),
    ]);
    state.conversations.addAll([
      Conversation(
        id: 'email-1',
        title: 'Paper invoice',
        source: 'email',
        participantIds: ['alice'],
        tags: const ['documents', 'email'],
        artifactNames: const ['invoice.pdf'],
        segments: [
          ConversationSegment(id: 'segment-1', text: 'Invoice from April'),
        ],
        startedAt: DateTime.utc(2026, 5, 1),
        endedAt: DateTime.utc(2026, 5, 1),
      ),
      Conversation(
        id: 'chat-1',
        title: 'Project chat',
        source: 'whatsapp',
        participantIds: ['alice', 'bob'],
        tags: const ['chat', 'whatsapp'],
        segments: [
          ConversationSegment(id: 'segment-2', text: 'Alice works with Bob'),
        ],
        startedAt: DateTime.utc(2026, 5, 2),
        endedAt: DateTime.utc(2026, 5, 2),
      ),
    ]);

    expect(state.search('invoice', source: 'email').map((item) => item.id), [
      'email-1',
    ]);
    expect(state.search('', tag: 'chat').map((item) => item.id), ['chat-1']);
    expect(state.search('alice', participantId: 'bob').map((item) => item.id), [
      'chat-1',
    ]);
    expect(state.availableSources, ['email', 'whatsapp']);
    expect(state.allTags, ['chat', 'documents', 'email', 'whatsapp']);
  });

  test('builds local vault insights from decrypted conversations', () {
    final state = LifenizerAppState();
    state.participants.addAll([
      Participant(id: 'alice', displayName: 'Alice'),
      Participant(id: 'bob', displayName: 'Bob'),
    ]);
    state.conversations.addAll([
      Conversation(
        id: 'recording-1',
        title: 'Recording',
        source: 'live-recording',
        participantIds: ['alice'],
        tags: const ['recording'],
        segments: [
          ConversationSegment(id: 'segment-1', text: 'First note'),
          ConversationSegment(id: 'segment-2', text: 'Second note'),
        ],
        startedAt: DateTime.utc(2026, 4, 30),
        endedAt: DateTime.utc(2026, 4, 30),
      ),
      Conversation(
        id: 'chat-1',
        title: 'Chat',
        source: 'whatsapp',
        participantIds: ['alice', 'bob'],
        tags: const ['chat', 'whatsapp'],
        artifactNames: const ['chat.txt'],
        segments: [
          ConversationSegment(id: 'segment-3', text: 'A chat message'),
        ],
        startedAt: DateTime.utc(2026, 5, 1),
        endedAt: DateTime.utc(2026, 5, 1),
      ),
    ]);

    final insights = state.insights;

    expect(insights.totalConversations, 2);
    expect(insights.totalSegments, 3);
    expect(insights.totalArtifacts, 1);
    expect(
      insights.sourceFacets.map((facet) => facet.source),
      containsAll(['live-recording', 'whatsapp']),
    );
    expect(insights.participantFacets.first.participant.displayName, 'Alice');
    expect(insights.participantFacets.first.count, 2);
    expect(insights.timeline.map((bucket) => bucket.day), [
      DateTime.utc(2026, 5, 1),
      DateTime.utc(2026, 4, 30),
    ]);
    expect(insights.tags, ['chat', 'recording', 'whatsapp']);
  });
}
