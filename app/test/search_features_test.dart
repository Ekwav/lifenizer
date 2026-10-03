import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/api_client.dart';
import 'package:app/services/local_vault_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast_memory.dart';

Conversation _conv({
  required String id,
  required String title,
  String source = 'manual',
  List<String> tags = const [],
  List<ConversationSegment> segments = const [],
  List<String> participantIds = const [],
  DateTime? at,
}) {
  return Conversation(
    id: id,
    title: title,
    source: source,
    participantIds: participantIds,
    tags: tags,
    segments: segments,
    startedAt: at ?? DateTime.utc(2026, 1, 1),
    endedAt: at ?? DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('relevance priorities', () {
    test('prefers same time last year when query asks for it', () {
      final state = LifenizerAppState();
      final now = DateTime.now().toUtc();
      final lastYear = _safeLastYear(now);

      state.conversations.addAll([
        _conv(
          id: 'last-year',
          title: 'Importer retrospective',
          segments: [ConversationSegment(id: 's1', text: 'Importer status')],
          at: lastYear,
        ),
        _conv(
          id: 'recent',
          title: 'Importer retrospective',
          segments: [ConversationSegment(id: 's2', text: 'Importer status')],
          at: now.subtract(const Duration(days: 2)),
        ),
      ]);

      final hits = state.search('importer same time last year');
      expect(hits, hasLength(2));
      expect(hits.first.id, 'last-year');
    });

    test('can reuse last search context with carryover phrase', () {
      final state = LifenizerAppState();
      state.conversations.addAll([
        _conv(
          id: 'atlas',
          title: 'Project Atlas timeline',
          segments: [
            ConversationSegment(id: 's1', text: 'Atlas importer roadmap'),
          ],
        ),
        _conv(
          id: 'zeus',
          title: 'Project Zeus timeline',
          segments: [
            ConversationSegment(id: 's2', text: 'Zeus importer roadmap'),
          ],
        ),
      ]);

      final first = state.search('atlas importer roadmap');
      expect(first.first.id, 'atlas');

      final followUp = state.search('same as before timeline');
      expect(followUp.first.id, 'atlas');
    });
  });

  test(
    'German participant and topic search rebuild after encrypted offline unlock',
    () async {
      final database = await databaseFactoryMemory.openDatabase('search-vault');
      final store = LocalVaultStore(database);
      final client = MockClient((request) async {
        if (request.url.path == '/api/auth/dev-login') {
          return http.Response(
            jsonEncode({
              'authToken': 'token',
              'userId': 'user',
              'vaultId': 'vault',
              'vaultSalt': 'search-salt',
            }),
            200,
          );
        }
        if (request.url.path == '/api/sync/pull') {
          return http.Response(jsonEncode({'cursor': 0, 'envelopes': []}), 200);
        }
        if (request.url.path == '/api/imports/capabilities') {
          return http.Response('[]', 200);
        }
        return http.Response('not found', 404);
      });
      final state = LifenizerAppState(
        localStore: store,
        apiFactory: (baseUrl) =>
            LifenizerApiClient(baseUrl: baseUrl, client: client),
      );
      await state.login(
        baseUrl: 'http://localhost:5075',
        email: 'search@example.test',
        passphrase: 'private-search-test',
      );
      expect(state.error, isNull);
      state.participants.add(
        Participant(id: 'jorg', displayName: 'Jörg Müller'),
      );
      state.conversations.addAll([
        _conv(
          id: 'insurance',
          title: 'Versicherung erneuern',
          participantIds: ['jorg'],
        ),
        _conv(id: 'holiday', title: 'Urlaub planen'),
        _conv(
          id: 'insurance-older',
          title: 'Versicherung erneuern',
          participantIds: ['jorg'],
          at: DateTime(2020),
        ),
      ]);
      final original = state
          .search('versicherung jorg')
          .map((c) => c.id)
          .toList();
      expect(original, ['insurance', 'insurance-older']);
      expect(state.search('versicherung jorg').map((c) => c.id), original);
      await state.pullSync(); // Persists the encrypted snapshot before locking.
      await state.lock();
      expect(state.search('versicherung'), isEmpty);
      await state.login(
        baseUrl: 'http://localhost:5075',
        email: 'search@example.test',
        passphrase: 'private-search-test',
        offline: true,
      );
      expect(state.error, isNull);
      expect(state.search('versicherung jorg').map((c) => c.id), original);
      expect(state.search('urlaub').map((c) => c.id), ['holiday']);
      expect(state.search('muell versicher').map((c) => c.id), original);
      await state.lock();
      await database.close();
      client.close();
    },
  );

  group('query independence and literal topics', () {
    test('switching to an unrelated short query has no carried tokens', () {
      final state = LifenizerAppState();
      state.conversations.addAll([
        _conv(id: 'insurance', title: 'Insurance renewal'),
        _conv(id: 'holiday', title: 'Holiday planning'),
      ]);
      expect(state.search('insurance').map((c) => c.id), ['insurance']);
      expect(state.search('holiday').map((c) => c.id), ['holiday']);
      expect(state.search('insurance').map((c) => c.id), ['insurance']);
    });

    test('time and search remain searchable literal topics', () {
      final state = LifenizerAppState();
      state.conversations.addAll([
        _conv(id: 'time', title: 'Time travel'),
        _conv(id: 'search', title: 'Search algorithms'),
        _conv(id: 'other', title: 'Holiday plans'),
      ]);
      expect(state.search('time travel').map((c) => c.id), ['time']);
      expect(state.search('search algorithms').map((c) => c.id), ['search']);
    });

    test(
      'a temporal-only query finds dated conversations without literal today',
      () {
        final state = LifenizerAppState();
        state.conversations.addAll([
          _conv(id: 'old', title: 'Old review', at: DateTime(2020)),
          _conv(id: 'now', title: 'Current review', at: DateTime.now()),
        ]);
        expect(state.search('today').first.id, 'now');
        expect(state.search('heute').first.id, 'now');
      },
    );
  });

  group('indexed search', () {
    test('picks up conversations added after first query', () {
      final state = LifenizerAppState();
      state.conversations.add(_conv(id: 'a', title: 'First entry'));

      expect(state.search('second'), isEmpty);

      state.conversations.add(_conv(id: 'b', title: 'Second entry'));
      final hits = state.search('second');
      expect(hits.map((item) => item.id), ['b']);
    });

    test('vector scoring can be toggled', () {
      final state = LifenizerAppState();
      state.conversations.addAll([
        _conv(
          id: 'a',
          title: 'Importer plan',
          segments: [
            ConversationSegment(
              id: 's1',
              text: 'search index plan with importer coverage',
            ),
          ],
        ),
        _conv(
          id: 'b',
          title: 'Importer plan plan plan',
          segments: [
            ConversationSegment(id: 's2', text: 'index tuning and ranking'),
          ],
        ),
      ]);

      final lexical = state.search('importer plan', useVector: false);
      final vector = state.search('importer plan', useVector: true);

      expect(lexical, hasLength(2));
      expect(vector, hasLength(2));
      expect(
        vector.map((item) => item.id).toSet(),
        equals(lexical.map((item) => item.id).toSet()),
      );
    });
  });

  group('fuzzy search', () {
    test('matches with single-character typo', () {
      final state = LifenizerAppState();
      state.conversations.add(_conv(id: 'a', title: 'Insurance policy'));

      // "polcy" → 1 edit away from "policy"
      final hits = state.search('polcy');
      expect(hits, hasLength(1));
      expect(hits.first.id, 'a');
    });

    test('matches longer tokens within 2 edits', () {
      final state = LifenizerAppState();
      state.conversations.add(_conv(id: 'a', title: 'September minutes'));

      final hits = state.search('Septmbr');
      expect(hits, hasLength(1));
    });

    test('rejects unrelated terms', () {
      final state = LifenizerAppState();
      state.conversations.add(_conv(id: 'a', title: 'Insurance policy'));

      final hits = state.search('banana');
      expect(hits, isEmpty);
    });

    test('all query tokens must match', () {
      final state = LifenizerAppState();
      state.conversations.addAll([
        _conv(id: 'a', title: 'Insurance policy'),
        _conv(id: 'b', title: 'Vehicle insurance renewal'),
      ]);

      final hits = state.search('insurance vehicle');
      expect(hits.map((c) => c.id), ['b']);
    });

    test('short tokens require substring match', () {
      final state = LifenizerAppState();
      state.conversations.add(_conv(id: 'a', title: 'Receipts only'));

      // "xy" is too short for fuzzy to kick in
      final hits = state.search('xy');
      expect(hits, isEmpty);
    });
  });

  group('person search (lookup by who was involved)', () {
    LifenizerAppState buildStateWithAlice() {
      final state = LifenizerAppState();
      state.participants.add(Participant(id: 'p-alice', displayName: 'Alice'));
      state.conversations.add(
        Conversation(
          id: 'c-alice',
          title: 'Weekly status',
          source: 'manual-text',
          participantIds: const ['p-alice'],
          segments: [
            ConversationSegment(
              id: 's-1',
              text: 'quarterly numbers looked fine this time around',
            ),
          ],
          startedAt: DateTime.utc(2026, 1, 1),
          endedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      return state;
    }

    test('finds a conversation by participant display name even though the '
        'name never appears in the message text', () {
      final state = buildStateWithAlice();
      final hits = state.search('alice');
      expect(hits.map((c) => c.id), contains('c-alice'));
    });

    test('participant name search is case-insensitive', () {
      final state = buildStateWithAlice();
      final hits = state.search('ALICE');
      expect(hits.map((c) => c.id), contains('c-alice'));
    });

    test('participant name search matches a partial name fragment', () {
      final state = buildStateWithAlice();
      final hits = state.search('ali');
      expect(hits.map((c) => c.id), contains('c-alice'));
    });

    test('partial participant name search still works alongside unrelated '
        'conversations that could pollute the candidate lookup', () {
      final state = buildStateWithAlice();
      // Add extra conversations with short, unrelated tokens (e.g. "all")
      // that are within edit-distance of the partial query "ali", to make
      // sure the match isn't only working by accident because the index
      // had no other candidates for that token.
      state.conversations.addAll([
        _conv(id: 'other-1', title: 'Buy all the groceries'),
        _conv(id: 'other-2', title: 'Align the calendars'),
      ]);
      final hits = state.search('ali');
      expect(hits.map((c) => c.id), contains('c-alice'));
    });
  });

  group('combined lookup keys (keyword + person + time)', () {
    test(
      'a typo\'d keyword combined with a participant name narrows correctly',
      () {
        final state = LifenizerAppState();
        final alice = Participant(id: 'p-alice', displayName: 'Alice');
        final bob = Participant(id: 'p-bob', displayName: 'Bob');
        state.participants.addAll([alice, bob]);
        state.conversations.addAll([
          _conv(
            id: 'alice-insurance',
            title: 'Insurance policy renewal',
            segments: [
              ConversationSegment(
                id: 's1',
                text: 'insurance policy renewal notes',
              ),
            ],
            participantIds: const ['p-alice'],
          ),
          _conv(
            id: 'bob-insurance',
            title: 'Insurance policy renewal',
            segments: [
              ConversationSegment(
                id: 's2',
                text: 'insurance policy renewal notes',
              ),
            ],
            participantIds: const ['p-bob'],
          ),
        ]);

        // "polcy" is a typo of "policy" (not present verbatim) but should
        // still fuzzy-match the "insurance" family of conversations combined
        // with "Alice" mentioned in the query text.
        final hits = state.search('polcy alice');
        expect(hits.map((c) => c.id), ['alice-insurance']);
      },
    );

    test('keyword + participant filter + date range narrows to only the '
        'conversation matching all three', () {
      final state = LifenizerAppState();
      final alice = Participant(id: 'p-alice', displayName: 'Alice');
      final bob = Participant(id: 'p-bob', displayName: 'Bob');
      state.participants.addAll([alice, bob]);

      final inRange = DateTime.utc(2026, 3, 10);
      final outOfRange = DateTime.utc(2026, 1, 1);

      Conversation roadmap({
        required String id,
        required List<String> participantIds,
        required DateTime at,
      }) => Conversation(
        id: id,
        title: 'Roadmap sync',
        source: 'manual-text',
        participantIds: participantIds,
        segments: [
          ConversationSegment(id: '$id-seg', text: 'roadmap discussion'),
        ],
        startedAt: at,
        endedAt: at,
      );

      state.conversations.addAll([
        // Matches keyword + participant + date.
        roadmap(id: 'match', participantIds: const ['p-alice'], at: inRange),
        // Right keyword + participant, wrong date.
        roadmap(
          id: 'wrong-date',
          participantIds: const ['p-alice'],
          at: outOfRange,
        ),
        // Right keyword + date, wrong participant.
        roadmap(
          id: 'wrong-participant',
          participantIds: const ['p-bob'],
          at: inRange,
        ),
        // Right participant + date, wrong keyword.
        Conversation(
          id: 'wrong-keyword',
          title: 'Weekend plans',
          source: 'manual-text',
          participantIds: const ['p-alice'],
          segments: [
            ConversationSegment(
              id: 'wrong-keyword-seg',
              text: 'grocery shopping',
            ),
          ],
          startedAt: inRange,
          endedAt: inRange,
        ),
      ]);

      final results = state.search(
        'roadmap',
        participantId: 'p-alice',
        from: DateTime.utc(2026, 3, 1),
        to: DateTime.utc(2026, 3, 31),
      );

      expect(results.map((c) => c.id), ['match']);
    });
  });

  group('searchPaged', () {
    LifenizerAppState buildState(int total) {
      final state = LifenizerAppState();
      for (var i = 0; i < total; i++) {
        state.conversations.add(
          _conv(
            id: 'c-$i',
            title: 'Note $i',
            at: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
          ),
        );
      }
      return state;
    }

    test('returns the first page by default', () {
      final state = buildState(25);
      final page = state.searchPaged('Note');

      expect(page.page, 1);
      expect(page.pageSize, 10);
      expect(page.total, 25);
      expect(page.items, hasLength(10));
      expect(page.totalPages, 3);
      expect(page.hasPrevious, isFalse);
      expect(page.hasNext, isTrue);
    });

    test('returns subsequent pages', () {
      final state = buildState(25);

      final second = state.searchPaged('Note', page: 2);
      expect(second.items, hasLength(10));
      expect(second.hasPrevious, isTrue);
      expect(second.hasNext, isTrue);

      final last = state.searchPaged('Note', page: 3);
      expect(last.items, hasLength(5));
      expect(last.hasNext, isFalse);
    });

    test('clamps out-of-range pages to empty slice with total preserved', () {
      final state = buildState(5);

      final page = state.searchPaged('Note', page: 99, pageSize: 2);
      expect(page.items, isEmpty);
      expect(page.total, 5);
      expect(page.page, 99);
    });

    test('respects custom pageSize', () {
      final state = buildState(12);

      final page = state.searchPaged('Note', pageSize: 5);
      expect(page.items, hasLength(5));
      expect(page.totalPages, 3);
    });
  });
}

DateTime _safeLastYear(DateTime now) {
  final targetYear = now.year - 1;
  final lastDay = DateTime.utc(targetYear, now.month + 1, 0).day;
  final day = now.day > lastDay ? lastDay : now.day;
  return DateTime.utc(targetYear, now.month, day, now.hour);
}
