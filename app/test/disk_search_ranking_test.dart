import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:app/models.dart';
import 'package:app/services/conversation_search_index.dart';
import 'package:app/services/disk_search_index_io.dart';
import 'package:app/services/search_criteria.dart';
import 'package:app/services/search_scorer.dart';
import 'package:app/services/search_posting_positions.dart';
import 'package:app/services/search_service.dart';
import 'package:app/services/temporal_intent.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  late Directory directory;
  late DiskSearchIndex disk;
  final now = DateTime.utc(2026, 10, 28);
  final key = List.generate(32, (n) => n);
  const people = {'alice': 'Alice Müller', 'bob': 'Bob Garcia'};
  late List<Conversation> docs;

  Conversation item(int n, {String? text, String? title, String? source}) {
    final random = Random(n);
    final words = [
      'archive',
      'renewal',
      'insurance',
      'project',
      'projector',
      'budget',
      'meeting',
      'travel',
    ];
    final time = now.subtract(Duration(hours: n % 181));
    return Conversation(
      id: 'doc-${n.toString().padLeft(6, '0')}',
      title:
          title ?? '${n % 7 == 0 ? 'Insurance renewal' : 'Archive project'} $n',
      source:
          source ??
          ['email', 'discord', 'scanned-pdf', 'browser-history'][n % 4],
      participantIds: [n % 3 == 0 ? 'alice' : 'bob'],
      tags: [if (n % 5 == 0) 'budget'],
      isFavorite: n % 13 == 0,
      location: n % 7 == 0
          ? RecordingLocation(town: 'Berlin', venue: 'Central Station')
          : null,
      segments: [
        ConversationSegment(
          id: 'segment-$n',
          text:
              text ??
              [
                for (var k = 0; k < 10 + n % 40; k++)
                  words[random.nextInt(words.length)],
              ].join(' '),
          createdAt: time,
        ),
      ],
      startedAt: time,
      endedAt: time.add(Duration(hours: n % 8)),
    );
  }

  Future<void> upsert(List<Conversation> values) => disk.upsert(
    values,
    participantById: people,
    relationTextByConversation: const {},
  );

  Future<Uint8List> transformEncrypted(
    List<int> packed,
    List<int> Function(Uint8List) transform,
  ) async {
    final cipher = AesGcm.with256bits();
    final secret = SecretKey(key);
    final data = Uint8List.fromList(packed);
    final plain = await cipher.decrypt(
      SecretBox(
        Uint8List.sublistView(data, 28),
        nonce: Uint8List.sublistView(data, 0, 12),
        mac: Mac(Uint8List.sublistView(data, 12, 28)),
      ),
      secretKey: secret,
    );
    final nonce = cipher.newNonce();
    final box = await cipher.encrypt(
      transform(Uint8List.fromList(plain)),
      secretKey: secret,
      nonce: nonce,
    );
    return Uint8List.fromList([...nonce, ...box.mac.bytes, ...box.cipherText]);
  }

  Future<void> check(
    SearchCriteria criteria, {
    TemporalIntent? intent,
    List<String> previous = const [],
  }) async {
    final tokens = ConversationSearchIndex.tokenize(
      TemporalIntent.lexicalQuery(criteria.normalized),
    );
    final scorer = SearchScorer(
      temporalIntent: intent,
      normalizedQuery: criteria.normalized,
      now: now,
      lastSearchTopIds: previous,
    );
    final reference = ConversationSearchIndex.build(
      conversations: docs,
      participantById: people,
      relationTextByConversation: const {},
    );
    final expected = SearchService(reference)
        .rankConversations(
          criteria,
          scorer,
          tokens,
          tokens.join(' '),
          maxResults: 100,
        )
        .map((doc) => doc.id)
        .toList();
    final actual = await disk.search(
      criteria,
      scorer,
      tokens,
      tokens.join(' '),
    );
    expect(actual.map((doc) => doc.id).toList(), expected, reason: '$criteria');
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('disk-ranking-');
    disk = await DiskSearchIndex.open(
      path: '${directory.path}/index.sqlite',
      vaultKey: key,
    );
    docs = [for (var n = 0; n < 1536; n++) item(n)];
    await upsert(docs);
  });
  tearDown(() async {
    await disk.close();
    await directory.delete(recursive: true);
  });

  test(
    'block pruning agrees with exhaustive top100 across fields and filters',
    () async {
      for (final query in [
        'archive',
        'project budget',
        'insuranc',
        'ali muell',
        'berlin station',
        '1535',
      ]) {
        for (final vector in [false, true]) {
          await check(SearchCriteria(query: query, useVector: vector));
        }
      }
      for (final criteria in [
        SearchCriteria(query: 'project', source: 'group:chat'),
        SearchCriteria(query: 'archive', includeConsumed: false),
        SearchCriteria(query: 'budget', favoritesOnly: true),
        SearchCriteria(query: 'project', tag: 'budget', participantId: 'alice'),
        SearchCriteria(query: 'project town:ber'),
        SearchCriteria(
          query: 'archive',
          from: now.subtract(const Duration(days: 2)),
        ),
        SearchCriteria(query: '', source: 'group:documents'),
      ]) {
        await check(criteria);
      }
      await check(
        SearchCriteria(query: 'archive yesterday morning'),
        intent: TemporalIntent.tryParse('yesterday morning', now),
      );
      await check(
        SearchCriteria(query: 'archive previous search'),
        previous: ['doc-001511', 'doc-001535'],
      );
    },
  );

  test(
    'DF propagation, replacements, removals and reopen preserve exact boundaries',
    () async {
      // The existing rare numeric witnesses become frequent in other blocks.
      final additions = [
        for (var n = 1536; n < 2048; n++)
          item(
            n,
            text: 'archive project ${List.generate(128, (i) => i).join(' ')}',
          ),
      ];
      docs.addAll(additions);
      await upsert(additions);
      await check(SearchCriteria(query: 'archive'));
      await check(SearchCriteria(query: 'project 42'));
      final replacements = [
        for (var n = 0; n < 140; n++)
          item(
            n,
            title: 'Renewal project',
            text: 'insurance budget',
            source: 'browser-history',
          ),
      ];
      docs.setRange(0, replacements.length, replacements);
      await upsert(replacements);
      final removed = docs.skip(1000).take(130).map((doc) => doc.id).toList();
      await disk.remove(removed);
      docs.removeWhere((doc) => removed.contains(doc.id));
      await disk.close();
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      for (final query in ['archive', 'insurance budget', 'project', '42']) {
        await check(SearchCriteria(query: query));
      }
    },
  );

  test(
    'legacy ranking migration survives cancellation and preserves source pages',
    () async {
      await disk.close();
      final database = sql.sqlite3.open('${directory.path}/index.sqlite');
      database.execute('DELETE FROM rankingpages');
      database.execute(
        "DELETE FROM metadata WHERE key IN ('_rankingVersion', '_rankingCursor')",
      );
      database.close();
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      final criteria = SearchCriteria(query: 'archive');
      final pending = disk.search(
        criteria,
        SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'archive',
          now: now,
        ),
        ['archive'],
        'archive',
      );
      await disk.cancelSearch();
      expect(await pending, isEmpty);
      await disk.prepare();
      await check(criteria);
      expect(await disk.readMetadata('_rankingVersion'), 6);
      expect(await disk.readMetadata('_rankingCursor'), isNull);
    },
  );

  test(
    'common templates prune safely and identical timestamps retain ID ties',
    () async {
      final text = List.generate(200, (n) => 'topic$n').join(' ');
      Future<void> populate({required bool tied}) async {
        await disk.clear();
        docs = [
          for (var n = 0; n < 512; n++)
            Conversation(
              id: 'template-${n.toString().padLeft(4, '0')}',
              title: 'Archive',
              source: 'manual',
              participantIds: const [],
              segments: [ConversationSegment(id: 'segment', text: text)],
              startedAt: now.subtract(Duration(hours: tied ? 0 : n)),
              endedAt: now.subtract(Duration(hours: tied ? 0 : n)),
            ),
        ];
        await upsert(docs);
      }

      await populate(tied: false);
      await check(SearchCriteria(query: 'archive'));
      final profile = await disk.searchProfile;
      expect(profile['docpagesReads'] ?? 0, 0);
      expect(profile['postingCacheHits'], greaterThan(0));
      expect(profile['scorePostingSqlReads'], 0);
      expect(
        profile['postingCachePeakBytes'],
        lessThanOrEqualTo(16 * 1024 * 1024),
      );
      expect(profile['postingCacheEntries'], lessThanOrEqualTo(65536));
      expect(
        (await disk.searchProfile)['scoretilesReads'],
        lessThanOrEqualTo(13),
      );
      await populate(tied: true);
      await check(SearchCriteria(query: 'archive'));
    },
  );

  test(
    'ready preparation preserves active queries and cancellation is explicit',
    () async {
      final criteria = SearchCriteria(query: 'archive');
      final active = disk.search(
        criteria,
        SearchScorer(
          temporalIntent: null,
          normalizedQuery: 'archive',
          now: now,
        ),
        ['archive'],
        'archive',
      );
      await disk.prepare();
      expect(await active, hasLength(100));
      final cancelled = expectLater(disk.prepare(), throwsStateError);
      await disk.cancelSearch();
      await cancelled;
      await disk.prepare();
      await check(criteria);
    },
  );

  test(
    'phrase bounds preserve substring edges and exclude impossible typos',
    () async {
      Future<void> populate(String Function(int) text) async {
        await disk.clear();
        docs = [
          for (var n = 0; n < 512; n++)
            Conversation(
              id: 'phrase-${n.toString().padLeft(4, '0')}',
              title: '',
              source: 'manual',
              participantIds: const [],
              segments: [ConversationSegment(id: 'segment', text: text(n))],
              startedAt: now.subtract(Duration(hours: n)),
              endedAt: now.subtract(Duration(hours: n)),
            ),
        ];
        await upsert(docs);
      }

      await populate((_) => 'archive separated project');
      for (final query in ['archvie', 'archvie projct', 'archive project']) {
        await check(SearchCriteria(query: query));
        expect((await disk.searchProfile)['docpagesReads'] ?? 0, 0);
        expect(
          (await disk.searchProfile)['scoretilesReads'],
          lessThanOrEqualTo(13),
        );
      }
      expect((await disk.searchProfile)['positionReads'], greaterThan(0));
      await populate(
        (n) => n < 256 ? 'archive separated project' : 'fooarchive projector',
      );
      final partial = SearchCriteria(
        query: 'archive project',
        useVector: false,
      );
      await check(partial);
      final result = await disk.search(
        partial,
        SearchScorer(
          temporalIntent: null,
          normalizedQuery: partial.normalized,
          now: now,
        ),
        ['archive', 'project'],
        'archive project',
      );
      expect(result.first.id, 'phrase-0256');
      await populate(
        (n) => n < 256
            ? '123 gap 5 afoo gap boo'
            : '123 gap 5 9123 567 afoo xa boo',
      );
      await check(SearchCriteria(query: '123 5'));
      expect((await disk.searchProfile)['docpagesReads'], greaterThan(0));
      await check(SearchCriteria(query: 'a b'));
    },
  );

  test(
    'v1 position upgrades reset old cursors and resume v6 checkpoints',
    () async {
      for (final migrationVersion in [1, 4, 5, 6]) {
        await disk.writeMetadata('_rankingVersion', 1);
        await disk.writeMetadata('_rankingCursor', 8);
        await disk.writeMetadata('_rankingMigrationVersion', migrationVersion);
        await disk.close();
        final database = sql.sqlite3.open('${directory.path}/index.sqlite');
        Map<String, String> sourcePages() => {
          for (final table in ['docpages', 'bodypages', 'summarypages'])
            for (final row in database.select('SELECT id, payload FROM $table'))
              '$table:${row['id']}': base64Encode(row['payload'] as List<int>),
        };
        final original = sourcePages();
        for (final row in database.select(
          'SELECT term, page, payload FROM postings',
        )) {
          // A v6 cursor at block 8 means the first posting page already committed.
          if (migrationVersion == 6 && row['page'] == 0) continue;
          final legacy = await transformEncrypted(
            row['payload'] as List<int>,
            (plain) =>
                plain.sublist(0, (row['term'] as int).isEven ? 128 : 168),
          );
          database.execute(
            'UPDATE postings SET payload = ? WHERE term = ? AND page = ?',
            [legacy, row['term'], row['page']],
          );
        }
        disk = await DiskSearchIndex.open(
          path: '${directory.path}/index.sqlite',
          vaultKey: key,
        );
        await disk.prepare();
        expect(await disk.readMetadata('_rankingVersion'), 6);
        expect(await disk.readMetadata('_rankingCursor'), isNull);
        expect(await disk.readMetadata('_rankingMigrationVersion'), isNull);
        expect(sourcePages(), original);
        database.close();
        await check(SearchCriteria(query: 'archive project'));
      }
    },
  );

  test(
    'authenticated malformed position tails fail instead of pruning results',
    () async {
      await disk.close();
      final database = sql.sqlite3.open('${directory.path}/index.sqlite');
      final lookup = (await Hmac.sha256().calculateMac(
        utf8.encode('term:archive'),
        secretKey: SecretKey(key),
      )).bytes;
      final term = database.select('SELECT id FROM terms WHERE lookup = ?', [
        Uint8List.fromList(lookup),
      ]).single['id'];
      final row = database.select(
        'SELECT page, payload FROM postings WHERE term = ? LIMIT 1',
        [term],
      ).single;
      final malformed = await transformEncrypted(row['payload'] as List<int>, (
        plain,
      ) {
        plain[plain.length - 1] ^= 1;
        return plain;
      });
      database.execute(
        'UPDATE postings SET payload = ? WHERE term = ? AND page = ?',
        [malformed, term, row['page']],
      );
      database.close();
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      final criteria = SearchCriteria(query: 'archive project');
      await expectLater(
        disk.search(
          criteria,
          SearchScorer(
            temporalIntent: null,
            normalizedQuery: criteria.normalized,
            now: now,
          ),
          ['archive', 'project'],
          'archive project',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'sparse candidates load score tiles and missing required tiles fail',
    () async {
      final criteria = SearchCriteria(query: '0');
      await check(criteria);
      final profile = await disk.searchProfile;
      expect(profile['scoretilesReads'], 1);
      expect(profile['docpagesReads'] ?? 0, 0);
      expect(profile['summarypagesReads'] ?? 0, 0);
      expect(profile['vocabularyReads'] ?? 0, 0);
      final database = sql.sqlite3.open('${directory.path}/index.sqlite');
      try {
        database.execute(
          'UPDATE docpages SET payload = zeroblob(length(payload)) WHERE id = 0',
        );
        await check(criteria);
        database.execute(
          'DELETE FROM scoretiles WHERE id = (SELECT MAX(id) FROM scoretiles)',
        );
        await check(criteria);
        database.execute('DELETE FROM scoretiles WHERE id = 0');
        await expectLater(
          disk.search(
            criteria,
            SearchScorer(temporalIntent: null, normalizedQuery: '0', now: now),
            ['0'],
            '0',
          ),
          throwsStateError,
        );
      } finally {
        database.close();
      }
    },
  );

  test(
    'v2 positional upgrade preserves canonical ciphertext and untouched tiles',
    () async {
      final database = sql.sqlite3.open('${directory.path}/index.sqlite');
      try {
        for (final row in database.select(
          'SELECT term, page, payload FROM postings',
        )) {
          final legacy = await transformEncrypted(row['payload'] as List<int>, (
            plain,
          ) {
            final bitmap = Uint8List.sublistView(plain, 0, 128);
            final positions = decodePostingPositions(
              bitmap,
              Uint8List.fromList(gzip.decode(plain.sublist(169))),
              hasFieldBoosts: true,
            );
            return [
              ...plain.sublist(0, 168),
              ...gzip.encode(encodePostingPositions(bitmap, positions)),
            ];
          });
          database.execute(
            'UPDATE postings SET payload = ? WHERE term = ? AND page = ?',
            [legacy, row['term'], row['page']],
          );
        }
        await disk.writeMetadata('_rankingVersion', 2);
        await disk.writeMetadata('_rankingMigrationVersion', 2);
        await disk.writeMetadata('_rankingCursor', 8);
        await disk.close();
        final originalDocuments = <int, String>{};
        for (final row in database.select('SELECT id, payload FROM docpages')) {
          final legacy = await transformEncrypted(row['payload'] as List<int>, (
            plain,
          ) {
            final documents =
                jsonDecode(utf8.decode(gzip.decode(plain))) as List;
            for (final data in documents) {
              if (data is Map) data.remove('n');
            }
            return gzip.encode(utf8.encode(jsonEncode(documents)));
          });
          database.execute('UPDATE docpages SET payload = ? WHERE id = ?', [
            legacy,
            row['id'],
          ]);
          originalDocuments[row['id'] as int] = base64Encode(legacy);
        }
        database.execute(
          'CREATE TABLE ranking_witnesses (term INTEGER, block INTEGER)',
        );
        database.execute('CREATE INDEX terms_df ON terms (df DESC)');
        database.execute('DELETE FROM scoretiles');
        disk = await DiskSearchIndex.open(
          path: '${directory.path}/index.sqlite',
          vaultKey: key,
        );
        await disk.prepare();

        expect({
          for (final row in database.select('SELECT id, payload FROM docpages'))
            row['id'] as int: base64Encode(row['payload'] as List<int>),
        }, originalDocuments);
        expect(
          database.select(
            "SELECT name FROM sqlite_master WHERE name IN ('ranking_witnesses', 'terms_df')",
          ),
          isEmpty,
        );
        await check(SearchCriteria(query: 'archive'));
        await check(SearchCriteria(query: '0'));
        final untouched = base64Encode(
          database
                  .select('SELECT payload FROM scoretiles WHERE id = 1')
                  .single['payload']
              as List<int>,
        );
        docs[0] = item(0, text: 'replacement insurance project');
        await upsert([docs[0]]);
        expect(
          base64Encode(
            database
                    .select('SELECT payload FROM scoretiles WHERE id = 1')
                    .single['payload']
                as List<int>,
          ),
          untouched,
        );
        await check(SearchCriteria(query: '0'));
        await check(SearchCriteria(query: 'replacement insurance'));
      } finally {
        database.close();
      }
    },
  );

  test(
    'queued mutations survive both cold migration and warm preparation',
    () async {
      for (final legacy in [true, false]) {
        if (legacy) {
          await disk.writeMetadata('_rankingVersion', 4);
          await disk.close();
          final database = sql.sqlite3.open('${directory.path}/index.sqlite');
          database.execute('DELETE FROM rankdocuments');
          database.close();
          disk = await DiskSearchIndex.open(
            path: '${directory.path}/index.sqlite',
            vaultKey: key,
          );
        } else {
          await disk.prepare();
        }
        docs[0] = item(0, title: 'First queued insurance');
        docs[1] = item(1, title: 'Second queued insurance');
        await Future.wait([
          upsert([docs[0]]),
          upsert([docs[1]]),
        ]);
        await check(SearchCriteria(query: 'queued insurance'));
        expect((await disk.loadConversation(docs[0].id)).title, docs[0].title);
        expect((await disk.loadConversation(docs[1].id)).title, docs[1].title);
      }
    },
  );

  test(
    'v5 combined tiles migrate to summaries and numeric pages warm once',
    () async {
      await disk.writeMetadata('_rankingVersion', 5);
      await disk.close();
      final database = sql.sqlite3.open('${directory.path}/index.sqlite');
      Map<int, String> tiles() => {
        for (final row in database.select('SELECT id,payload FROM scoretiles'))
          row['id'] as int: base64Encode(row['payload'] as List<int>),
      };
      for (final row in database.select('SELECT id,payload FROM scoretiles')) {
        final tile = row['id'] as int;
        final packedDocuments =
            database.select('SELECT payload FROM docpages WHERE id = ?', [
                  tile ~/ 16,
                ]).single['payload']
                as List<int>;
        late List originalDocuments;
        await transformEncrypted(packedDocuments, (plain) {
          originalDocuments =
              jsonDecode(utf8.decode(gzip.decode(plain))) as List;
          return plain;
        });
        final combined = await transformEncrypted(row['payload'] as List<int>, (
          plain,
        ) {
          final summaries = jsonDecode(utf8.decode(gzip.decode(plain))) as List;
          return gzip.encode(
            utf8.encode(
              jsonEncode([
                for (var n = 0; n < summaries.length; n++)
                  [originalDocuments[(tile % 16) * 8 + n], summaries[n]],
              ]),
            ),
          );
        });
        database.execute('UPDATE scoretiles SET payload = ? WHERE id = ?', [
          combined,
          tile,
        ]);
      }
      final originalTiles = tiles();
      database.execute('DELETE FROM rankdocuments');
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      await disk.prepare();
      final migratedTiles = tiles();
      expect(migratedTiles.keys, containsAll(originalTiles.keys));
      // Reserved source ranges can add empty tiles during migration.
      for (final tile in migratedTiles.keys.where(
        (tile) => !originalTiles.containsKey(tile),
      )) {
        await transformEncrypted(base64Decode(migratedTiles[tile]!), (plain) {
          expect(
            jsonDecode(utf8.decode(gzip.decode(plain))),
            everyElement(isNull),
          );
          return plain;
        });
      }
      expect(tiles(), isNot(originalTiles));
      await check(SearchCriteria(query: 'archive project'));
      database.execute(
        'UPDATE rankdocuments SET payload = zeroblob(length(payload))',
      );
      // Warm preparation and subsequent queries reuse the authenticated cache.
      await disk.prepare();
      await check(SearchCriteria(query: 'archive project'));
      await disk.close();
      disk = await DiskSearchIndex.open(
        path: '${directory.path}/index.sqlite',
        vaultKey: key,
      );
      await expectLater(disk.prepare(), throwsStateError);
      database.close();
    },
  );

  test(
    'empty-corpus preparation warms recents without reading old holes',
    () async {
      await disk.remove(docs.map((doc) => doc.id).toList());
      expect(await disk.count, 0);
      await disk.writeMetadata('_recentFrontier', null);
      final database = sql.sqlite3.open('${directory.path}/index.sqlite');
      try {
        database.execute(
          'UPDATE summarypages SET payload = zeroblob(length(payload))',
        );
        await disk.prepare();
        final recent = await disk.readMetadata('_recentFrontier') as Map;
        expect(
          (recent['groups'] as List).every((group) => (group as List).isEmpty),
          isTrue,
        );
        expect(
          await disk.search(
            SearchCriteria(query: ''),
            SearchScorer(temporalIntent: null, normalizedQuery: '', now: now),
            const [],
            '',
          ),
          isEmpty,
        );
      } finally {
        database.close();
      }
    },
  );
  test(
    'sorted phrase unions preserve long repeated and substring positions',
    () async {
      await disk.clear();
      docs = [
        for (var n = 0; n < 180; n++)
          item(
            n,
            title: n % 3 == 0 ? 'Archive projector' : 'Transcript',
            text: [
              for (var k = 0; k < 400 + n % 10; k++)
                n % 4 == 0
                    ? 'archive archive project projector'
                    : n % 4 == 1
                    ? 'archival importer archive import'
                    : n % 4 == 2
                    ? 'import archive import archive'
                    : 'archived importing archive importer',
              if (n % 7 == 0) 'archive insurance renewal',
            ].join(' '),
          ),
      ];
      await upsert(docs);
      for (final query in [
        'archive archive',
        'archive archive project',
        'archive import',
        'ive imp',
        'archive projector',
        'archive insuranc',
        'archive insurance renewal',
        'archive archival',
        'arhive import',
        'archive 123',
        'a import',
      ]) {
        for (final vector in [false, true]) {
          await check(SearchCriteria(query: query, useVector: vector));
        }
      }
    },
  );
}
