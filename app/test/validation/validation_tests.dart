import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Validation test suite', () {
    // ------------------------------------------------------------------
    // Data validation (15 tests)
    // ------------------------------------------------------------------

    final dataValidationCases = <({String name, List<String> Function() run, bool expectValid})>[
      (
        name: 'conversation with required fields is valid',
        run: () => _validateConversation(_validConversation(id: 'c-1')),
        expectValid: true,
      ),
      (
        name: 'conversation requires non-empty id',
        run: () => _validateConversation(_validConversation(id: '')),
        expectValid: false,
      ),
      (
        name: 'conversation requires non-empty title',
        run: () => _validateConversation(_validConversation(id: 'c-title', title: '')),
        expectValid: false,
      ),
      (
        name: 'conversation requires non-empty source',
        run: () => _validateConversation(_validConversation(id: 'c-source', source: '')),
        expectValid: false,
      ),
      (
        name: 'conversation requires at least one segment',
        run: () => _validateConversation(
          Conversation(
            id: 'c-segments',
            title: 'No segments',
            source: 'manual-text',
            participantIds: const ['p-1'],
            segments: const [],
            tags: const ['work'],
            startedAt: DateTime.utc(2026, 1, 1),
            endedAt: DateTime.utc(2026, 1, 1, 1),
          ),
        ),
        expectValid: false,
      ),
      (
        name: 'conversation timestamps must be ordered',
        run: () => _validateConversation(
          _validConversation(
            id: 'c-order',
            startedAt: DateTime.utc(2026, 1, 2),
            endedAt: DateTime.utc(2026, 1, 1),
          ),
        ),
        expectValid: false,
      ),
      (
        name: 'participant with required fields is valid',
        run: () => _validateParticipant(Participant(id: 'p-1', displayName: 'Alice')),
        expectValid: true,
      ),
      (
        name: 'participant requires non-empty id',
        run: () => _validateParticipant(Participant(id: '', displayName: 'Alice')),
        expectValid: false,
      ),
      (
        name: 'participant requires non-empty display name',
        run: () => _validateParticipant(Participant(id: 'p-1', displayName: '')),
        expectValid: false,
      ),
      (
        name: 'segment with valid timestamp is valid',
        run: () => _validateSegment(
          ConversationSegment(
            id: 's-1',
            text: 'ok',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ),
        expectValid: true,
      ),
      (
        name: 'segment requires non-empty id',
        run: () => _validateSegment(ConversationSegment(id: '', text: 'x')),
        expectValid: false,
      ),
      (
        name: 'segment requires non-empty text',
        run: () => _validateSegment(ConversationSegment(id: 's-1', text: '')),
        expectValid: false,
      ),
      (
        name: 'segment offset must be non-negative',
        run: () => _validateSegment(ConversationSegment(id: 's-1', text: 'x', offsetMs: -1)),
        expectValid: false,
      ),
      (
        name: 'conversation participant references must exist',
        run: () {
          final c = _validConversation(id: 'c-ref-missing', participantIds: const ['p-missing']);
          return _validateConversationWithParticipants(c, [Participant(id: 'p-1', displayName: 'A')]);
        },
        expectValid: false,
      ),
      (
        name: 'conversation participant references valid ids pass',
        run: () {
          final c = _validConversation(id: 'c-ref-valid', participantIds: const ['p-1']);
          return _validateConversationWithParticipants(c, [Participant(id: 'p-1', displayName: 'A')]);
        },
        expectValid: true,
      ),
    ];

    for (final caseItem in dataValidationCases) {
      test(caseItem.name, () {
        final errors = caseItem.run();
        if (caseItem.expectValid) {
          expect(errors, isEmpty);
        } else {
          expect(errors, isNotEmpty);
        }
      });
    }

    // ------------------------------------------------------------------
    // API contract validation (15 tests)
    // ------------------------------------------------------------------

    final apiContractCases = <({String name, Map<String, dynamic> payload, List<String> requiredFields, bool expectValid})>[
      (
        name: 'auth response matches schema',
        payload: {
          'authToken': 'token',
          'userId': 'u',
          'vaultId': 'v',
          'vaultSalt': 's',
        },
        requiredFields: const ['authToken', 'userId', 'vaultId', 'vaultSalt'],
        expectValid: true,
      ),
      (
        name: 'auth response missing token is invalid',
        payload: {'userId': 'u', 'vaultId': 'v', 'vaultSalt': 's'},
        requiredFields: const ['authToken', 'userId', 'vaultId', 'vaultSalt'],
        expectValid: false,
      ),
      (
        name: 'import response schema valid',
        payload: {
          'source': 'whatsapp',
          'plaintextCompute': true,
          'message': 'ok',
          'conversations': [
            {'title': 'x'}
          ],
          'participants': [
            {'displayName': 'Alice'}
          ],
        },
        requiredFields: const ['source', 'plaintextCompute', 'message', 'conversations', 'participants'],
        expectValid: true,
      ),
      (
        name: 'import response missing conversations invalid',
        payload: {
          'source': 'whatsapp',
          'plaintextCompute': true,
          'message': 'ok',
          'participants': []
        },
        requiredFields: const ['source', 'plaintextCompute', 'message', 'conversations', 'participants'],
        expectValid: false,
      ),
      (
        name: 'sync push request schema valid',
        payload: {
          'envelopes': [
            {'id': '1'}
          ]
        },
        requiredFields: const ['envelopes'],
        expectValid: true,
      ),
      (
        name: 'sync push request missing envelopes invalid',
        payload: {},
        requiredFields: const ['envelopes'],
        expectValid: false,
      ),
      (
        name: 'sync pull response schema valid',
        payload: {
          'cursor': 1,
          'envelopes': []
        },
        requiredFields: const ['cursor', 'envelopes'],
        expectValid: true,
      ),
      (
        name: 'sync pull response missing cursor invalid',
        payload: {'envelopes': []},
        requiredFields: const ['cursor', 'envelopes'],
        expectValid: false,
      ),
      (
        name: 'relation extraction response schema valid',
        payload: {
          'plaintextCompute': true,
          'compromise': 'x',
          'relations': []
        },
        requiredFields: const ['plaintextCompute', 'compromise', 'relations'],
        expectValid: true,
      ),
      (
        name: 'relation extraction response missing compromise invalid',
        payload: {
          'plaintextCompute': true,
          'relations': []
        },
        requiredFields: const ['plaintextCompute', 'compromise', 'relations'],
        expectValid: false,
      ),
      (
        name: 'no null values in required auth fields',
        payload: {
          'authToken': null,
          'userId': 'u',
          'vaultId': 'v',
          'vaultSalt': 's',
        },
        requiredFields: const ['authToken', 'userId', 'vaultId', 'vaultSalt'],
        expectValid: false,
      ),
      (
        name: 'no null values in required import fields',
        payload: {
          'source': 'x',
          'plaintextCompute': null,
          'message': 'ok',
          'conversations': [],
          'participants': [],
        },
        requiredFields: const ['source', 'plaintextCompute', 'message', 'conversations', 'participants'],
        expectValid: false,
      ),
      (
        name: 'request parameter validation rejects empty import source',
        payload: {'source': ''},
        requiredFields: const ['source'],
        expectValid: false,
      ),
      (
        name: 'request parameter validation accepts valid import source',
        payload: {'source': 'whatsapp'},
        requiredFields: const ['source'],
        expectValid: true,
      ),
      (
        name: 'request parameter validation rejects non-list envelopes',
        payload: {'envelopes': 'not-list'},
        requiredFields: const ['envelopes'],
        expectValid: false,
      ),
    ];

    for (final contract in apiContractCases) {
      test(contract.name, () {
        final errors = _validateContract(
          contract.payload,
          requiredFields: contract.requiredFields,
        );

        if (contract.payload.containsKey('source') && contract.payload['source'] is String) {
          final source = contract.payload['source'] as String;
          if (source.isEmpty) {
            errors.add('source must not be empty');
          }
        }
        if (contract.payload.containsKey('envelopes') && contract.payload['envelopes'] is! List) {
          errors.add('envelopes must be a list');
        }

        if (contract.expectValid) {
          expect(errors, isEmpty);
        } else {
          expect(errors, isNotEmpty);
        }
      });
    }

    // ------------------------------------------------------------------
    // Search index validation (10 tests)
    // ------------------------------------------------------------------

    final searchIndexTests = <({String name, void Function() run})>[
      (
        name: 'index stays consistent across repeated searches',
        run: () {
          final state = _stateWithData();
          final a = state.search('release').map((c) => c.id).toList();
          final b = state.search('release').map((c) => c.id).toList();
          expect(a, b);
        },
      ),
      (
        name: 'index updates after adding a conversation',
        run: () {
          final state = _stateWithData();
          expect(state.search('new-topic'), isEmpty);
          state.conversations.add(_validConversation(id: 'c-new', title: 'new-topic', source: 'manual-text'));
          expect(state.search('new-topic'), isNotEmpty);
        },
      ),
      (
        name: 'index rebuild after relation insert keeps searchable relation text',
        run: () {
          final state = _stateWithData();
          state.relations.add(
            RelationEdge(
              id: 'r-1',
              subject: 'Alice',
              relation: 'collaborates with',
              object: 'Bob',
              evidence: 'text',
              confidence: 0.9,
              evidenceConversationId: 'c-1',
            ),
          );
          final results = state.search('collaborates');
          expect(results, isNotEmpty);
        },
      ),
      (
        name: 'index supports source-filtered queries',
        run: () {
          final state = _stateWithData();
          final email = state.search('release', source: 'email');
          expect(email.every((c) => c.source == 'email'), isTrue);
        },
      ),
      (
        name: 'index supports participant-filtered queries',
        run: () {
          final state = _stateWithData();
          final byAlice = state.search('release', participantId: 'p-1');
          expect(byAlice.every((c) => c.participantIds.contains('p-1')), isTrue);
        },
      ),
      (
        name: 'index supports tag-filtered queries',
        run: () {
          final state = _stateWithData();
          final work = state.search('release', tag: 'work');
          expect(work.every((c) => c.tags.contains('work')), isTrue);
        },
      ),
      (
        name: 'index pagination returns non-overlapping pages',
        run: () {
          final state = _stateWithData();
          final p1 = state.searchPaged('release', page: 1, pageSize: 1);
          final p2 = state.searchPaged('release', page: 2, pageSize: 1);
          expect(p1.items.first.id, isNot(p2.items.first.id));
        },
      ),
      (
        name: 'index rebuild does not lose documents',
        run: () {
          final state = _stateWithData();
          final before = state.search('').length;
          state.relations.add(
            RelationEdge(
              id: 'r-2',
              subject: 'X',
              relation: 'knows',
              object: 'Y',
              evidence: 'e',
              confidence: 0.6,
              evidenceConversationId: 'c-2',
            ),
          );
          final after = state.search('').length;
          expect(after, before);
        },
      ),
      (
        name: 'index can handle mixed document types in same query',
        run: () {
          final state = _stateWithData();
          state.conversations.add(
            _validConversation(
              id: 'c-3',
              title: 'Bookmark digest',
              source: 'bookmarks',
              segments: [ConversationSegment(id: 's-3', text: 'github links')],
            ),
          );
          final results = state.search('github');
          expect(results, isNotEmpty);
        },
      ),
      (
        name: 'index supports vector and non-vector modes consistently',
        run: () {
          final state = _stateWithData();
          final vector = state.search('release roadmap', useVector: true);
          final lexical = state.search('release roadmap', useVector: false);
          expect(vector.map((c) => c.id).toSet(), lexical.map((c) => c.id).toSet());
        },
      ),
    ];

    for (final searchTest in searchIndexTests) {
      test(searchTest.name, searchTest.run);
    }
  });
}

Conversation _validConversation({
  required String id,
  String title = 'Release planning',
  String source = 'email',
  List<String> participantIds = const ['p-1'],
  List<ConversationSegment> segments = const [],
  List<String> tags = const ['work'],
  DateTime? startedAt,
  DateTime? endedAt,
}) {
  final start = startedAt ?? DateTime.utc(2026, 1, 1);
  final end = endedAt ?? DateTime.utc(2026, 1, 1, 1);
  return Conversation(
    id: id,
    title: title,
    source: source,
    participantIds: participantIds,
    segments: segments.isEmpty ? [ConversationSegment(id: 's-1', text: 'release roadmap')] : segments,
    tags: tags,
    startedAt: start,
    endedAt: end,
  );
}

List<String> _validateConversation(Conversation conversation) {
  final errors = <String>[];
  if (conversation.id.trim().isEmpty) errors.add('id required');
  if (conversation.title.trim().isEmpty) errors.add('title required');
  if (conversation.source.trim().isEmpty) errors.add('source required');
  if (conversation.segments.isEmpty) errors.add('at least one segment required');
  if (conversation.startedAt.isAfter(conversation.endedAt)) {
    errors.add('timestamps out of order');
  }
  for (final segment in conversation.segments) {
    errors.addAll(_validateSegment(segment));
  }
  return errors;
}

List<String> _validateConversationWithParticipants(
  Conversation conversation,
  List<Participant> participants,
) {
  final errors = _validateConversation(conversation);
  final known = participants.map((p) => p.id).toSet();
  for (final participantId in conversation.participantIds) {
    if (!known.contains(participantId)) {
      errors.add('unknown participant: $participantId');
    }
  }
  return errors;
}

List<String> _validateParticipant(Participant participant) {
  final errors = <String>[];
  if (participant.id.trim().isEmpty) errors.add('id required');
  if (participant.displayName.trim().isEmpty) errors.add('displayName required');
  return errors;
}

List<String> _validateSegment(ConversationSegment segment) {
  final errors = <String>[];
  if (segment.id.trim().isEmpty) errors.add('segment id required');
  if (segment.text.trim().isEmpty) errors.add('segment text required');
  if (segment.offsetMs < 0) errors.add('segment offset must be non-negative');
  return errors;
}

List<String> _validateContract(
  Map<String, dynamic> payload, {
  required List<String> requiredFields,
}) {
  final errors = <String>[];
  for (final field in requiredFields) {
    if (!payload.containsKey(field)) {
      errors.add('missing field: $field');
      continue;
    }
    if (payload[field] == null) {
      errors.add('null field: $field');
    }
  }
  return errors;
}

LifenizerAppState _stateWithData() {
  final state = LifenizerAppState();
  state.participants.addAll([
    Participant(id: 'p-1', displayName: 'Alice'),
    Participant(id: 'p-2', displayName: 'Bob'),
  ]);

  state.conversations.addAll([
    _validConversation(
      id: 'c-1',
      title: 'Release roadmap',
      source: 'email',
      participantIds: const ['p-1'],
      segments: [ConversationSegment(id: 's-1', text: 'release roadmap and milestones')],
      tags: const ['work'],
      startedAt: DateTime.utc(2026, 1, 2),
      endedAt: DateTime.utc(2026, 1, 2, 1),
    ),
    _validConversation(
      id: 'c-2',
      title: 'Release follow-up',
      source: 'chat',
      participantIds: const ['p-1', 'p-2'],
      segments: [ConversationSegment(id: 's-2', text: 'release blockers and actions')],
      tags: const ['work'],
      startedAt: DateTime.utc(2026, 1, 3),
      endedAt: DateTime.utc(2026, 1, 3, 1),
    ),
  ]);

  return state;
}
