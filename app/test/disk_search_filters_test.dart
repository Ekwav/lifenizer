import 'dart:io';

import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  final now = DateTime.utc(2026, 10, 29);
  final key = List<int>.generate(32, (i) => i);
  late Directory directory;
  late String path;
  late DiskSearchIndex disk;
  Conversation document(int i) => Conversation(
    id: 'document-${i.toString().padLeft(4, '0')}',
    title: 'Archive',
    source: const [
      'email',
      'discord',
      'youtube-transcript',
      'paperless',
      'manual',
    ][i % 5],
    participantIds: [i % 200 == 0 ? 'alice' : 'bob'],
    tags: i % 271 == 0 ? const ['Work'] : const [],
    isFavorite: i % 333 == 0,
    location: i % 317 == 0
        ? RecordingLocation(town: i.isEven ? 'Berlin' : 'Hamburg')
        : null,
    startedAt: now.subtract(Duration(minutes: i)),
    endedAt: now.subtract(Duration(minutes: i)),
    segments: [
      ConversationSegment(id: 's-$i', text: 'Common archive contents'),
    ],
  );
  Future<List<Conversation>> search(SearchCriteria criteria) {
    final tokens = ConversationSearchIndex.tokenize(criteria.normalized);
    return disk.search(
      criteria,
      SearchScorer(
        temporalIntent: null,
        normalizedQuery: criteria.normalized,
        now: now,
      ),
      tokens,
      tokens.join(' '),
    );
  }

  Future<void> seed() async {
    await disk.upsert(
      List.generate(1300, document),
      participantById: const {'alice': 'Alice', 'bob': 'Bob'},
      relationTextByConversation: const {},
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('search-filters-');
    path = '${directory.path}/search.sqlite';
    disk = await DiskSearchIndex.open(path: path, vaultKey: key);
  });
  tearDown(() async {
    await disk.close();
    await directory.delete(recursive: true);
  });

  test('sparse facets restrict decoded pages before ranking', () async {
    await seed();
    final cases = <(SearchCriteria, bool Function(Conversation))>[
      (
        SearchCriteria(query: 'archive', favoritesOnly: true),
        (c) => c.isFavorite,
      ),
      (
        SearchCriteria(query: 'archive', participantId: 'alice'),
        (c) => c.participantIds.contains('alice'),
      ),
      (
        SearchCriteria(query: 'archive', tag: '  WORK  '),
        (c) => c.tags.contains('Work'),
      ),
      (
        SearchCriteria(query: 'archive town:Berlin'),
        (c) => c.location?.town == 'Berlin',
      ),
      (
        SearchCriteria(query: '', participantId: 'alice'),
        (c) => c.participantIds.contains('alice'),
      ),
    ];
    for (final (criteria, accepts) in cases) {
      final expected = List.generate(
        1300,
        document,
      ).where(accepts).map((c) => c.id);
      final found = await search(criteria);
      expect(
        found.map((c) => c.id),
        unorderedEquals(expected),
        reason: '$criteria',
      );
      // The location presence bitmap is conservative; both towns remain eligible.
      final limit = criteria.locationLabels.isNotEmpty ? 5 : expected.length;
      expect(
        (await disk.searchProfile)['summarypagesReads'] ?? 0,
        lessThanOrEqualTo(limit),
      );
    }
    await disk.upsert(
      [
        Conversation.fromJson({
          ...document(0).toJson(),
          'source': 'youtube-transcript',
        }),
      ],
      participantById: const {},
      relationTextByConversation: const {},
    );
    expect(
      (await search(
        SearchCriteria(
          query: 'archive',
          favoritesOnly: true,
          includeConsumed: false,
        ),
      )).map((c) => c.id),
      unorderedEquals([document(333).id, document(666).id, document(999).id]),
    );
    expect(
      (await disk.searchProfile)['summarypagesReads'] ?? 0,
      lessThanOrEqualTo(3),
    );
    expect(
      await search(
        SearchCriteria(
          query: 'archive',
          source: 'group:chat',
          participantId: 'alice',
        ),
      ),
      isEmpty,
    );
    expect((await disk.searchProfile)['summarypagesReads'] ?? 0, 0);
    expect(
      await search(
        SearchCriteria(
          query: 'archive',
          source: 'group:consumed',
          includeConsumed: false,
        ),
      ),
      isEmpty,
    );
  });

  test(
    'updates remove old facet memberships and survive reopen and removal',
    () async {
      await seed();
      final updated = Conversation(
        id: document(0).id,
        title: 'Archive',
        source: 'photo',
        participantIds: const ['carol'],
        tags: const ['Updated'],
        startedAt: now,
        endedAt: now,
        segments: [
          ConversationSegment(id: 'new', text: 'New archive contents'),
        ],
      );
      await disk.upsert(
        [updated],
        participantById: const {'carol': 'Carol'},
        relationTextByConversation: const {},
      );
      await disk.close();
      disk = await DiskSearchIndex.open(path: path, vaultKey: key);
      for (final criteria in [
        SearchCriteria(query: 'archive', favoritesOnly: true),
        SearchCriteria(query: 'archive', participantId: 'alice'),
        SearchCriteria(query: 'archive', tag: 'work'),
        SearchCriteria(query: 'archive town:Berlin'),
      ]) {
        expect(
          (await search(criteria)).map((c) => c.id),
          isNot(contains(updated.id)),
        );
      }
      expect(
        (await search(
          SearchCriteria(
            query: 'archive',
            source: 'photo',
            participantId: 'carol',
            tag: 'updated',
          ),
        )).single.id,
        updated.id,
      );
      await disk.remove([updated.id]);
      expect(
        await search(SearchCriteria(query: 'archive', source: 'photo')),
        isEmpty,
      );
      await disk.clear();
      await disk.upsert(
        [document(0)],
        participantById: const {},
        relationTextByConversation: const {},
      );
      expect(
        (await search(
          SearchCriteria(query: 'archive', favoritesOnly: true),
        )).single.id,
        document(0).id,
      );
    },
  );

  test('facet write failures roll back documents and resume migration', () async {
    await seed();
    await disk.close();
    var db = sql.sqlite3.open(path);
    db.execute(
      "CREATE TRIGGER reject_filters BEFORE INSERT ON filterpostings BEGIN SELECT RAISE(ABORT, 'facet fault'); END",
    );
    db.close();
    disk = await DiskSearchIndex.open(path: path, vaultKey: key);
    await expectLater(
      disk.upsert(
        [
          Conversation(
            id: document(0).id,
            title: 'Changed',
            source: 'photo',
            participantIds: const [],
            segments: const [],
          ),
        ],
        participantById: const {},
        relationTextByConversation: const {},
      ),
      throwsStateError,
    );
    expect(
      (await search(
        SearchCriteria(query: 'archive', favoritesOnly: true),
      )).map((c) => c.id),
      contains(document(0).id),
    );
    expect(await search(SearchCriteria(query: 'changed')), isEmpty);
    await disk.close();
    db = sql.sqlite3.open(path);
    db.execute('DROP TRIGGER reject_filters');
    db.execute('DELETE FROM filterpostings');
    db.execute(
      "DELETE FROM metadata WHERE key IN ('_filterVersion', '_filterCursor')",
    );
    db.execute(
      "CREATE TRIGGER interrupt_filters BEFORE INSERT ON filterpostings WHEN NEW.page >= 1 BEGIN SELECT RAISE(ABORT, 'migration fault'); END",
    );
    db.close();
    disk = await DiskSearchIndex.open(path: path, vaultKey: key);
    await expectLater(disk.prepare(), throwsStateError);
    expect(await disk.readMetadata('_filterCursor'), 8);
    expect(await disk.readMetadata('_filterVersion'), isNull);
    await disk.close();
    db = sql.sqlite3.open(path);
    db.execute('DROP TRIGGER interrupt_filters');
    db.close();
    disk = await DiskSearchIndex.open(path: path, vaultKey: key);
    await disk.prepare();
    expect(await disk.readMetadata('_filterVersion'), 1);
    expect(await disk.readMetadata('_filterCursor'), isNull);
    expect(
      (await search(
        SearchCriteria(query: 'archive', favoritesOnly: true),
      )).map((c) => c.id),
      unorderedEquals([
        document(0).id,
        document(333).id,
        document(666).id,
        document(999).id,
      ]),
    );
  });
}
