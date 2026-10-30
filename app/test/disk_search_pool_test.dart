import 'dart:io';

import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  late Directory directory;
  late DiskSearchIndex index;
  final key = List<int>.generate(32, (i) => i);
  final now = DateTime.utc(2026, 10, 28);
  final people = {'oliver': 'Oliver Thompson'};
  final docs = [
    for (var n = 0; n < 512; n++)
      Conversation(
        id: 'pool-${n.toString().padLeft(4, '0')}',
        title: n % 7 == 0 ? 'Import archive' : 'Archive ${n % 11}',
        source: const [
          'manual',
          'imap',
          'discord',
          'scanned-pdf',
          'browser-history',
        ][n % 5],
        participantIds: [if (n % 17 == 0) 'oliver'],
        tags: [if (n % 7 == 0) 'project'],
        isFavorite: n % 13 == 0,
        startedAt: now.subtract(Duration(microseconds: n % 23)),
        endedAt: now,
        segments: [
          ConversationSegment(
            id: 's-$n',
            text: [
              n == 0 ? 'spectral' : 'spectrality',
              for (var k = 0; k < 4 + n % 7; k++) 'import',
              'archive grocery shopping project',
              if (n % 3 == 0) 'shopping grocery',
              if (n % 17 == 0) 'oliver thompson',
            ].join(' '),
          ),
        ],
      ),
  ];
  SearchScorer scorer(SearchCriteria c) => SearchScorer(
    temporalIntent: null,
    normalizedQuery: c.normalized,
    now: now,
  );
  Future<List<String>> search(
    SearchCriteria c, {
    DiskSearchIndex? target,
  }) async {
    final tokens = ConversationSearchIndex.tokenize(c.normalized);
    return (await (target ?? index).search(
      c,
      scorer(c),
      tokens,
      tokens.join(' '),
    )).map((doc) => doc.id).toList();
  }

  List<String> canonical(SearchCriteria c, [List<Conversation>? records]) {
    final reference = ConversationSearchIndex.build(
      conversations: records ?? docs,
      participantById: people,
      relationTextByConversation: const {},
    );
    final tokens = ConversationSearchIndex.tokenize(c.normalized);
    return SearchService(reference)
        .rankConversations(
          c,
          scorer(c),
          tokens,
          tokens.join(' '),
          maxResults: 100,
        )
        .map((doc) => doc.id)
        .toList();
  }

  Future<void> seed() => index.upsert(
    docs,
    participantById: people,
    relationTextByConversation: const {},
  );
  String getPath() => '${directory.path}/index.sqlite';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('disk-search-pool-test-');
    index = await DiskSearchIndex.open(
      path: getPath(),
      vaultKey: key,
      searchWorkers: 4,
    );
    await seed();
  });
  tearDown(() async {
    await index.close();
    await directory.delete(recursive: true);
  });

  test(
    'automatic resource policy keeps small vaults serial and caps large pools',
    () async {
      for (final processors in [0, 1, 2, 4, 8, 32]) {
        expect(DiskSearchIndex.automaticSearchWorkers(249999, processors), 1);
      }
      expect(DiskSearchIndex.automaticSearchWorkers(250000, 0), 1);
      expect(DiskSearchIndex.automaticSearchWorkers(250000, 1), 1);
      expect(DiskSearchIndex.automaticSearchWorkers(250000, 2), 2);
      expect(DiskSearchIndex.automaticSearchWorkers(250000, 4), 4);
      expect(DiskSearchIndex.automaticSearchWorkers(250000, 32), 8);
      expect(DiskSearchIndex.automaticSearchWorkers(2000000, 8), 8);
      await index.close();
      index = await DiskSearchIndex.open(path: getPath(), vaultKey: key);
      final criteria = SearchCriteria(query: 'archive import');
      expect(await search(criteria), canonical(criteria));
      final profile = await index.searchProfile;
      expect(profile['automaticSearchWorkers'], 1);
      expect(profile['searchWorkers'], 1);
      expect(profile['configuredSearchWorkers'], 1);
      expect(profile['phaseTimesAreWorkSums'], 0);
      expect(profile['sqliteCacheTotalBudgetKiB'], 16384);
      expect(profile['postingPayloadCacheTotalLimitBytes'], 16 * 1024 * 1024);
    },
  );

  test(
    'range workers preserve canonical global scores, facets and total cache budget',
    () async {
      for (final c in [
        SearchCriteria(query: 'archive import'),
        SearchCriteria(query: 'import archive'),
        SearchCriteria(query: 'archive archive'),
        SearchCriteria(query: 'olivr thompson'),
        SearchCriteria(query: 'grocery shopping'),
        SearchCriteria(query: 'import', source: 'group:email'),
        SearchCriteria(query: 'archive', includeConsumed: false),
        SearchCriteria(query: 'archive', favoritesOnly: true),
        SearchCriteria(query: 'archive', tag: 'project'),
        SearchCriteria(query: ''),
        SearchCriteria(query: '', source: 'group:chat'),
      ]) {
        expect(await search(c), canonical(c), reason: c.normalized);
        if (c.isEmptyQuery && c.normalizedSource == null) {
          final recentProfile = await index.searchProfile;
          expect(recentProfile['searchWorkers'], 1);
          expect(recentProfile['configuredSearchWorkers'], 4);
          expect(
            recentProfile['postingPayloadCacheTotalLimitBytes'],
            4 * 16 * 1024 * 1024,
          );
        }
      }
      await search(SearchCriteria(query: 'archive import'));
      final profile = await index.searchProfile;
      expect(profile['searchWorkers'], 4);
      expect(profile['automaticSearchWorkers'], 0);
      expect(profile['primaryNumericCacheBytesAfterRelease'], 0);
      expect(profile['configuredSearchWorkers'], 4);
      expect(profile['phaseTimesAreWorkSums'], 1);
      expect(profile['sqliteCacheTotalBudgetKiB'], 16384);
      expect(
        profile['postingPayloadCacheTotalLimitBytes'],
        4 * 16 * 1024 * 1024,
      );
      expect(profile['sqliteCacheKiB'], 16384);
      final state = (await index.readMetadata('_state')) as List;
      expect(
        profile['numericCachedBytes'],
        ((state[2] as int) + 1023) ~/ 1024 * 40960,
      );
    },
  );

  test(
    'exact word absent from a local range retains the global vector query norm',
    () async {
      for (final c in [
        SearchCriteria(query: 'spectral import'),
        SearchCriteria(query: 'spectral import', source: 'group:chat'),
        SearchCriteria(query: 'spectral import', source: 'group:email'),
        SearchCriteria(query: 'spectral import', includeConsumed: false),
      ]) {
        expect(await search(c), canonical(c));
      }
    },
  );

  test(
    'prepare does not cancel an active query and typing cancellation retains a usable pool',
    () async {
      await index.prepare();
      final c = SearchCriteria(query: 'archive import');
      final active = search(c);
      await index.prepare();
      expect(await active, canonical(c));
      final warmReaders = (await index.searchProfile)['workerIdentity'];
      final obsolete = search(c);
      final latest = search(SearchCriteria(query: 'grocery shopping'));
      expect(await obsolete, isEmpty);
      expect(
        await latest,
        canonical(SearchCriteria(query: 'grocery shopping')),
      );
      final cancelled = search(c);
      await index.cancelSearch();
      expect(await cancelled, isEmpty);
      expect(await search(c), canonical(c));
      expect((await index.searchProfile)['workerIdentity'], warmReaders);
    },
  );

  test(
    'mutation drains readers and a query after the pending write sees its commit',
    () async {
      await index.prepare();
      final obsolete = search(SearchCriteria(query: 'archive import'));
      final changed = Conversation.fromJson({
        ...docs.first.toJson(),
        'title': 'afterchange',
      });
      final write = index.upsert(
        [changed],
        participantById: people,
        relationTextByConversation: const {},
      );
      final latest = search(SearchCriteria(query: 'afterchange'));
      await write;
      expect(await obsolete, isEmpty);
      expect(await latest, [changed.id]);
      await index.remove([changed.id]);
      expect(await search(SearchCriteria(query: 'afterchange')), isEmpty);
      await index.writeMetadata('pool-note', 7);
      expect(await index.readMetadata('pool-note'), 7);
    },
  );

  test(
    'cancel rejects preparation while retaining the initializer and usable pool',
    () async {
      final preparing = expectLater(index.prepare(), throwsStateError);
      await index.count;
      await index.cancelSearch();
      await preparing;
      await index.prepare();
      expect(
        await search(SearchCriteria(query: 'archive')),
        canonical(SearchCriteria(query: 'archive')),
      );
      expect((await index.searchProfile)['searchWorkers'], 4);
    },
  );

  test(
    'cancel and mutation during initialization leave no stale reader snapshot',
    () async {
      final preparing = index.prepare();
      await index
          .count; // Ordered after primary preparation, before reader startup.
      await index.cancelSearch();
      final write = index.writeMetadata('during-init', 9);
      await Future.wait([expectLater(preparing, throwsStateError), write]);
      expect(await index.readMetadata('during-init'), 9);
      expect(
        await search(SearchCriteria(query: 'archive')),
        canonical(SearchCriteria(query: 'archive')),
      );
    },
  );

  test(
    'failed partial reader initialization does not poison clear and rebuild',
    () async {
      final preparing = index.prepare();
      await index
          .count; // Primary warmed every numeric page; readers have not opened.
      final database = sql.sqlite3.open(getPath());
      try {
        database.execute('PRAGMA busy_timeout=1000');
        database.execute(
          'DELETE FROM rankdocuments WHERE id = (SELECT MAX(id) FROM rankdocuments)',
        );
      } finally {
        database.close();
      }
      await expectLater(preparing, throwsStateError);
      // Its failed initialization future must not prevent the repair write.
      await index.clear();
      expect(await index.count, 0);
      await seed();
      expect(
        await search(SearchCriteria(query: 'archive import')),
        canonical(SearchCriteria(query: 'archive import')),
      );
    },
  );

  test(
    'failed mutation reports its error and permits a later write retry',
    () async {
      await index.prepare();
      final invalid = Conversation.fromSummaryJson(docs.last.toSummaryJson());
      final changed = Conversation.fromJson({
        ...docs.first.toJson(),
        'title': 'rolledback',
      });
      await expectLater(
        index.upsert(
          [changed, invalid],
          participantById: people,
          relationTextByConversation: const {},
        ),
        throwsStateError,
      );
      expect(await search(SearchCriteria(query: 'rolledback')), isEmpty);
      await expectLater(index.writeMetadata('_state', null), throwsStateError);
      await index.upsert(
        [changed],
        participantById: people,
        relationTextByConversation: const {},
      );
      expect(await search(SearchCriteria(query: 'rolledback')), [changed.id]);
    },
  );

  test(
    'close drains initialization and queries, is idempotent, and permits clean reopen',
    () async {
      final preparing = index.prepare();
      await index.count;
      final close = index.close();
      await Future.wait([
        expectLater(preparing, throwsStateError),
        close,
        index.close(),
      ]);
      await expectLater(
        search(SearchCriteria(query: 'archive')),
        throwsStateError,
      );
      index = await DiskSearchIndex.open(
        path: getPath(),
        vaultKey: key,
        searchWorkers: 4,
      );
      final active = search(SearchCriteria(query: 'archive import'));
      await index.close();
      expect(await active, isEmpty);
      final database = sql.sqlite3.open(getPath());
      try {
        database.execute('BEGIN EXCLUSIVE');
        database.execute('ROLLBACK');
      } finally {
        database.close();
      }
      index = await DiskSearchIndex.open(
        path: getPath(),
        vaultKey: key,
        searchWorkers: 4,
      );
      expect(
        await search(SearchCriteria(query: 'archive')),
        canonical(SearchCriteria(query: 'archive')),
      );
    },
  );

  test(
    'merged ties use the numeric result timestamp rather than summary time',
    () async {
      await index.clear();
      final base = DateTime.utc(2500).microsecondsSinceEpoch;
      final pair = [
        for (var i = 0; i < 2; i++)
          Conversation(
            id: i == 0 ? 'a' : 'b',
            title: 'Archive',
            source: i == 0 ? 'manual' : 'discord',
            participantIds: const [],
            startedAt: DateTime.fromMicrosecondsSinceEpoch(
              base + i,
              isUtc: true,
            ),
            endedAt: DateTime.fromMicrosecondsSinceEpoch(base + i, isUtc: true),
            segments: [ConversationSegment(id: 's', text: 'archive import')],
          ),
      ];
      await index.upsert(
        pair,
        participantById: const {},
        relationTextByConversation: const {},
      );
      await index.close();
      final single = await DiskSearchIndex.open(path: getPath(), vaultKey: key);
      final c = SearchCriteria(query: 'archive import');
      late List<String> expected;
      try {
        expected = await search(c, target: single);
      } finally {
        await single.close();
      }
      index = await DiskSearchIndex.open(
        path: getPath(),
        vaultKey: key,
        searchWorkers: 4,
      );
      expect(expected, ['a', 'b']);
      expect(await search(c), expected);
    },
  );
}
