import 'dart:convert';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Backward compatibility', () {
    final oldConversationFixtures = <Map<String, dynamic>>[
      _oldConversation(id: 'c-1', title: 'Legacy 1', source: 'manual-text'),
      _oldConversation(id: 'c-2', title: 'Legacy 2', source: 'whatsapp'),
      _oldConversation(
        id: 'c-3',
        title: 'Legacy 3',
        source: 'telegram',
        tags: ['chat'],
      ),
      _oldConversation(
        id: 'c-4',
        title: 'Legacy 4',
        source: 'signal',
        artifactNames: ['a.txt'],
      ),
      _oldConversation(
        id: 'c-5',
        title: 'Legacy 5',
        source: 'email',
        isFavorite: true,
      ),
    ];

    for (final fixture in oldConversationFixtures) {
      test('old conversation JSON can deserialize: ${fixture['id']}', () {
        final parsed = Conversation.fromJson(fixture);
        expect(parsed.id, fixture['id']);
        expect(parsed.title, fixture['title']);
        expect(parsed.source, fixture['source']);
        expect(parsed.startedAt.isUtc, isTrue);
      });
    }

    final modelFixtures =
        <
          ({
            String name,
            Map<String, dynamic> payload,
            Object Function(Map<String, dynamic>) parse,
          })
        >[
          (
            name: 'old participant JSON can deserialize',
            payload: {'id': 'p-1', 'displayName': 'Alice'},
            parse: Participant.fromJson,
          ),
          (
            name: 'old segment JSON can deserialize with defaults',
            payload: {
              'id': 's-1',
              'text': 'hello',
              'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
            },
            parse: ConversationSegment.fromJson,
          ),
          (
            name: 'old saved search JSON can deserialize with optional filters',
            payload: {
              'id': 'ss-1',
              'title': 'Legacy search',
              'query': 'legacy',
              'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
            },
            parse: SavedSearch.fromJson,
          ),
          (
            name: 'old relation JSON can deserialize',
            payload: {
              'id': 'r-1',
              'subject': 'A',
              'relation': 'knows',
              'object': 'B',
              'evidence': 'legacy relation',
              'confidence': 0.8,
            },
            parse: RelationEdge.fromJson,
          ),
          (
            name: 'old auth session JSON can deserialize',
            payload: {
              'authToken': 't',
              'userId': 'u',
              'vaultId': 'v',
              'vaultSalt': 's',
            },
            parse: AuthSession.fromJson,
          ),
        ];

    for (final fixture in modelFixtures) {
      test(fixture.name, () {
        final parsed = fixture.parse(fixture.payload);
        expect(parsed, isNotNull);
      });
    }

    final migrationTests = <({String name, void Function() run})>[
      (
        name: 'v1 vault conversations can be transformed to v2 shape',
        run: () {
          final v1 = {
            'id': 'legacy',
            'title': 'Legacy vault',
            'source': 'manual-text',
            'participantIds': <String>[],
            'segments': [
              {
                'id': 's-1',
                'text': 'line 1',
                'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
              },
            ],
            'startedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
            'endedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          };

          final migrated = _migrateConversationV1ToV2(v1);
          final parsed = Conversation.fromJson(migrated);
          expect(parsed.tags, contains('manual-text'));
        },
      ),
      (
        name: 'old search index can be rebuilt from legacy conversations',
        run: () {
          final state = _stateWithLegacyData();
          final first = state.search('roadmap');
          state.relations.add(
            RelationEdge(
              id: 'rel-1',
              subject: 'Alice',
              relation: 'works with',
              object: 'Bob',
              evidence: 'legacy',
              confidence: 0.9,
              evidenceConversationId: first.first.id,
            ),
          );
          final rebuilt = state.search('works with');
          expect(rebuilt, isNotEmpty);
        },
      ),
      (
        name: 'old import payload can be reparsed into conversation model',
        run: () {
          final legacyImport = {
            'title': 'Imported legacy',
            'source': 'whatsapp',
            'participantNames': ['Alice'],
            'segments': [
              {
                'text': 'old import line',
                'participantName': 'Alice',
                'offsetMs': 0,
              },
            ],
          };
          final converted = _legacyImportToConversationJson(legacyImport);
          final parsed = Conversation.fromJson(converted);
          expect(parsed.segments.first.text, 'old import line');
        },
      ),
      (
        name: 'legacy JSON bundle with unknown fields remains parseable',
        run: () {
          final payload = _oldConversation(
            id: 'c-extra',
            title: 'Legacy extra',
            source: 'manual-text',
          )..['legacyScore'] = 77;

          final parsed = Conversation.fromJson(payload);
          expect(parsed.title, 'Legacy extra');
        },
      ),
      (
        name: 'legacy ISO timestamps preserve absolute instant',
        run: () {
          final ts = '2025-06-01T10:00:00+02:00';
          final payload = _oldConversation(
            id: 'c-ts',
            title: 'TZ',
            source: 'manual-text',
            startedAt: ts,
            endedAt: ts,
          );
          final parsed = Conversation.fromJson(payload);
          expect(parsed.startedAt.toUtc().hour, 8);
        },
      ),
      (
        name: 'legacy search result list can roundtrip through JSON',
        run: () {
          final list = oldConversationFixtures.take(2).toList();
          final encoded = jsonEncode(list);
          final decoded = (jsonDecode(encoded) as List)
              .cast<Map>()
              .map(
                (item) =>
                    Conversation.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList();
          expect(decoded, hasLength(2));
        },
      ),
      (
        name: 'legacy participant identifiers default to empty list',
        run: () {
          final parsed = Participant.fromJson({
            'id': 'p-legacy',
            'displayName': 'Legacy User',
          });
          expect(parsed.identifiers, isEmpty);
        },
      ),
      (
        name: 'legacy saved search without source filter still works',
        run: () {
          final parsed = SavedSearch.fromJson({
            'id': 's-legacy',
            'title': 'Legacy Search',
            'query': 'legacy query',
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          });
          expect(parsed.source, isNull);
        },
      ),
      (
        name:
            'legacy saved search predating the date-range filter still '
            'loads with a null range',
        run: () {
          final parsed = SavedSearch.fromJson({
            'id': 's-pre-date-range',
            'title': 'Legacy Search',
            'query': 'legacy query',
            'source': 'email',
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          });
          expect(parsed.from, isNull);
          expect(parsed.to, isNull);
          expect(parsed.source, 'email');
        },
      ),
      (
        name: 'saved search with a date range round-trips through JSON',
        run: () {
          final original = SavedSearch(
            id: 's-range',
            title: 'Ranged search',
            query: 'roadmap',
            from: DateTime.utc(2026, 3, 1),
            to: DateTime.utc(2026, 3, 31),
          );
          final roundTripped = SavedSearch.fromJson(original.toJson());
          expect(roundTripped.from, original.from);
          expect(roundTripped.to, original.to);
        },
      ),
      (
        name: 'legacy relation without conversation id remains valid',
        run: () {
          final parsed = RelationEdge.fromJson({
            'id': 'r-legacy',
            'subject': 'A',
            'relation': 'friend',
            'object': 'B',
            'evidence': 'legacy',
            'confidence': 0.5,
          });
          expect(parsed.evidenceConversationId, isNull);
        },
      ),
      (
        name: 'legacy segment without offset defaults to zero',
        run: () {
          final parsed = ConversationSegment.fromJson({
            'id': 'seg-legacy',
            'text': 'line',
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          });
          expect(parsed.offsetMs, 0);
        },
      ),
    ];

    for (final migrationTest in migrationTests) {
      test(migrationTest.name, migrationTest.run);
    }

    final serviceCompatibilityTests = <({String name, Future<void> Function() run})>[
      (
        name:
            'search and searchPaged return same first item for identical criteria',
        run: () async {
          final state = _stateWithLegacyData();
          final full = state.search('release');
          final page = state.searchPaged('release', page: 1, pageSize: 1);
          expect(page.items.first.id, full.first.id);
        },
      ),
      (
        name: 'search ranking keeps stable order for repeated query',
        run: () async {
          final state = _stateWithLegacyData();
          final first = state.search('roadmap').map((c) => c.id).toList();
          final second = state.search('roadmap').map((c) => c.id).toList();
          expect(second, first);
        },
      ),
      (
        name: 'search filter by source behaves same as legacy expectation',
        run: () async {
          final state = _stateWithLegacyData();
          final filtered = state.search('release', source: 'email');
          expect(filtered.every((c) => c.source == 'email'), isTrue);
        },
      ),
      (
        name: 'search filter by participant behaves same as legacy expectation',
        run: () async {
          final state = _stateWithLegacyData();
          final filtered = state.search('release', participantId: 'p-alice');
          expect(filtered, isNotEmpty);
          expect(
            filtered.every((c) => c.participantIds.contains('p-alice')),
            isTrue,
          );
        },
      ),
      (
        name: 'search filter by tag behaves same as legacy expectation',
        run: () async {
          final state = _stateWithLegacyData();
          final filtered = state.search('release', tag: 'work');
          expect(filtered, isNotEmpty);
          expect(filtered.every((c) => c.tags.contains('work')), isTrue);
        },
      ),
      (
        name: 'search favoritesOnly flag still limits result set',
        run: () async {
          final state = _stateWithLegacyData();
          final favorites = state.search('release', favoritesOnly: true);
          expect(favorites.every((c) => c.isFavorite), isTrue);
        },
      ),
      (
        name: 'old app state participant name fallback remains usable',
        run: () async {
          final state = _stateWithLegacyData();
          expect(state.participantName('missing-id'), 'missing-id');
        },
      ),
      (
        name: 'old app state addSavedSearch still creates local saved search',
        run: () async {
          final state = _stateWithLegacyData();
          await state.addSavedSearch(title: 'Legacy save', query: 'release');
          expect(
            state.savedSearches.map((s) => s.title),
            contains('Legacy save'),
          );
        },
      ),
      (
        name: 'old app state addManualText still creates local conversation',
        run: () async {
          final state = _stateWithLegacyData();
          final before = state.conversations.length;
          await state.addManualText(
            title: 'Legacy manual',
            participantNames: 'Alice',
            text: 'legacy manual text',
          );
          expect(state.conversations.length, greaterThan(before));
        },
      ),
      (
        name: 'search behavior remains unchanged when vector scoring disabled',
        run: () async {
          final state = _stateWithLegacyData();
          final vectorOff = state.search('release roadmap', useVector: false);
          final vectorOn = state.search('release roadmap', useVector: true);
          expect(vectorOff.first.id, vectorOn.first.id);
        },
      ),
    ];

    for (final compatibilityTest in serviceCompatibilityTests) {
      test(compatibilityTest.name, compatibilityTest.run);
    }
  });
}

Map<String, dynamic> _oldConversation({
  required String id,
  required String title,
  required String source,
  List<String> participantIds = const [],
  List<Map<String, dynamic>>? segments,
  List<String> tags = const [],
  List<String> artifactNames = const [],
  bool isFavorite = false,
  String? startedAt,
  String? endedAt,
}) {
  return {
    'id': id,
    'title': title,
    'source': source,
    'participantIds': participantIds,
    'segments':
        segments ??
        [
          {
            'id': 'seg-$id',
            'text': 'legacy segment for $title',
            'offsetMs': 0,
            'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          },
        ],
    'artifactNames': artifactNames,
    'tags': tags,
    'isFavorite': isFavorite,
    'startedAt': startedAt ?? DateTime.utc(2026, 1, 1).toIso8601String(),
    'endedAt': endedAt ?? DateTime.utc(2026, 1, 1).toIso8601String(),
  };
}

Map<String, dynamic> _migrateConversationV1ToV2(Map<String, dynamic> v1) {
  final migrated = Map<String, dynamic>.from(v1);
  migrated['tags'] = List<String>.from(
    migrated['tags'] as List? ?? [migrated['source']],
  );
  migrated['artifactNames'] = List<String>.from(
    migrated['artifactNames'] as List? ?? const <String>[],
  );
  migrated['isFavorite'] = migrated['isFavorite'] as bool? ?? false;
  return migrated;
}

Map<String, dynamic> _legacyImportToConversationJson(
  Map<String, dynamic> legacyImport,
) {
  final segments = (legacyImport['segments'] as List).cast<Map>().map((
    segment,
  ) {
    final map = Map<String, dynamic>.from(segment);
    return {
      'id': 'seg-${map['offsetMs'] ?? 0}',
      'text': map['text'] as String,
      'participantId': null,
      'offsetMs': map['offsetMs'] as int? ?? 0,
      'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
    };
  }).toList();

  return {
    'id': 'import-${legacyImport['title']}',
    'title': legacyImport['title'],
    'source': legacyImport['source'],
    'participantIds': const <String>[],
    'segments': segments,
    'artifactNames': const <String>[],
    'tags': [legacyImport['source']],
    'isFavorite': false,
    'startedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
    'endedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
  };
}

LifenizerAppState _stateWithLegacyData() {
  final state = LifenizerAppState();
  state.participants.addAll([
    Participant(id: 'p-alice', displayName: 'Alice'),
    Participant(id: 'p-bob', displayName: 'Bob'),
  ]);

  final now = DateTime.now().toUtc();
  state.conversations.addAll([
    Conversation(
      id: 'c-1',
      title: 'Release roadmap',
      source: 'email',
      participantIds: const ['p-alice'],
      tags: const ['work'],
      isFavorite: true,
      segments: [
        ConversationSegment(id: 's-1', text: 'release roadmap details'),
      ],
      startedAt: now.subtract(const Duration(days: 2)),
      endedAt: now.subtract(const Duration(days: 2)),
    ),
    Conversation(
      id: 'c-2',
      title: 'Release follow up',
      source: 'chat',
      participantIds: const ['p-alice', 'p-bob'],
      tags: const ['work'],
      segments: [
        ConversationSegment(id: 's-2', text: 'release blockers and roadmap'),
      ],
      startedAt: now.subtract(const Duration(days: 1)),
      endedAt: now.subtract(const Duration(days: 1)),
    ),
    Conversation(
      id: 'c-3',
      title: 'Weekend plans',
      source: 'manual-text',
      participantIds: const ['p-bob'],
      tags: const ['personal'],
      segments: [ConversationSegment(id: 's-3', text: 'shopping list')],
      startedAt: now.subtract(const Duration(days: 3)),
      endedAt: now.subtract(const Duration(days: 3)),
    ),
  ]);
  return state;
}
