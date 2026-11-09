import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_service.dart';
import 'package:app/services/search_source_groups.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  late Directory directory;
  late DiskSearchIndex disk;
  final key = List<int>.generate(32, (n) => n);
  final people = {'alice': 'Alice Müller', 'bob': 'Böb'};
  final relations = {'one': 'Invoice paid'};
  final now = DateTime.utc(2026, 10, 28);
  Conversation conversation(
    String id,
    String text, {
    bool favorite = false,
    String source = 'email',
    RecordingLocation? location,
  }) => Conversation(
    id: id,
    title: 'Überweisung $id',
    source: source,
    participantIds: ['alice'],
    tags: ['Payment received'],
    isFavorite: favorite,
    location: location,
    segments: [
      ConversationSegment(
        id: 'segment-$id',
        text: text,
        participantId: 'bob',
        createdAt: now,
      ),
    ],
    startedAt: now.subtract(Duration(days: id.length)),
    endedAt: now,
  );
  SearchScorer scorer(SearchCriteria criteria) => SearchScorer(
    temporalIntent: null,
    normalizedQuery: criteria.normalized,
    now: now,
  );
  Future<List<String>> search(SearchCriteria criteria) async =>
      (await disk.search(
        criteria,
        scorer(criteria),
        ConversationSearchIndex.tokenize(criteria.normalized),
        ConversationSearchIndex.tokenize(criteria.normalized).join(' '),
      )).map((doc) => doc.id).toList();

  Future<List<int>> decryptPage(List<int> bytes) =>
      crypto.AesGcm.with256bits().decrypt(
        crypto.SecretBox(
          bytes.sublist(28),
          nonce: bytes.sublist(0, 12),
          mac: crypto.Mac(bytes.sublist(12, 28)),
        ),
        secretKey: crypto.SecretKeyData(key),
      );

  Future<Uint8List> encryptPage(List<int> bytes) async {
    final box = await crypto.AesGcm.with256bits().encrypt(
      bytes,
      secretKey: crypto.SecretKeyData(key),
    );
    return Uint8List.fromList([
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('disk-search-test-');
    disk = await DiskSearchIndex.open(
      path: '${directory.path}/index.sqlite',
      vaultKey: key,
    );
  });
  tearDown(() async {
    await disk.close();
    await directory.delete(recursive: true);
  });

  test(
    'standard gzip pages and positions remain compatible without migration',
    () async {
      final docs = [
        conversation('one', 'insurance renewal archive 私の音声'),
        conversation('two', 'insurance archive renewal archive'),
        conversation('three', 'renewal insurance archive'),
      ];
      await disk.upsert(
        docs,
        participantById: people,
        relationTextByConversation: relations,
      );
      await disk.writeMetadata('codec', {'unicode': 'Müller 私の音声'});
      await disk.prepare();
      final expected = <String, List<String>>{};
      for (final query in [
        'insurance renewal',
        'insuranc alice',
        'archive',
        '私の',
      ]) {
        expected[query] = await search(SearchCriteria(query: query));
      }
      await disk.close();
      final database = sql.sqlite3.open('${directory.path}/index.sqlite');
      try {
        // The old native decoder reads every managed stream; re-encode them with
        // the old encoder to exercise existing encrypted caches on reopen.
        for (final table in [
          'metadata',
          'bodypages',
          'docpages',
          'summarypages',
          'vocabulary',
          'scoretiles',
        ]) {
          final id = table == 'metadata' ? 'key' : 'id';
          for (final row in database.select(
            'SELECT $id, payload FROM $table',
          )) {
            final plain = gzip.decode(
              await decryptPage(row['payload'] as List<int>),
            );
            database.execute('UPDATE $table SET payload = ? WHERE $id = ?', [
              await encryptPage(gzip.encode(plain)),
              row[id],
            ]);
          }
        }
        for (final row in database.select(
          'SELECT term, page, payload FROM postings',
        )) {
          final packed = await decryptPage(row['payload'] as List<int>);
          // v6 keeps a 168-byte bitmap/impact header plus the v5 format marker.
          expect(packed[168], 5);
          final positions = gzip.decode(packed.sublist(169));
          database.execute(
            'UPDATE postings SET payload = ? WHERE term = ? AND page = ?',
            [
              await encryptPage([
                ...packed.take(169),
                ...gzip.encode(positions),
              ]),
              row['term'],
              row['page'],
            ],
          );
        }
      } finally {
        database.close();
      }
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      await disk.prepare();
      expect(await disk.readMetadata('_rankingVersion'), 6);
      expect(await disk.readMetadata('_rankingCursor'), isNull);
      expect(await disk.readMetadata('codec'), {'unicode': 'Müller 私の音声'});
      for (final entry in expected.entries) {
        expect(await search(SearchCriteria(query: entry.key)), entry.value);
      }
      for (final doc in docs) {
        expect((await disk.loadConversation(doc.id)).toJson(), doc.toJson());
      }
    },
  );

  for (final corruption in ['CRC', 'truncation']) {
    test('authenticated gzip $corruption is rejected', () async {
      await disk.writeMetadata('codec', {'value': 'complete payload'});
      await disk.close();
      final database = sql.sqlite3.open('${directory.path}/index.sqlite');
      try {
        final row = database
            .select("SELECT payload FROM metadata WHERE key = 'codec'")
            .single;
        var compressed = await decryptPage(row['payload'] as List<int>);
        if (corruption == 'CRC') {
          compressed[compressed.length - 8] ^= 1;
        } else {
          compressed = compressed.sublist(0, compressed.length - 1);
        }
        // Authenticate the damaged gzip so failure must come from the decoder.
        database.execute(
          "UPDATE metadata SET payload = ? WHERE key = 'codec'",
          [await encryptPage(compressed)],
        );
      } finally {
        database.close();
      }
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      await expectLater(disk.readMetadata('codec'), throwsStateError);
      expect(await disk.count, 0);
    });
  }

  test(
    'encrypted pages preserve reference fuzzy, Unicode, filters and ranking',
    () async {
      final docs = [
        conversation(
          'one',
          'invoice invoice amount 12345 私の音声',
          favorite: true,
        ),
        conversation(
          'two',
          'Berlin train ticket 123456',
          location: RecordingLocation(
            town: 'Berlin',
            venue: 'Central Station',
            address: 'Invalidenstrasse 1',
          ),
        ),
        conversation('three', 'insurance renewal invoice'),
        conversation('four', 'invoice payment', source: 'youtube'),
      ];
      await disk.upsert(
        docs,
        participantById: people,
        relationTextByConversation: relations,
      );
      final reference = ConversationSearchIndex.build(
        conversations: docs,
        participantById: people,
        relationTextByConversation: relations,
      );
      for (final query in [
        '',
        'invoice',
        'invioce',
        'ali muell',
        '12345',
        '1234',
        '私の',
        'insurance invoice',
        'absent',
      ]) {
        for (final vector in [true, false]) {
          final criteria = SearchCriteria(query: query, useVector: vector);
          final tokens = ConversationSearchIndex.tokenize(criteria.normalized);
          final expected = SearchService(reference)
              .rankConversations(
                criteria,
                scorer(criteria),
                tokens,
                tokens.join(' '),
                maxResults: 100,
              )
              .map((doc) => doc.id)
              .toList();
          expect(
            await search(criteria),
            expected,
            reason: '$query vector=$vector',
          );
        }
      }
      for (final criteria in [
        SearchCriteria(query: 'invoice', favoritesOnly: true),
        SearchCriteria(query: 'town:ber'),
        SearchCriteria(query: 'berlin town:ber'),
        SearchCriteria(query: 'location:central'),
        SearchCriteria(query: '', source: 'email'),
        SearchCriteria(query: 'alice', participantId: 'nobody'),
        SearchCriteria(query: 'invoice', tag: 'payment received'),
        SearchCriteria(query: 'invoice', includeConsumed: false),
        SearchCriteria(query: '', from: now.subtract(const Duration(days: 1))),
      ]) {
        final tokens = ConversationSearchIndex.tokenize(criteria.normalized);
        expect(
          await search(criteria),
          SearchService(reference)
              .rankConversations(
                criteria,
                scorer(criteria),
                tokens,
                tokens.join(' '),
                maxResults: 100,
              )
              .map((doc) => doc.id)
              .toList(),
        );
      }
      expect(
        (await disk.loadConversation('one')).segments.single.text,
        docs.first.segments.single.text,
      );
      final bytes = await File('${directory.path}/index.sqlite').readAsBytes();
      final contents = latin1.decode(bytes);
      for (final secret in [
        'invoice',
        'Überweisung',
        'Payment received',
        'Alice',
        'Berlin train',
        'segment-one',
      ]) {
        expect(contents.contains(secret), isFalse, reason: secret);
      }
    },
  );

  test(
    'updates, removals, metadata, reopen, pagination and hard result limit',
    () async {
      final docs = [
        for (var n = 0; n < 140; n++)
          conversation('doc-$n', 'archive oldword $n'),
      ];
      await disk.upsert(
        docs,
        participantById: people,
        relationTextByConversation: const {},
      );
      expect(await disk.count, 140);
      final criteria = SearchCriteria(query: 'archive');
      expect(
        (await disk.search(
          criteria,
          scorer(criteria),
          ['archive'],
          'archive',
          maxResults: 10000,
        )).length,
        100,
      );
      expect((await disk.summaries(offset: 128, limit: 100)).length, 12);
      await disk.upsert(
        [conversation('doc-0', 'newword')],
        participantById: people,
        relationTextByConversation: const {},
      );
      await disk.remove(['doc-1', 'missing']);
      await disk.writeMetadata('revision', {'value': 42});
      await disk.close();
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      expect(await disk.count, 139);
      expect(await disk.readMetadata('revision'), {'value': 42});
      expect(await search(SearchCriteria(query: 'newword')), ['doc-0']);
      expect(await search(SearchCriteria(query: 'newword oldword')), isEmpty);
      expect(await search(SearchCriteria(query: '1')), isEmpty);
      expect(
        (await disk.loadConversation('doc-0')).segments.single.text,
        'newword',
      );
    },
  );
  test(
    'posting boundaries, atomic rollback and manifest invalidation',
    () async {
      await disk.upsert(
        [for (var n = 0; n < 1030; n++) conversation('item-$n', 'archive $n')],
        participantById: people,
        relationTextByConversation: const {},
      );
      expect(await search(SearchCriteria(query: '1024')), ['item-1024']);
      await disk.writeMetadata('snapshotNonce', 'old');
      await disk.upsert(
        [conversation('item-1024', 'changed')],
        participantById: people,
        relationTextByConversation: const {},
      );
      expect(await disk.readMetadata('snapshotNonce'), isNull);
      await disk.writeMetadata('snapshotNonce', 'current');
      final stateBeforeFailure = (await disk.readMetadata('_state')) as List;
      final rangesBeforeFailure = await disk.readMetadata(
        '_sourceActivePostingPagesV2',
      );
      final unloaded = Conversation.fromSummaryJson(
        conversation('bad', 'unavailable', source: 'discord').toSummaryJson(),
      );
      await expectLater(
        disk.upsert(
          [conversation('item-1024', 'rolledback'), unloaded],
          participantById: people,
          relationTextByConversation: const {},
        ),
        throwsStateError,
      );
      expect(await disk.readMetadata('snapshotNonce'), 'current');
      expect(await disk.readMetadata('_state'), stateBeforeFailure);
      expect(
        await disk.readMetadata('_sourceActivePostingPagesV2'),
        rangesBeforeFailure,
      );
      expect(await search(SearchCriteria(query: 'changed')), ['item-1024']);
      expect(await search(SearchCriteria(query: 'rolledback')), isEmpty);
      expect(
        (await disk.loadConversations([
          'item-1029',
          'item-0',
          'item-1024',
        ])).map((doc) => doc.id),
        ['item-1029', 'item-0', 'item-1024'],
      );
      // Retry the rolled-back allocation in a previously unused source group.
      await disk.upsert(
        [conversation('retry', 'survivor', source: 'discord')],
        participantById: people,
        relationTextByConversation: const {},
      );
      expect(await search(SearchCriteria(query: 'survivor')), ['retry']);
      expect(
        ((await disk.readMetadata('_state')) as List)[2],
        (stateBeforeFailure[2] as int) + 1024,
      );
      await disk.remove(['item-1024']);
      expect(await search(SearchCriteria(query: 'changed')), isEmpty);
      await disk.clear();
      expect(await disk.count, 0);
      expect(await disk.readMetadata('snapshotNonce'), isNull);
      expect(await search(SearchCriteria(query: 'archive')), isEmpty);
      await disk.upsert(
        [conversation('replacement', 'rebuilt')],
        participantById: people,
        relationTextByConversation: const {},
      );
      expect(await search(SearchCriteria(query: 'rebuilt')), ['replacement']);
    },
  );

  test('a different vault key cannot open encrypted state', () async {
    await disk.upsert(
      [conversation('one', 'private')],
      participantById: people,
      relationTextByConversation: const {},
    );
    await expectLater(
      DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: List<int>.filled(32, 77),
      ),
      throwsStateError,
    );
  });
  test(
    'catalog and timeline do not decrypt scoring or conversation body pages',
    () async {
      await disk.upsert(
        [conversation('one', 'invoice')],
        participantById: people,
        relationTextByConversation: const {},
      );
      final database = sql.sqlite3.open('${directory.path}/index.sqlite');
      try {
        database.execute(
          'UPDATE docpages SET payload = zeroblob(length(payload))',
        );
        database.execute(
          'UPDATE scoretiles SET payload = zeroblob(length(payload))',
        );
        database.execute(
          'UPDATE bodypages SET payload = zeroblob(length(payload))',
        );
      } finally {
        database.close();
      }
      expect(await search(SearchCriteria(query: '')), ['one']);
      expect((await disk.summaries()).single.id, 'one');
      await expectLater(
        search(SearchCriteria(query: 'invoice')),
        throwsStateError,
      );
      await expectLater(disk.loadConversation('one'), throwsStateError);
    },
  );
  test(
    'explicit disposable cache recovery replaces a corrupt SQLite file',
    () async {
      await disk.close();
      final file = File('${directory.path}/index.sqlite');
      await file.writeAsString('corrupt disposable search cache');
      await expectLater(
        DiskSearchIndex.open(path: file.path, vaultKey: key),
        throwsStateError,
      );
      expect(await file.readAsString(), 'corrupt disposable search cache');
      disk = await DiskSearchIndex.open(
        path: file.path,
        vaultKey: key,
        recreateOnFailure: true,
      );
      expect(await disk.count, 0);
      await disk.upsert(
        [conversation('one', 'restored')],
        participantById: people,
        relationTextByConversation: const {},
      );
      expect(await search(SearchCriteria(query: 'restored')), ['one']);
    },
  );
  test(
    'new queries, explicit cancellation and close stop obsolete searches',
    () async {
      await disk.upsert(
        [for (var n = 0; n < 1030; n++) conversation('item-$n', 'archive $n')],
        participantById: people,
        relationTextByConversation: const {},
      );
      var obsolete = search(SearchCriteria(query: 'archive'));
      final latest = search(SearchCriteria(query: '1024'));
      expect(await obsolete, isEmpty);
      expect(await latest, ['item-1024']);
      obsolete = search(SearchCriteria(query: 'archive'));
      await disk.cancelSearch();
      expect(await obsolete, isEmpty);
      obsolete = search(SearchCriteria(query: 'archive'));
      await disk.close();
      expect(await obsolete, isEmpty);
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      expect(await disk.count, 1030);
      expect(await search(SearchCriteria(query: '1024')), ['item-1024']);
    },
  );
  test(
    'recent frontier exactly preserves weighted ranking and mutation recovery',
    () async {
      Conversation recent(String id, String source, DateTime date) =>
          Conversation(
            id: id,
            title: id,
            source: source,
            participantIds: const [],
            segments: [
              ConversationSegment(
                id: 'segment-$id',
                text: 'archive',
                createdAt: date,
              ),
            ],
            startedAt: date,
            endedAt: date,
          );
      const sources = ['manual', 'scanned-pdf', 'youtube-watch-history'];
      final docs = [
        for (var category = 0; category < sources.length; category++)
          for (var n = 0; n < 130; n++)
            recent(
              '$category-${n.toString().padLeft(3, '0')}',
              sources[category],
              n < 60
                  ? now.add(Duration(days: n % 20))
                  : now.subtract(Duration(days: 200 + n)),
            ),
      ];
      await disk.upsert(
        docs,
        participantById: const {},
        relationTextByConversation: const {},
      );
      Future<void> compare({SearchCriteria? criteria, int limit = 100}) async {
        final c = criteria ?? SearchCriteria(query: '');
        final reference = ConversationSearchIndex.build(
          conversations: docs,
          participantById: const {},
          relationTextByConversation: const {},
        );
        final expected = SearchService(reference)
            .rankConversations(c, scorer(c), const [], '', maxResults: limit)
            .map((doc) => doc.id)
            .toList();
        final actual = await disk.search(
          c,
          scorer(c),
          const [],
          '',
          maxResults: limit,
        );
        expect(actual.map((doc) => doc.id).toList(), expected);
      }

      final cache = await disk.readMetadata('_recentFrontier') as Map;
      expect((cache['groups'] as List).map((group) => (group as List).length), [
        100,
        100,
        100,
      ]);
      await compare();
      await compare(limit: 17);
      final c = SearchCriteria(query: '');
      expect(
        (await disk.search(
          c,
          scorer(c),
          const [],
          '',
          maxResults: 10000,
        )).length,
        100,
      );
      for (final filter in [
        SearchCriteria(query: '', source: 'manual'),
        SearchCriteria(query: '', includeConsumed: false),
        SearchCriteria(query: '', favoritesOnly: true),
        SearchCriteria(query: '', from: now.subtract(const Duration(days: 1))),
      ]) {
        await compare(criteria: filter);
      }
      // Updating a document outside the frontier can enter it without a scan.
      docs[125] = recent('0-125', 'manual', now.add(const Duration(days: 500)));
      await disk.upsert(
        [docs[125]],
        participantById: const {},
        relationTextByConversation: const {},
      );
      expect(await disk.readMetadata('_recentFrontier'), isNotNull);
      await compare();
      // Moving a frontier item away must discover the previous 101st item.
      docs[125] = recent(
        '0-125',
        'manual',
        now.subtract(const Duration(days: 5000)),
      );
      await disk.upsert(
        [docs[125]],
        participantById: const {},
        relationTextByConversation: const {},
      );
      expect(await disk.readMetadata('_recentFrontier'), isNull);
      await compare();
      final removed = [
        for (var n = 0; n < 60; n++) '0-${n.toString().padLeft(3, '0')}',
      ];
      await disk.remove(removed);
      docs.removeWhere((doc) => removed.contains(doc.id));
      expect(await disk.readMetadata('_recentFrontier'), isNull);
      await compare();
      // A database produced by the previous binary has no optional cache.
      await disk.writeMetadata('_recentFrontier', null);
      await compare();
      expect(await disk.readMetadata('_recentFrontier'), isNotNull);
      await disk.close();
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      await compare();
    },
  );

  test('cached unfiltered timeline reads only frontier summary pages', () async {
    const sources = ['manual', 'scanned-pdf', 'youtube-watch-history'];
    final docs = [
      for (var category = 0; category < sources.length; category++)
        for (var n = 0; n < 400; n++)
          Conversation(
            id: '$category-$n',
            title: 'Archive',
            source: sources[category],
            participantIds: const [],
            segments: const [],
            startedAt: now.subtract(Duration(days: n)),
            endedAt: now,
          ),
    ];
    await disk.upsert(
      docs,
      participantById: const {},
      relationTextByConversation: const {},
    );
    final expected = await search(SearchCriteria(query: ''));
    await disk.writeMetadata('_recentFrontier', null);
    await disk.prepare();
    expect(await disk.readMetadata('_recentFrontier'), isNotNull);
    final database = sql.sqlite3.open('${directory.path}/index.sqlite');
    try {
      int? olderPage;
      for (final row in database.select(
        'SELECT id, payload FROM summarypages',
      )) {
        final summaries =
            jsonDecode(
                  utf8.decode(
                    gzip.decode(await decryptPage(row['payload'] as List<int>)),
                  ),
                )
                as List;
        if (summaries.any((value) => value is Map && value['id'] == '2-200')) {
          olderPage = row['id'] as int;
          break;
        }
      }
      expect(olderPage, isNotNull);
      database.execute(
        'UPDATE summarypages SET payload = zeroblob(length(payload)) WHERE id = ?',
        [olderPage],
      );
    } finally {
      database.close();
    }
    expect(await search(SearchCriteria(query: '')), expected);
    final first = docs.first;
    await disk.upsert(
      [
        Conversation(
          id: first.id,
          title: 'Edited archive',
          source: first.source,
          participantIds: const ['new-person'],
          tags: const ['edited'],
          isFavorite: true,
          segments: [
            ConversationSegment(id: 'edited', text: 'Updated content'),
          ],
          startedAt: first.startedAt,
          endedAt: first.endedAt,
        ),
      ],
      participantById: const {'new-person': 'New Person'},
      relationTextByConversation: const {},
    );
    expect(await disk.readMetadata('_recentFrontier'), isNotNull);
    expect(await search(SearchCriteria(query: '')), expected);
    expect(
      await search(SearchCriteria(query: '', source: 'youtube-watch-history')),
      [for (var n = 0; n < 100; n++) '2-$n'],
    );
    // A filter which needs the damaged older block must still expose damage.
    await expectLater(
      search(
        SearchCriteria(
          query: '',
          source: 'youtube-watch-history',
          to: now.subtract(const Duration(days: 200)),
        ),
      ),
      throwsStateError,
    );
  });
  test(
    'source posting ranges reduce reads and preserve global ranking',
    () async {
      const sources = [
        'browser-history',
        'scanned-pdf',
        'email',
        'discord',
        'manual',
      ];
      Conversation item(int n, String source) => Conversation(
        id: 'partition-$n',
        title: 'Archive $n',
        source: source,
        participantIds: const [],
        segments: [
          ConversationSegment(
            id: 'segment-$n',
            text: 'archive corpus',
            createdAt: now,
          ),
        ],
        startedAt: now.subtract(Duration(hours: n)),
        endedAt: now,
      );
      final docs = [
        for (var n = 0; n < 400; n++) item(n, sources[n % sources.length]),
      ];
      await disk.upsert(
        docs,
        participantById: const {},
        relationTextByConversation: const {},
      );
      Future<void> compare(SearchCriteria c) async {
        final reference = ConversationSearchIndex.build(
          conversations: docs,
          participantById: const {},
          relationTextByConversation: const {},
        );
        final tokens = ConversationSearchIndex.tokenize(c.normalized);
        expect(
          (await disk.search(
            c,
            scorer(c),
            tokens,
            tokens.join(' '),
          )).map((doc) => doc.id).toList(),
          SearchService(reference)
              .rankConversations(
                c,
                scorer(c),
                tokens,
                tokens.join(' '),
                maxResults: 100,
              )
              .map((doc) => doc.id)
              .toList(),
        );
      }

      await compare(SearchCriteria(query: 'archive'));
      final unfilteredReads = (await disk.searchProfile)['postingReads']!;
      expect(unfilteredReads, greaterThan(1));
      for (final c in [
        for (final group in SearchSourceGroup.values)
          SearchCriteria(query: 'archive', source: sourceGroupFilter(group)),
        SearchCriteria(query: 'archive', source: 'email'),
        SearchCriteria(query: 'archive', source: 'discord'),
        SearchCriteria(query: 'archive', includeConsumed: false),
        SearchCriteria(
          query: 'archive',
          source: 'group:consumed',
          includeConsumed: false,
        ),
      ]) {
        await compare(c);
        if (c.source != null && c.includeConsumed) {
          expect(
            (await disk.searchProfile)['postingReads'],
            lessThan(unfilteredReads),
          );
        }
      }
      var database = sql.sqlite3.open('${directory.path}/index.sqlite');
      try {
        final pages = database.select(
          'SELECT page, COUNT(*) AS n FROM page_groups GROUP BY page',
        );
        expect(pages.length, 5);
        expect(
          database
              .select('SELECT COUNT(DISTINCT page) AS n FROM postings')
              .single['n'],
          5,
        );
        expect(pages.every((row) => row['n'] == 1), isTrue);
        expect(
          database
              .select('SELECT DISTINCT length(group_key) AS n FROM page_groups')
              .single['n'],
          32,
        );
      } finally {
        database.close();
      }
      final rangesBeforeSourceChange = await disk.readMetadata(
        '_sourceActivePostingPagesV2',
      );
      // A source change keeps its ordinal and adds a safe mixed-page route.
      docs[0] = item(0, 'email');
      await disk.upsert(
        [docs[0]],
        participantById: const {},
        relationTextByConversation: const {},
      );
      expect(
        await disk.readMetadata('_sourceActivePostingPagesV2'),
        rangesBeforeSourceChange,
      );
      await compare(SearchCriteria(query: 'archive', source: 'group:email'));
      await compare(SearchCriteria(query: 'archive', source: 'group:consumed'));
      await disk.close();
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      docs.add(item(400, 'email'));
      await disk.upsert(
        [docs.last],
        participantById: const {},
        relationTextByConversation: const {},
      );
      await compare(SearchCriteria(query: 'archive', source: 'group:email'));
      final resumedRanges =
          (await disk.readMetadata('_sourceActivePostingPagesV2')) as Map;
      final previousEmail = (rangesBeforeSourceChange as Map)['email'] as List;
      expect(resumedRanges['email'], [
        previousEmail[0],
        (previousEmail[1] as int) + 1,
      ]);
      database = sql.sqlite3.open('${directory.path}/index.sqlite');
      try {
        expect(
          database.select('SELECT COUNT(*) AS n FROM summarypages').single['n'],
          5,
        );
      } finally {
        database.close();
      }
    },
  );

  test(
    'legacy mixed pages migrate in place and interrupted routing resumes',
    () async {
      Conversation item(int n, String source) => Conversation(
        id: 'legacy-$n',
        title: 'Archive $n',
        source: source,
        participantIds: const [],
        segments: [
          ConversationSegment(
            id: 's-$n',
            text: 'archive legacy',
            createdAt: now,
          ),
        ],
        startedAt: now.subtract(Duration(hours: n)),
        endedAt: now,
      );
      final docs = [for (var n = 0; n < 300; n++) item(n, 'manual')];
      await disk.upsert(
        docs,
        participantById: const {},
        relationTextByConversation: const {},
      );
      const sources = [
        'email',
        'discord',
        'browser-history',
        'scanned-pdf',
        'manual',
      ];
      for (var n = 0; n < docs.length; n++) {
        docs[n] = item(n, sources[n % sources.length]);
      }
      await disk.upsert(
        docs,
        participantById: const {},
        relationTextByConversation: const {},
      );
      await disk.close();
      Map<String, String> payloads(sql.Database database) => {
        for (final table in ['summarypages', 'docpages', 'bodypages'])
          for (final row in database.select('SELECT id, payload FROM $table'))
            '$table:${row['id']}': base64Encode(row['payload'] as List<int>),
      };
      var database = sql.sqlite3.open('${directory.path}/index.sqlite');
      late Map<String, String> original;
      try {
        original = payloads(database);
        database.execute('DELETE FROM page_groups');
        database.execute(
          "DELETE FROM metadata WHERE key IN ('_sourcePartitions', '_sourcePartitionCursor', '_sourceActivePostingPagesV2')",
        );
        // Simulate the old allocator's high-water mark and partial 128-slot page.
        final stateRow = database
            .select("SELECT payload FROM metadata WHERE key = '_state'")
            .single;
        final clearState = gzip.decode(
          await decryptPage(stateRow['payload'] as List<int>),
        );
        final state = jsonDecode(utf8.decode(clearState)) as List;
        state[2] = 300;
        database.execute(
          "UPDATE metadata SET payload = ? WHERE key = '_state'",
          [await encryptPage(gzip.encode(utf8.encode(jsonEncode(state))))],
        );
        final legacyActivePages = utf8.encode(
          jsonEncode({
            'other': [2, 44],
          }),
        );
        database.execute('INSERT OR REPLACE INTO metadata VALUES (?, ?)', [
          '_sourceActivePages',
          await encryptPage(gzip.encode(legacyActivePages)),
        ]);
      } finally {
        database.close();
      }
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      final query = SearchCriteria(query: 'archive', source: 'group:email');
      final interrupted = disk.search(query, scorer(query), [
        'archive',
      ], 'archive');
      await disk.cancelSearch();
      expect(await interrupted, isEmpty);
      // Cancellation can arrive after the small routing migration commits.
      // The subsequent parity checks validate either completed or resumed routes.
      if (await disk.readMetadata('_sourcePartitions') == 1) {
        expect(await disk.readMetadata('_sourcePartitionCursor'), isNull);
      }
      final reference = ConversationSearchIndex.build(
        conversations: docs,
        participantById: const {},
        relationTextByConversation: const {},
      );
      for (final group in SearchSourceGroup.values) {
        final c = SearchCriteria(
          query: 'archive',
          source: sourceGroupFilter(group),
        );
        expect(
          (await disk.search(c, scorer(c), [
            'archive',
          ], 'archive')).map((doc) => doc.id).toList(),
          SearchService(reference)
              .rankConversations(
                c,
                scorer(c),
                ['archive'],
                'archive',
                maxResults: 100,
              )
              .map((doc) => doc.id)
              .toList(),
        );
      }
      expect(await disk.readMetadata('_sourcePartitions'), 1);
      expect(await disk.readMetadata('_sourcePartitionCursor'), isNull);
      database = sql.sqlite3.open('${directory.path}/index.sqlite');
      try {
        expect(payloads(database), original);
        expect(
          database
              .select(
                'SELECT page, COUNT(*) AS n FROM page_groups GROUP BY page',
              )
              .every((row) => row['n'] == 5),
          isTrue,
        );
      } finally {
        database.close();
      }
      docs.add(item(300, 'email'));
      await disk.upsert(
        [docs.last],
        participantById: const {},
        relationTextByConversation: const {},
      );
      expect(await disk.readMetadata('_sourceActivePages'), {
        'other': [2, 44],
      });
      expect(((await disk.readMetadata('_state')) as List)[2], 2048);
      database = sql.sqlite3.open('${directory.path}/index.sqlite');
      try {
        final afterAppend = payloads(database);
        for (final entry in original.entries) {
          expect(afterAppend[entry.key], entry.value);
        }
        expect(
          database.select('SELECT MAX(id) AS n FROM documents').single['n'],
          1024,
        );
      } finally {
        database.close();
      }
      final criteria = SearchCriteria(query: 'archive', source: 'group:email');
      final updatedReference = ConversationSearchIndex.build(
        conversations: docs,
        participantById: const {},
        relationTextByConversation: const {},
      );
      expect(
        await search(criteria),
        SearchService(updatedReference)
            .rankConversations(
              criteria,
              scorer(criteria),
              ['archive'],
              'archive',
              maxResults: 100,
            )
            .map((doc) => doc.id)
            .toList(),
      );
    },
  );
  test(
    'bulk inserts are atomic and any existing ID keeps bounded update batches',
    () async {
      final invalid = Conversation.fromSummaryJson(
        conversation('unloaded', 'missing').toSummaryJson(),
      );
      final fresh = [
        for (var n = 0; n < DiskSearchIndex.writeBatchSize; n++)
          conversation('fresh-$n', 'archive'),
      ];
      fresh[128] = invalid;
      await expectLater(
        disk.upsert(
          fresh,
          participantById: people,
          relationTextByConversation: const {},
        ),
        throwsStateError,
      );
      expect(await disk.count, 0);

      await disk.upsert(
        [conversation('existing', 'original')],
        participantById: people,
        relationTextByConversation: const {},
      );
      final mixed = [
        for (var n = 0; n < DiskSearchIndex.writeBatchSize; n++)
          conversation('mixed-$n', 'archive'),
      ];
      // The existing record comes after the failure, requiring the preflight to
      // check the entire request before selecting smaller update transactions.
      mixed[1000] = conversation('existing', 'updated');
      mixed[128] = invalid;
      await expectLater(
        disk.upsert(
          mixed,
          participantById: people,
          relationTextByConversation: const {},
        ),
        throwsStateError,
      );
      expect(await disk.count, 129);
      expect(
        (await disk.loadConversation('existing')).segments.single.text,
        'original',
      );
      mixed[128] = conversation('mixed-128', 'archive');
      await disk.upsert(
        mixed,
        participantById: people,
        relationTextByConversation: const {},
      );
      expect(await disk.count, DiskSearchIndex.writeBatchSize);
      expect(
        (await disk.loadConversation('existing')).segments.single.text,
        'updated',
      );
    },
  );
}
