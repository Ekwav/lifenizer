import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:cryptography/cryptography.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import '../models.dart';
import 'conversation_search_index.dart';
import 'native_sidecar_aead.dart';
import 'native_posting_inflate.dart';
import 'search_criteria.dart';
import 'search_lexicon_routes.dart';
import 'search_posting_positions.dart';
import 'search_scorer.dart';
import 'search_source_groups.dart';
import 'source_categories.dart';
import 'string_distance_service.dart';
import 'temporal_intent.dart';

part 'disk_search_ranking.dart';
part 'disk_search_filters.dart';
part 'disk_search_pool.dart';

// Managed buffers avoid native zlib allocator retention across large builds.
Uint8List _managedEncode(List<int> bytes) =>
    const archive.GZipEncoderWeb().encodeBytes(bytes);

Uint8List _managedDecode(List<int> bytes) {
  // ISIZE is only a bounded allocation hint; the decoder still validates it.
  final end = bytes.length;
  final initialSize = end < 4
      ? 64
      : (bytes[end - 4] |
                bytes[end - 3] << 8 |
                bytes[end - 2] << 16 |
                bytes[end - 1] << 24)
            .clamp(64, 64 * 1024);
  final output = archive.OutputMemoryStream(size: initialSize);
  if (!const archive.GZipDecoderWeb().decodeStream(
    archive.InputMemoryStream(bytes),
    output,
    verify: true,
  )) {
    throw const FormatException('Invalid or truncated gzip stream');
  }
  return output.getBytes();
}

/// Native search storage. SQLite sees opaque lookup keys, numeric bookkeeping and
/// ciphertext only; decrypted pages and query caches have fixed size limits.
class DiskSearchIndex {
  DiskSearchIndex._(this._request);
  final Future<Object?> Function(String, Object?) _request;
  static const int writeBatchSize = 1024;

  /// Native resource policy, shared with callers planning their cache budget.
  static int automaticSearchWorkers(int conversationCount, int processors) =>
      conversationCount < 250000 ? 1 : math.min(8, math.max(1, processors));

  /// Automatic parallel queries start at 250,000 conversations, using up to
  /// eight CPU cores. An explicit [searchWorkers] overrides that policy;
  /// one retains the serial path.
  static Future<DiskSearchIndex> open({
    required String path,
    required List<int> vaultKey,
    bool recreateOnFailure = false,
    int? searchWorkers,
  }) async {
    if (searchWorkers != null && (searchWorkers < 1 || searchWorkers > 16)) {
      throw ArgumentError.value(
        searchWorkers,
        'searchWorkers',
        'Requires 1..16',
      );
    }
    final writer = await _openWorker(
      path: path,
      vaultKey: vaultKey,
      recreateOnFailure: recreateOnFailure,
    );
    if (searchWorkers == 1) return writer;
    return DiskSearchIndex._(
      _DiskSearchPool(writer, path, vaultKey, searchWorkers).request,
    );
  }

  static Future<DiskSearchIndex> _openWorker({
    required String path,
    required List<int> vaultKey,
    bool recreateOnFailure = false,
    bool readOnly = false,
    int rangeStart = 0,
    int? rangeEnd,
    int sqliteCacheKiB = 16384,
  }) async {
    if (vaultKey.length != 32) {
      throw const FormatException('Invalid device key.');
    }
    final port = ReceivePort();
    final ended = Completer<void>();
    final ready = Completer<SendPort>();
    final pending = <int, Completer<Object?>>{};
    var sequence = 0;
    var requestGeneration = 0;
    var closed = false;
    Future<Object?>? closing;
    void fail(Object error) {
      closed = true;
      if (!ready.isCompleted) ready.completeError(error);
      for (final completer in pending.values) {
        completer.completeError(error);
      }
      pending.clear();
    }

    port.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is List && message.length == 3) {
        final completer = pending.remove(message[0]);
        if (message[1] == true) {
          completer?.complete(message[2]);
        } else {
          completer?.completeError(StateError(message[2] as String));
        }
      } else if (message is List && message.length == 2) {
        fail(
          StateError(
            'The disk search worker failed: ${message[0]}\n${message[1]}',
          ),
        );
      } else {
        if (!ended.isCompleted) ended.complete();
        if (!closed) fail(StateError('The disk search worker stopped.'));
        port.close();
      }
    });
    ready.future.ignore();
    try {
      await Isolate.spawn(
        _serve,
        (
          path,
          vaultKey.toList(),
          port.sendPort,
          readOnly,
          rangeStart,
          rangeEnd,
          sqliteCacheKiB,
        ),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
    } catch (_) {
      port.close();
      rethrow;
    }
    late SendPort commands;
    try {
      commands = await ready.future;
    } catch (_) {
      // Startup failures must release SQLite before replacing this disposable
      // sidecar. An error notification alone does not prove the worker exited.
      await ended.future;
      if (!recreateOnFailure) rethrow;
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$path$suffix');
        if (await file.exists()) await file.delete();
      }
      return _openWorker(path: path, vaultKey: vaultKey);
    }
    return DiskSearchIndex._((operation, value) async {
      if (closed) {
        if (operation == 'close') {
          if (closing != null) return closing;
          await ended.future;
          return null;
        }
        throw StateError('The disk search index is closed.');
      }
      if (operation == 'close') closed = true;
      if (const {
        'search',
        'cancelSearch',
        'close',
        'clear',
        'upsert',
        'remove',
      }.contains(operation)) {
        requestGeneration++;
      }
      final generation = requestGeneration;
      final id = sequence++;
      final result = Completer<Object?>();
      pending[id] = result;
      if (operation == 'close') {
        closing = result.future.whenComplete(() => ended.future);
      }
      commands.send([id, operation, value]);
      if (operation == 'close') return closing;
      final response = await result.future;
      // A fast worker can finish before receiving an already queued cancel.
      if (generation != requestGeneration) {
        if (operation == 'search') return const _SearchReply([], {}, []);
        if (operation == 'prepare') {
          throw StateError('Search index preparation was cancelled.');
        }
      }
      return response;
    });
  }

  Future<void> clear() async {
    await _request('clear', null);
  }

  Future<void> prepare() async {
    await _request('prepare', null);
  }

  Future<int> get count async => await _request('count', null) as int;

  Future<Map<String, int>> get searchProfile async =>
      Map<String, int>.from(await _request('searchProfile', null) as Map);

  Future<void> upsert(
    List<Conversation> batch, {
    required Map<String, String> participantById,
    required Map<String, String> relationTextByConversation,
  }) async {
    // New documents share bounded source pages; existing updates are split into
    // smaller transactions in the worker to bound decrypted random pages.
    for (var start = 0; start < batch.length; start += writeBatchSize) {
      final part = batch.sublist(
        start,
        math.min(start + writeBatchSize, batch.length),
      );
      await _request('upsert', (
        part,
        participantById,
        {
          for (final doc in part)
            if (relationTextByConversation[doc.id] case final String value)
              doc.id: value,
        },
      ));
    }
  }

  Future<void> remove(List<String> ids) async {
    for (var start = 0; start < ids.length; start += 128) {
      await _request(
        'remove',
        ids.sublist(start, math.min(start + 128, ids.length)),
      );
    }
  }

  Future<List<Conversation>> search(
    SearchCriteria criteria,
    SearchScorer scorer,
    List<String> tokens,
    String normalized, {
    int maxResults = 100,
  }) async =>
      (await _request('search', (
                criteria,
                scorer,
                tokens,
                normalized,
                maxResults.clamp(1, 100),
              ))
              as _SearchReply)
          .results;

  Future<List<Conversation>> summaries({
    int offset = 0,
    int limit = 1000,
    String? afterId,
  }) async =>
      (await _request('summaries', (offset, limit.clamp(1, 1000), afterId))
              as List)
          .cast<Conversation>();

  Future<Conversation> loadConversation(String id) async =>
      await _request('loadConversation', id) as Conversation;

  Future<List<Conversation>> loadConversations(List<String> ids) async {
    final result = <Conversation>[];
    for (var start = 0; start < ids.length; start += 128) {
      result.addAll(
        (await _request(
                  'loadConversations',
                  ids.sublist(start, math.min(start + 128, ids.length)),
                )
                as List)
            .cast<Conversation>(),
      );
    }
    return result;
  }

  Future<Object?> readMetadata(String key) => _request('readMetadata', key);
  Future<void> writeMetadata(String key, Object? value) async {
    await _request('writeMetadata', (key, value));
  }

  Future<void> cancelSearch() async {
    await _request('cancelSearch', null);
  }

  Future<void> close() async {
    await _request('close', null);
  }
}

Future<void> _serve(
  (String, List<int>, SendPort, bool, int, int?, int) setup,
) async {
  final (path, bytes, responses, readOnly, start, end, cacheKiB) = setup;
  late final _DiskStore store;
  try {
    store = _DiskStore(
      path,
      bytes,
      readOnly: readOnly,
      rangeStart: start,
      rangeEnd: end,
      sqliteCacheKiB: cacheKiB,
    );
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
  final commands = ReceivePort();
  try {
    await store.initialize();
    final stopped = Completer<void>();
    var tail = Future<void>.value();
    commands.listen((message) {
      final request = message as List;
      final operation = request[1] as String;
      if (const {
        'search',
        'cancelSearch',
        'close',
        'clear',
        'upsert',
        'remove',
      }.contains(operation)) {
        store.searchGeneration++;
      }
      final generation = store.searchGeneration;
      if (operation == 'cancelSearch') {
        responses.send([request[0], true, null]);
        return;
      }
      // Control messages can cancel a query while mutations remain serialized.
      tail = tail.then((_) async {
        try {
          final value = await store.request(
            operation,
            request[2],
            generation: generation,
          );
          responses.send([request[0], true, value]);
        } catch (error) {
          responses.send([request[0], false, error.toString()]);
        }
        if (operation == 'close' && !stopped.isCompleted) stopped.complete();
      });
    });
    responses.send(commands.sendPort);
    await stopped.future;
  } finally {
    commands.close();
    store.close();
  }
}

class _Term {
  const _Term(this.word, this.idf, this.matches, this.exact, this.phrase);
  final String word;
  final double idf;
  final List<double> matches;
  final bool exact;
  final List<int> phrase;
}

typedef _RecentItem = ({int ordinal, int time, String id});

int _compareRecent(_RecentItem a, _RecentItem b) {
  final time = b.time.compareTo(a.time);
  return time != 0 ? time : a.id.compareTo(b.id);
}

class _DiskStore {
  _DiskStore(
    String path,
    List<int> bytes, {
    this.readOnly = false,
    this.rangeStart = 0,
    this.rangeEnd,
    this.sqliteCacheKiB = 16384,
  }) : database = sql.sqlite3.open(
         path,
         mode: readOnly ? sql.OpenMode.readOnly : sql.OpenMode.readWriteCreate,
       ),
       key = SecretKeyData(bytes.toList(), overwriteWhenDestroyed: true);
  final bool readOnly;
  final int rangeStart;
  final int? rangeEnd;
  int sqliteCacheKiB;
  int get rangeLimit => math.min(rangeEnd ?? nextDocument, nextDocument);
  final sql.Database database;
  final SecretKeyData key;
  final cipher = AesGcm.with256bits();
  NativeSidecarAead? _nativeCipher;
  final hmac = Hmac.sha256();
  late final ranking = _DiskRanking(this);
  late final filters = _DiskFilters(this);
  final _termIds = <String, int>{};
  final _lexiconKeys = <String, Uint8List>{};
  int documentCount = 0;
  int totalLength = 0;
  int nextDocument = 0;
  int nextTerm = 0;
  bool _closed = false;
  int searchGeneration = 0;
  final _searchProfile = <String, int>{};
  bool _profilingSearch = false;
  final _groupKeys = <SearchSourceGroup, Uint8List>{};
  static const docPageSize = 128;
  static const updateBatchSize = 128;
  static const vocabPageSize = 256;
  static const postingPageSize = 1024;
  static const cacheSize = 65536;
  // Bump when groupForSource changes so existing pages acquire new routes.
  static const sourcePartitionVersion = 1;

  Future<void> initialize() async {
    _nativeCipher = NativeSidecarAead.tryCreate(key.bytes);
    database.execute('PRAGMA cache_size = -$sqliteCacheKiB');
    database.execute('PRAGMA temp_store = MEMORY');
    if (!readOnly) {
      ranking.initialize();
      filters.initialize();
      database.execute(
        'CREATE TABLE IF NOT EXISTS documents '
        '(id INTEGER PRIMARY KEY, lookup BLOB UNIQUE NOT NULL)',
      );
      database.execute(
        'CREATE TABLE IF NOT EXISTS terms '
        '(id INTEGER PRIMARY KEY, lookup BLOB UNIQUE NOT NULL, df INTEGER NOT NULL)',
      );
      for (final table in [
        'docpages',
        'bodypages',
        'summarypages',
        'vocabulary',
      ]) {
        database.execute(
          'CREATE TABLE IF NOT EXISTS $table '
          '(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)',
        );
      }
      database.execute(
        'CREATE TABLE IF NOT EXISTS postings '
        '(term INTEGER NOT NULL, page INTEGER NOT NULL, payload BLOB NOT NULL, '
        'PRIMARY KEY (term, page)) WITHOUT ROWID',
      );
      database.execute(
        'CREATE TABLE IF NOT EXISTS page_groups '
        '(page INTEGER NOT NULL, group_key BLOB NOT NULL, '
        'PRIMARY KEY (group_key, page)) WITHOUT ROWID',
      );
      database.execute(
        'CREATE TABLE IF NOT EXISTS lexicon_routes '
        '(lookup BLOB NOT NULL, page INTEGER NOT NULL, '
        'PRIMARY KEY (lookup, page)) WITHOUT ROWID',
      );
      database.execute(
        'CREATE TABLE IF NOT EXISTS metadata '
        '(key TEXT PRIMARY KEY, payload BLOB NOT NULL)',
      );
    }
    for (final group in SearchSourceGroup.values) {
      _groupKeys[group] = await lookup('source-group', group.name);
    }
    final state = await readMetadata('_state');
    if (state != null) {
      final values = state as List;
      documentCount = values[0] as int;
      totalLength = values[1] as int;
      nextDocument = values[2] as int;
      nextTerm = values[3] as int;
    } else if (database
            .select('SELECT COUNT(*) AS n FROM documents')
            .single['n'] !=
        0) {
      throw StateError('Incomplete disk search index.');
    }
    if (readOnly &&
        (state == null ||
            await readMetadata('_lexiconRoutes') != 1 ||
            await readMetadata('_sourcePartitions') != sourcePartitionVersion ||
            await readMetadata('_rankingVersion') != _DiskRanking.version ||
            await readMetadata('_filterVersion') != 1 ||
            await readRecent() == null)) {
      throw StateError('Read-only search metadata is not prepared.');
    }
  }

  Future<Object?> request(
    String operation,
    Object? value, {
    required int generation,
  }) async {
    if (!readOnly &&
        sqliteCacheKiB == 0 &&
        const {
          'prepare',
          'clear',
          'upsert',
          'remove',
          'writeMetadata',
        }.contains(operation)) {
      sqliteCacheKiB = 16384;
      database.execute('PRAGMA cache_size = -$sqliteCacheKiB');
    }
    switch (operation) {
      case 'documentCapacity':
        return nextDocument;
      case 'releaseQueryBuffers':
        ranking.invalidate();
        filters.invalidate();
        _termIds.clear();
        _lexiconKeys.clear();
        sqliteCacheKiB = 0;
        database.execute('PRAGMA cache_size = 0');
        database.execute('PRAGMA shrink_memory');
        return ranking._numericCache.values.fold<int>(
          0,
          (size, page) => size + page.length,
        );
      case 'clear':
        database.execute('BEGIN IMMEDIATE');
        try {
          for (final table in [
            'documents',
            'terms',
            'docpages',
            'bodypages',
            'summarypages',
            'vocabulary',
            'postings',
            'page_groups',
            'rankingpages',
            'rankdocuments',
            'scoretiles',
            'filterpostings',
            'lexicon_routes',
            'metadata',
          ]) {
            database.execute('DELETE FROM $table');
          }
          await writeMetadata('_state', [0, 0, 0, 0]);
          database.execute('COMMIT');
          documentCount = totalLength = nextDocument = nextTerm = 0;
          _termIds.clear();
          ranking.invalidate();
          filters.invalidate();
        } catch (_) {
          database.execute('ROLLBACK');
          rethrow;
        }
        return null;
      case 'prepare':
        if (generation != searchGeneration ||
            !await ensureLexiconRoutes(generation) ||
            !await ensureSourcePartitions(generation) ||
            !await ranking.ensure(
              generation,
              warmNumericCache: value != false,
            ) ||
            !await filters.ensure(generation) ||
            await ensureRecent(generation) == null ||
            generation != searchGeneration) {
          throw StateError('Search index preparation was cancelled.');
        }
        return null;
      case 'count':
        return documentCount;
      case 'searchProfile':
        return Map<String, int>.of(_searchProfile);
      case 'upsert':
        final (
          docs,
          people,
          relations,
        ) = value
            as (List<Conversation>, Map<String, String>, Map<String, String>);
        if (!await ranking.ensure(null)) {
          throw StateError('Search index preparation was cancelled.');
        }
        var batchSize = DiskSearchIndex.writeBatchSize;
        if (docs.length > updateBatchSize) {
          for (final doc in docs) {
            if (database.select('SELECT 1 FROM documents WHERE lookup = ?', [
              await lookup('document', doc.id),
            ]).isNotEmpty) {
              batchSize = updateBatchSize;
              break;
            }
          }
        }
        for (var start = 0; start < docs.length; start += batchSize) {
          await update(
            docs.sublist(start, math.min(start + batchSize, docs.length)),
            people,
            relations,
            const [],
          );
        }
        return null;
      case 'remove':
        if (!await ranking.ensure(null)) {
          throw StateError('Search index preparation was cancelled.');
        }
        await update(
          const [],
          const {},
          const {},
          (value as List).cast<String>(),
        );
        return null;
      case 'search':
        final (criteria, scorer, tokens, normalized, limit) =
            value as (SearchCriteria, SearchScorer, List<String>, String, int);
        _profilingSearch = true;
        try {
          final scores = <_SearchScore>[];
          final results = await search(
            criteria,
            scorer,
            tokens,
            normalized,
            limit,
            generation,
            scores,
          );
          _searchProfile['numericCachedBytes'] = ranking._numericCache.values
              .fold<int>(0, (size, page) => size + page.length);
          _searchProfile['sqliteCacheKiB'] = sqliteCacheKiB;
          _searchProfile['sqliteCacheTotalBudgetKiB'] = sqliteCacheKiB;
          return _SearchReply(results, Map.of(_searchProfile), scores);
        } finally {
          _profilingSearch = false;
        }
      case 'summaries':
        final (offset, limit, afterId) = value as (int, int, String?);
        return summaries(offset, limit, afterId);
      case 'loadConversation':
        return (await loadConversations([value as String])).single;
      case 'loadConversations':
        return loadConversations((value as List).cast<String>());
      case 'readMetadata':
        return readMetadata(value as String);
      case 'writeMetadata':
        final (name, data) = value as (String, Object?);
        if (name == '_state') throw ArgumentError('Reserved metadata key.');
        await writeMetadata(name, data);
        return null;
      case 'close':
        close();
        return null;
      default:
        throw ArgumentError('Unknown disk search operation.');
    }
  }

  Future<Uint8List> seal(Object? value) =>
      sealBytes(_managedEncode(utf8.encode(jsonEncode(value))));

  Future<Uint8List> sealBytes(List<int> plain) async {
    final nonce = cipher.newNonce();
    final native = _nativeCipher;
    if (native != null) return native.encrypt(plain, nonce);
    final box = await cipher.encrypt(plain, secretKey: key, nonce: nonce);
    return Uint8List(28 + box.cipherText.length)
      ..setRange(0, 12, nonce)
      ..setRange(12, 28, box.mac.bytes)
      ..setRange(28, 28 + box.cipherText.length, box.cipherText);
  }

  Future<Uint8List> unsealBytes(List<int> bytes) async {
    final packed = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final native = _nativeCipher;
    if (native != null) return native.decrypt(packed);
    final clear = await cipher.decrypt(
      SecretBox(
        Uint8List.sublistView(packed, 28),
        nonce: Uint8List.sublistView(packed, 0, 12),
        mac: Mac(Uint8List.sublistView(packed, 12, 28)),
      ),
      secretKey: key,
    );
    return clear is Uint8List ? clear : Uint8List.fromList(clear);
  }

  Future<Object?> unseal(List<int> bytes) async {
    return jsonDecode(utf8.decode(_managedDecode(await unsealBytes(bytes))));
  }

  Future<Uint8List> lookup(String kind, String value) async =>
      Uint8List.fromList(
        (await hmac.calculateMac(
          utf8.encode('$kind:$value'),
          secretKey: key,
        )).bytes,
      );

  Future<Object?> readMetadata(String name) async {
    final rows = database.select('SELECT payload FROM metadata WHERE key = ?', [
      name,
    ]);
    return rows.isEmpty ? null : unseal(rows.single['payload'] as List<int>);
  }

  Future<void> writeMetadata(String name, Object? value) async {
    database.execute('INSERT OR REPLACE INTO metadata VALUES (?, ?)', [
      name,
      await seal(value),
    ]);
  }

  Future<List<dynamic>> readPage(String table, int page, int size) async {
    if (_profilingSearch) {
      _searchProfile.update('${table}Reads', (n) => n + 1, ifAbsent: () => 1);
    }
    final rows = database.select('SELECT payload FROM $table WHERE id = ?', [
      page,
    ]);
    return rows.isEmpty
        ? List<dynamic>.filled(size, null)
        : (await unseal(rows.single['payload'] as List<int>) as List);
  }

  Future<void> writePage(String table, int page, List<dynamic> values) async {
    database.execute('INSERT OR REPLACE INTO $table VALUES (?, ?)', [
      page,
      await seal(values),
    ]);
  }

  void tagSourcePage(int page, SearchSourceGroup group) {
    database.execute('INSERT OR IGNORE INTO page_groups VALUES (?, ?)', [
      page,
      _groupKeys[group],
    ]);
  }

  /// Existing mixed pages retain their addresses and acquire every source group
  /// they contain. New pages are allocated separately for each group.
  Future<bool> ensureSourcePartitions(int generation) async {
    if (await readMetadata('_sourcePartitions') == sourcePartitionVersion) {
      return true;
    }
    var page = (await readMetadata('_sourcePartitionCursor') as int?) ?? 0;
    final count = (nextDocument + docPageSize - 1) ~/ docPageSize;
    while (page < count) {
      final end = math.min(page + 64, count);
      database.execute('BEGIN IMMEDIATE');
      try {
        while (page < end) {
          if ((page & 7) == 0) await Future<void>.delayed(Duration.zero);
          if (generation != searchGeneration) break;
          final summaries = await readPage('summarypages', page, docPageSize);
          final groups = <SearchSourceGroup>{};
          for (final summary in summaries) {
            if (summary case final Map data) {
              groups.add(groupForSource(data['source'] as String));
            }
          }
          for (final group in groups) {
            tagSourcePage(page, group);
          }
          page++;
        }
        await writeMetadata('_sourcePartitionCursor', page);
        if (page == count) {
          await writeMetadata('_sourcePartitions', sourcePartitionVersion);
          database.execute(
            "DELETE FROM metadata WHERE key = '_sourcePartitionCursor'",
          );
        }
        database.execute('COMMIT');
      } catch (_) {
        database.execute('ROLLBACK');
        rethrow;
      }
      if (generation != searchGeneration) return false;
    }
    return true;
  }

  Future<List<List<_RecentItem>>?> readRecent() async {
    final data = await readMetadata('_recentFrontier');
    if (data == null) return null;
    final groups = (data as Map)['groups'] as List;
    return [
      for (final group in groups)
        [
          for (final row in group as List)
            (
              ordinal: (row as List)[0] as int,
              time: row[1] as int,
              id: row[2] as String,
            ),
        ],
    ];
  }

  Future<List<List<_RecentItem>>?> ensureRecent(int generation) async {
    if (generation != searchGeneration) return null;
    final cached = await readRecent();
    if (cached != null) return cached;
    final recent = List.generate(
      SourceCategory.values.length,
      (_) => <_RecentItem>[],
    );
    if (documentCount > 0) {
      for (var page = 0; page * docPageSize < nextDocument; page++) {
        if ((page & 7) == 0) await Future<void>.delayed(Duration.zero);
        if (generation != searchGeneration) return null;
        final summaries = await readPage('summarypages', page, docPageSize);
        for (var n = 0; n < summaries.length; n++) {
          if (summaries[n] case final Map data) {
            includeRecent(
              recent,
              page * docPageSize + n,
              Conversation.fromSummaryJson(Map<String, dynamic>.from(data)),
            );
          }
        }
      }
    }
    await writeRecent(recent);
    return generation == searchGeneration ? recent : null;
  }

  Future<void> writeRecent(List<List<_RecentItem>> groups) =>
      writeMetadata('_recentFrontier', {
        'groups': [
          for (final group in groups)
            [
              for (final item in group) [item.ordinal, item.time, item.id],
            ],
        ],
      });

  void includeRecent(
    List<List<_RecentItem>> groups,
    int ordinal,
    Conversation conversation,
  ) {
    final group = groups[categoryForSource(conversation.source).index];
    final item = (
      ordinal: ordinal,
      time: conversation.startedAt.microsecondsSinceEpoch,
      id: conversation.id,
    );
    if (group.length == 100 && _compareRecent(item, group.last) >= 0) return;
    var low = 0;
    var high = group.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_compareRecent(item, group[mid]) < 0) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    group.insert(low, item);
    if (group.length > 100) group.removeLast();
  }

  Future<Uint8List> lexiconKey(String gram) async {
    final cached = _lexiconKeys.remove(gram);
    final key = cached ?? await lookup('lexicon-gram', gram);
    _lexiconKeys[gram] = key;
    if (_lexiconKeys.length > 4096) {
      _lexiconKeys.remove(_lexiconKeys.keys.first);
    }
    return key;
  }

  Future<void> routeVocabulary(int page, List<dynamic> words) async {
    final grams = <String>{
      for (final word in words)
        if (word is String) ...searchLexiconGrams(word),
    };
    final insert = database.prepare(
      'INSERT OR IGNORE INTO lexicon_routes VALUES (?, ?)',
    );
    try {
      for (final gram in grams) {
        insert.execute([await lexiconKey(gram), page]);
      }
    } finally {
      insert.close();
    }
  }

  Future<bool> ensureLexiconRoutes(int generation) async {
    if (await readMetadata('_lexiconRoutes') == 1) return true;
    var page = await readMetadata('_lexiconRoutesCursor') as int? ?? 0;
    while (page * vocabPageSize < nextTerm) {
      await Future<void>.delayed(Duration.zero);
      if (generation != searchGeneration) return false;
      database.execute('BEGIN IMMEDIATE');
      try {
        final end = math.min(
          page + 8,
          (nextTerm + vocabPageSize - 1) ~/ vocabPageSize,
        );
        for (; page < end; page++) {
          await routeVocabulary(
            page,
            await readPage('vocabulary', page, vocabPageSize),
          );
        }
        await writeMetadata('_lexiconRoutesCursor', page);
        database.execute('COMMIT');
      } catch (_) {
        database.execute('ROLLBACK');
        rethrow;
      }
    }
    database.execute('BEGIN IMMEDIATE');
    try {
      await writeMetadata('_lexiconRoutes', 1);
      database.execute(
        "DELETE FROM metadata WHERE key = '_lexiconRoutesCursor'",
      );
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
    return generation == searchGeneration;
  }

  Future<List<int>> lexiconPages(String query) async {
    final pages = <int>{};
    for (final gram in searchLexiconQueryGrams(query)) {
      pages.addAll(
        database
            .select('SELECT page FROM lexicon_routes WHERE lookup = ?', [
              await lexiconKey(gram),
            ])
            .map((row) => row['page'] as int),
      );
    }
    return pages.toList()..sort();
  }

  Future<void> update(
    List<Conversation> docs,
    Map<String, String> people,
    Map<String, String> relations,
    List<String> removals,
  ) async {
    final docPages = <int, List<dynamic>>{};
    final bodyPages = <int, List<dynamic>>{};
    final summaryPages = <int, List<dynamic>>{};
    final vocabPages = <int, List<dynamic>>{};
    final postingPages = <(int, int), Uint8List>{};
    final positionPages = <(int, int), Map<int, List<int>>>{};
    final fieldPages = <(int, int), Map<int, int>>{};
    final deltas = <int, int>{};
    final filterWrites = _FilterWrites(filters);
    final changedIds = <int>{};
    final previous = (documentCount, totalLength, nextDocument, nextTerm);
    List<List<_RecentItem>>? recent;
    final activePages = <String, List<int>>{};
    final storedPages =
        await readMetadata('_sourceActivePostingPagesV2') as Map?;
    for (final entry
        in storedPages?.entries ?? const <MapEntry<dynamic, dynamic>>[]) {
      activePages[entry.key as String] = (entry.value as List)
          .cast<int>()
          .toList();
    }
    final empty = documentCount == 0;
    Future<List<dynamic>> docPage(int id) async =>
        docPages[id ~/ docPageSize] ??= await readPage(
          'docpages',
          id ~/ docPageSize,
          docPageSize,
        );
    Future<void> posting(int term, int doc, bool present) async {
      final address = (term, doc ~/ postingPageSize);
      var bits = postingPages[address];
      if (bits == null) {
        final rows = database.select(
          'SELECT payload FROM postings WHERE term = ? AND page = ?',
          [address.$1, address.$2],
        );
        bits = rows.isEmpty
            ? Uint8List(postingPageSize ~/ 8)
            : await unsealBytes(rows.single['payload'] as List<int>);
        postingPages[address] = bits;
        final decoded = ranking.decodePosting(bits);
        positionPages[address] = decoded.positions;
        fieldPages[address] = decoded.boosts;
      }
      final offset = doc % postingPageSize;
      if (present) {
        bits[offset >> 3] |= 1 << (offset & 7);
      } else {
        bits[offset >> 3] &= ~(1 << (offset & 7));
        positionPages[address]!.remove(offset);
        fieldPages[address]!.remove(offset);
      }
      deltas.update(
        term,
        (n) => n + (present ? 1 : -1),
        ifAbsent: () => present ? 1 : -1,
      );
    }

    Future<void> detach(
      int id,
      List<dynamic> page, {
      Conversation? replacement,
    }) async {
      final old = page[id % docPageSize] as Map?;
      if (old == null) return;
      changedIds.add(id);
      for (
        var category = 0;
        recent != null && category < recent!.length;
        category++
      ) {
        final group = recent![category];
        final index = group.indexWhere((item) => item.ordinal == id);
        if (index < 0) continue;
        final item = group[index];
        if (replacement != null &&
            replacement.id == item.id &&
            replacement.startedAt.microsecondsSinceEpoch == item.time &&
            categoryForSource(replacement.source).index == category) {
          group.removeAt(index);
        } else {
          recent = null;
        }
        break;
      }
      final frequency = old['f'] as List;
      for (var n = 0; n < frequency.length; n += 2) {
        await posting(frequency[n] as int, id, false);
      }
      totalLength -= old['l'] as int;
      documentCount--;
      page[id % docPageSize] = null;
      final body = bodyPages[id ~/ docPageSize] ??= await readPage(
        'bodypages',
        id ~/ docPageSize,
        docPageSize,
      );
      body[id % docPageSize] = null;
      final summary = summaryPages[id ~/ docPageSize] ??= await readPage(
        'summarypages',
        id ~/ docPageSize,
        docPageSize,
      );
      if (summary[id % docPageSize] case final Map previousSummary) {
        await filterWrites.change(id, previousSummary, false);
      }
      summary[id % docPageSize] = null;
    }

    database.execute('BEGIN IMMEDIATE');
    try {
      recent = await readRecent();
      if (recent == null && documentCount == 0) {
        recent = List.generate(
          SourceCategory.values.length,
          (_) => <_RecentItem>[],
        );
      }
      database.execute("DELETE FROM metadata WHERE key = 'snapshotNonce'");
      for (final id in removals) {
        final found = database.select(
          'SELECT id FROM documents WHERE lookup = ?',
          [await lookup('document', id)],
        );
        if (found.isEmpty) continue;
        final number = found.single['id'] as int;
        await detach(number, await docPage(number));
        database.execute('DELETE FROM documents WHERE id = ?', [number]);
      }
      for (final conversation in docs) {
        final hash = await lookup('document', conversation.id);
        final found = database.select(
          'SELECT id FROM documents WHERE lookup = ?',
          [hash],
        );
        final group = groupForSource(conversation.source);
        late int id;
        if (found.isEmpty) {
          var active = activePages[group.name];
          if (active == null || active[1] == postingPageSize) {
            active = [
              (nextDocument + postingPageSize - 1) ~/ postingPageSize,
              0,
            ];
            activePages[group.name] = active;
            // Reserve the whole range; 128-document metadata pages stay unchanged.
            nextDocument = (active[0] + 1) * postingPageSize;
          }
          id = active[0] * postingPageSize + active[1]++;
        } else {
          id = found.single['id'] as int;
        }
        changedIds.add(id);
        tagSourcePage(id ~/ docPageSize, group);
        final page = await docPage(id);
        await detach(id, page, replacement: conversation);
        final analyzed = ConversationSearchIndex.analyze(
          conversation,
          people,
          relations,
        );
        final frequency = <int>[];
        for (final term in analyzed.termFrequency.entries) {
          var termId = _termIds.remove(term.key);
          if (termId == null) {
            final hash = await lookup('term', term.key);
            final rows = database.select(
              'SELECT id FROM terms WHERE lookup = ?',
              [hash],
            );
            if (rows.isEmpty) {
              termId = nextTerm++;
              database.execute('INSERT INTO terms VALUES (?, ?, 0)', [
                termId,
                hash,
              ]);
              final number = termId ~/ vocabPageSize;
              final words = vocabPages[number] ??= await readPage(
                'vocabulary',
                number,
                vocabPageSize,
              );
              words[termId % vocabPageSize] = term.key;
            } else {
              termId = rows.single['id'] as int;
            }
          }
          _termIds[term.key] = termId;
          if (_termIds.length > cacheSize) _termIds.remove(_termIds.keys.first);
          frequency.addAll([termId, term.value]);
          await posting(termId, id, true);
        }
        page[id % docPageSize] = {
          'h': analyzed.haystack,
          't': analyzed.titleTokens.toList(),
          'p': analyzed.personTokens.toList(),
          'f': frequency,
          'l': analyzed.length,
        };
        final body = bodyPages[id ~/ docPageSize] ??= await readPage(
          'bodypages',
          id ~/ docPageSize,
          docPageSize,
        );
        body[id % docPageSize] = conversation.toJson();
        final summary = summaryPages[id ~/ docPageSize] ??= await readPage(
          'summarypages',
          id ~/ docPageSize,
          docPageSize,
        );
        summary[id % docPageSize] = conversation.toSummaryJson(
          previewLength: 180,
        );
        await filterWrites.change(id, summary[id % docPageSize] as Map, true);
        database.execute('INSERT OR REPLACE INTO documents VALUES (?, ?)', [
          id,
          hash,
        ]);
        documentCount++;
        totalLength += analyzed.length;
        if (recent != null) includeRecent(recent!, id, conversation);
      }
      for (final entry in deltas.entries) {
        database.execute('UPDATE terms SET df = df + ? WHERE id = ?', [
          entry.value,
          entry.key,
        ]);
      }
      for (final entry in vocabPages.entries) {
        await writePage('vocabulary', entry.key, entry.value);
        await routeVocabulary(entry.key, entry.value);
      }
      if (previous.$4 == 0) await writeMetadata('_lexiconRoutes', 1);
      await ranking.update(
        docPages,
        summaryPages,
        postingPages,
        positionPages,
        fieldPages,
      );
      await ranking.writeTiles(summaryPages, changedIds);
      for (final entry in postingPages.entries) {
        if (entry.value
            .take(_DiskRanking.bitmapBytes)
            .every((byte) => byte == 0)) {
          database.execute('DELETE FROM postings WHERE term = ? AND page = ?', [
            entry.key.$1,
            entry.key.$2,
          ]);
        } else {
          database.execute('INSERT OR REPLACE INTO postings VALUES (?, ?, ?)', [
            entry.key.$1,
            entry.key.$2,
            await sealBytes(
              ranking.packPosting(
                entry.value,
                positionPages[entry.key]!,
                fieldPages[entry.key]!,
              ),
            ),
          ]);
        }
      }
      for (final entry in docPages.entries) {
        await writePage('docpages', entry.key, entry.value);
      }
      for (final entry in bodyPages.entries) {
        await writePage('bodypages', entry.key, entry.value);
      }
      for (final entry in summaryPages.entries) {
        await writePage('summarypages', entry.key, entry.value);
      }
      await filterWrites.flush();
      await writeMetadata('_sourceActivePostingPagesV2', activePages);
      if (empty) {
        await filters.complete();
        await writeMetadata('_rankingVersion', _DiskRanking.version);
        await writeMetadata('_sourcePartitions', sourcePartitionVersion);
        database.execute(
          "DELETE FROM metadata WHERE key = '_sourcePartitionCursor'",
        );
      }
      if (recent == null) {
        database.execute("DELETE FROM metadata WHERE key = '_recentFrontier'");
      } else {
        await writeRecent(recent!);
      }
      await writeMetadata('_state', [
        documentCount,
        totalLength,
        nextDocument,
        nextTerm,
      ]);
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      documentCount = previous.$1;
      totalLength = previous.$2;
      nextDocument = previous.$3;
      nextTerm = previous.$4;
      _termIds.clear();
      ranking.invalidate();
      filters.invalidate();
      rethrow;
    }
  }

  Future<List<Conversation>> summaries(
    int offset,
    int limit,
    String? afterId,
  ) async {
    late sql.ResultSet ids;
    if (afterId == null) {
      ids = database.select(
        'SELECT id FROM documents ORDER BY id LIMIT ? OFFSET ?',
        [limit, math.max(0, offset)],
      );
    } else {
      final cursor = database.select(
        'SELECT id FROM documents WHERE lookup = ?',
        [await lookup('document', afterId)],
      );
      if (cursor.isEmpty) throw StateError('Summary cursor no longer exists.');
      ids = database.select(
        'SELECT id FROM documents WHERE id > ? ORDER BY id LIMIT ?',
        [cursor.single['id'], limit],
      );
    }
    final result = <Conversation>[];
    var loadedPage = -1;
    List<dynamic> values = const [];
    for (final row in ids) {
      final id = row['id'] as int;
      if (id ~/ docPageSize != loadedPage) {
        loadedPage = id ~/ docPageSize;
        values = await readPage('summarypages', loadedPage, docPageSize);
      }
      result.add(
        Conversation.fromSummaryJson(
          Map<String, dynamic>.from(values[id % docPageSize] as Map),
        ),
      );
    }
    return result;
  }

  Future<List<Conversation>> loadConversations(List<String> ids) async {
    final addresses = <int, List<(int, int)>>{};
    for (var n = 0; n < ids.length; n++) {
      final rows = database.select(
        'SELECT id FROM documents WHERE lookup = ?',
        [await lookup('document', ids[n])],
      );
      if (rows.isEmpty) throw StateError('Conversation no longer exists.');
      final id = rows.single['id'] as int;
      addresses.putIfAbsent(id ~/ docPageSize, () => []).add((
        n,
        id % docPageSize,
      ));
    }
    final result = List<Conversation?>.filled(ids.length, null);
    for (final entry in addresses.entries) {
      final page = await readPage('bodypages', entry.key, docPageSize);
      for (final address in entry.value) {
        result[address.$1] = Conversation.fromJson(
          Map<String, dynamic>.from(page[address.$2] as Map),
        );
      }
    }
    return result.cast<Conversation>();
  }

  static final digits = RegExp(r'^\d+$');
  static double quality(String query, String token) {
    if (digits.hasMatch(query)) return query == token ? 1 : 0;
    if (query == token) return 1;
    if (token.startsWith(query)) return .8;
    if (query.length >= 2 && token.contains(query)) return .6;
    if (query.length < 4) return 0;
    final limit = query.length >= 6 ? 2 : 1;
    final distance = StringDistance.levenshtein(query, token, limit);
    return distance <= limit ? (distance == 1 ? .5 : .3) : 0;
  }

  Future<List<Conversation>> search(
    SearchCriteria criteria,
    SearchScorer scorer,
    List<String> inputTokens,
    String normalized,
    int limit,
    int generation,
    List<_SearchScore> scores,
  ) async {
    _searchProfile.clear();
    _searchProfile['nativeAead'] = _nativeCipher == null ? 0 : 1;
    _searchProfile['workerIdentity'] = Isolate.current.controlPort.hashCode;
    _searchProfile['searchWorkers'] = 1;
    _searchProfile['configuredSearchWorkers'] = 1;
    _searchProfile['automaticSearchWorkers'] = 0;
    _searchProfile['phaseTimesAreWorkSums'] = 0;
    _searchProfile['postingPayloadCacheTotalLimitBytes'] = 16 * 1024 * 1024;
    final clock = Stopwatch()..start();
    if (generation != searchGeneration || documentCount == 0) return [];
    final tokens = inputTokens.toSet().toList();
    Set<int>? sourcePages;
    final sourceFilter = criteria.normalizedSource;
    if (sourceFilter != null || !criteria.includeConsumed) {
      if (!await ensureSourcePartitions(generation)) return [];
      final selected = sourceFilter == null
          ? null
          : groupFromSourceFilter(sourceFilter) ?? groupForSource(sourceFilter);
      final groups = [
        for (final group in SearchSourceGroup.values)
          if ((selected == null || group == selected) &&
              (criteria.includeConsumed || group != SearchSourceGroup.consumed))
            group,
      ];
      if (groups.isEmpty) return [];
      final placeholders = List.filled(groups.length, '?').join(',');
      sourcePages = database
          .select(
            'SELECT DISTINCT page FROM page_groups '
            'WHERE group_key IN ($placeholders) ORDER BY page',
            [for (final group in groups) _groupKeys[group]],
          )
          .map((row) => row['page'] as int)
          .toSet();
      if (sourcePages.isEmpty) return [];
    }
    Set<int>? recentIds;
    // Within a category freshness is monotonic; recency/ID breaks its ties.
    // Each category's first 100 therefore covers the global first 100.
    if (_usesRecent(criteria, scorer, tokens)) {
      final recent = await ensureRecent(generation);
      if (recent == null) return [];
      recentIds = {
        for (final group in recent)
          for (final item in group) item.ordinal,
      };
    }
    if (recentIds == null && !await ranking.ensure(generation)) return [];
    _searchProfile['prepareMs'] = clock.elapsedMilliseconds;
    clock.reset();
    final rankingQuery = _RankingQuery(
      this,
      criteria,
      scorer,
      tokens,
      normalized,
    );
    Uint8List? candidates = await filters.candidates(criteria, generation);
    if (rangeEnd != null) {
      final owned = Uint8List((nextDocument + 7) ~/ 8);
      owned.fillRange(rangeStart >> 3, (rangeLimit + 7) >> 3, 255);
      if ((rangeLimit & 7) != 0) owned.last &= (1 << (rangeLimit & 7)) - 1;
      if (candidates == null) {
        candidates = owned;
      } else {
        for (var i = 0; i < owned.length; i++) {
          candidates[i] &= owned[i];
        }
      }
    }
    if (generation != searchGeneration ||
        (candidates != null && candidates.every((byte) => byte == 0))) {
      return [];
    }
    final expansions = <({int cost, List<(int, String)> terms})>[];
    for (final token in tokens) {
      final terms = <(int, String)>[];
      var cost = 0;
      if (digits.hasMatch(token)) {
        final rows = database.select(
          'SELECT id, df FROM terms WHERE lookup = ? AND df > 0',
          [await lookup('term', token)],
        );
        for (final row in rows) {
          terms.add((row['id'] as int, token));
          cost += row['df'] as int;
        }
      } else {
        if (!await ensureLexiconRoutes(generation)) return [];
        for (final page in await lexiconPages(token)) {
          if ((page & 7) == 0) await Future<void>.delayed(Duration.zero);
          if (generation != searchGeneration) return [];
          final words = await readPage('vocabulary', page, vocabPageSize);
          final rows = database.select(
            'SELECT id, df FROM terms WHERE id >= ? AND id < ? AND df > 0',
            [page * vocabPageSize, (page + 1) * vocabPageSize],
          );
          for (final row in rows) {
            final id = row['id'] as int;
            final word = words[id % vocabPageSize] as String;
            if (quality(token, word) > 0) {
              terms.add((id, word));
              cost += row['df'] as int;
            }
          }
        }
      }
      if (terms.isEmpty || generation != searchGeneration) return [];
      expansions.add((cost: cost, terms: terms));
    }
    // AND is commutative; ranking and phrase order retain the original tokens.
    expansions.sort((a, b) => a.cost.compareTo(b.cost));
    var postingReads = 0;
    Future<void> addPostings(
      int term,
      String word,
      Uint8List bits,
      List<int>? allowedPages,
    ) async {
      final impact = rankingQuery.term(term, word);
      var after = -1;
      var offset = 0;
      while (true) {
        if ((postingReads++ & 31) == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        if (generation != searchGeneration) return;
        late sql.ResultSet rows;
        if (allowedPages == null) {
          rows = database.select(
            'SELECT page, payload FROM postings WHERE term = ? AND page > ? ORDER BY page LIMIT 32',
            [term, after],
          );
          if (rows.isEmpty) break;
        } else {
          if (offset == allowedPages.length) break;
          final part = allowedPages.sublist(
            offset,
            math.min(offset + 32, allowedPages.length),
          );
          offset += part.length;
          final marks = List.filled(part.length, '?').join(',');
          rows = database.select(
            'SELECT page, payload FROM postings WHERE term = ? AND page IN ($marks) ORDER BY page',
            [term, ...part],
          );
        }
        final native = _nativeCipher;
        var rowOffset = 0;
        while (rowOffset < rows.length) {
          final batch = <(int, Uint8List?)>[];
          final encrypted = <Uint8List>[];
          var bytes = 0;
          while (rowOffset < rows.length && batch.length < 512) {
            final row = rows[rowOffset];
            final number = row['page'] as int;
            if (sourcePages != null &&
                !Iterable<int>.generate(
                  postingPageSize ~/ docPageSize,
                  (n) => number * (postingPageSize ~/ docPageSize) + n,
                ).any(sourcePages.contains)) {
              after = number;
              rowOffset++;
              continue;
            }
            final packed = row['payload'] as Uint8List;
            if (batch.isNotEmpty && bytes + packed.length > 4 * 1024 * 1024) {
              break;
            }
            after = number;
            rowOffset++;
            var cached = rankingQuery.cachedPosting(term, number);
            if (cached == null &&
                (native == null || packed.length > 4 * 1024 * 1024)) {
              cached = await unsealBytes(packed);
            }
            batch.add((number, cached));
            if (cached == null) encrypted.add(packed);
            bytes += packed.length;
            if (bytes > 4 * 1024 * 1024) break;
          }
          final decoded = encrypted.isEmpty
              ? const <Uint8List>[]
              : native!.decryptMany(encrypted);
          if (encrypted.isNotEmpty) {
            _searchProfile.update(
              'postingBatchCalls',
              (n) => n + 1,
              ifAbsent: () => 1,
            );
            _searchProfile.update(
              'postingBatchPayloads',
              (n) => n + encrypted.length,
              ifAbsent: () => encrypted.length,
            );
            _searchProfile['postingBatchPeakPackedBytes'] = math.max(
              _searchProfile['postingBatchPeakPackedBytes'] ?? 0,
              encrypted.fold<int>(0, (n, p) => n + p.length),
            );
          }
          var decodedOffset = 0;
          for (final (number, cached) in batch) {
            _searchProfile.update(
              'postingReads',
              (n) => n + 1,
              ifAbsent: () => 1,
            );
            final page = cached ?? decoded[decodedOffset++];
            rankingQuery.cachePosting(term, number, page);
            if (impact != null) {
              await rankingQuery.posting(number, page, impact);
            }
            final start = number * (postingPageSize ~/ 8);
            for (
              var n = 0;
              n < _DiskRanking.bitmapBytes && start + n < bits.length;
              n++
            ) {
              bits[start + n] |= page[n];
            }
          }
        }
      }
    }

    for (final expansion in expansions) {
      final bits = Uint8List((nextDocument + 7) ~/ 8);
      final allowedPages = candidates == null
          ? null
          : (<int>{
              for (var byte = 0; byte < candidates.length; byte++)
                if (candidates[byte] != 0) byte ~/ _DiskRanking.bitmapBytes,
            }.toList()..sort());
      for (final (term, word) in expansion.terms) {
        await addPostings(term, word, bits, allowedPages);
        if (generation != searchGeneration) return [];
      }
      if (generation != searchGeneration) return [];
      if (candidates == null) {
        candidates = bits;
      } else {
        for (var n = 0; n < bits.length; n++) {
          candidates[n] &= bits[n];
        }
      }
      if (candidates.every((byte) => byte == 0)) return [];
    }
    _searchProfile['candidateMs'] = clock.elapsedMilliseconds;
    clock.reset();
    final top = <(Conversation, double)>[];
    int compare((Conversation, double) a, (Conversation, double) b) {
      final score = b.$2.compareTo(a.$2);
      if (score != 0) return score;
      final date = b.$1.startedAt.compareTo(a.$1.startedAt);
      return date != 0 ? date : a.$1.id.compareTo(b.$1.id);
    }

    final from = criteria.normalizedFrom;
    final to = criteria.normalizedTo;
    final pages = recentIds != null
        ? ({for (final id in recentIds) id ~/ docPageSize}.toList()..sort())
        : sourcePages != null
        ? (sourcePages.toList()..sort())
        : Iterable<int>.generate(
            (nextDocument + docPageSize - 1) ~/ docPageSize,
          );
    final ownedPages = rangeEnd == null
        ? pages
        : pages.where(
            (page) =>
                page * docPageSize < rangeLimit &&
                (page + 1) * docPageSize > rangeStart,
          );
    final orderedPages = recentIds == null
        ? await rankingQuery.order(ownedPages)
        : [for (final page in ownedPages) (page: page, bound: double.infinity)];
    _searchProfile['boundMs'] = clock.elapsedMilliseconds;
    _searchProfile['candidateBlocks'] = orderedPages.length;
    clock.reset();
    if (tokens.isNotEmpty && candidates != null) {
      return rankingQuery.rankDocuments(
        candidates,
        orderedPages,
        limit,
        generation,
        scores,
      );
    }
    var scoredPages = 0;
    var scoredDocuments = 0;
    for (final item in orderedPages) {
      if (top.length == limit && item.bound < top.last.$2) break;
      final page = item.page;
      if ((scoredPages++ & 7) == 0) await Future<void>.delayed(Duration.zero);
      if (generation != searchGeneration) return [];
      final start = page * docPageSize;
      if (candidates != null &&
          !Uint8List.sublistView(
            candidates,
            start >> 3,
            math.min((start + docPageSize) >> 3, candidates.length),
          ).any((byte) => byte != 0)) {
        continue;
      }
      final summaries = await readPage('summarypages', page, docPageSize);
      for (var n = 0; n < summaries.length; n++) {
        final id = start + n;
        if (recentIds != null && !recentIds.contains(id)) continue;
        if (candidates != null &&
            (id >= nextDocument ||
                (candidates[id >> 3] & (1 << (id & 7))) == 0)) {
          continue;
        }
        final summary = summaries[n] as Map?;
        if (summary == null) continue;
        final conversation = Conversation.fromSummaryJson(
          Map<String, dynamic>.from(summary),
        );
        final category = categoryForSource(conversation.source);
        final tags = conversation.tags.map((tag) => tag.toLowerCase()).toSet();
        if (!criteria.matchesLocation(conversation.location) ||
            !criteria.matchesSource(conversation.source) ||
            (criteria.normalizedParticipantId != null &&
                !conversation.participantIds.contains(
                  criteria.normalizedParticipantId,
                )) ||
            (criteria.normalizedTag != null &&
                !tags.contains(criteria.normalizedTag)) ||
            (criteria.favoritesOnly && !conversation.isFavorite) ||
            (!criteria.includeConsumed &&
                category == SourceCategory.consumed)) {
          continue;
        }
        final a = conversation.startedAt.toUtc();
        final b = conversation.endedAt.toUtc();
        final spanStart = a.isBefore(b) ? a : b;
        final spanEnd = a.isAfter(b) ? a : b;
        if ((from != null && spanEnd.isBefore(from)) ||
            (to != null && spanStart.isAfter(to))) {
          continue;
        }
        scoredDocuments++;
        var score = 0.0;
        score += scorer.score(
          documentTime: conversation.startedAt.toUtc(),
          conversationId: conversation.id,
          useVector: !criteria.isEmptyQuery && criteria.useVector,
        );
        score *= categoryWeight(category);
        final item = (conversation, score);
        if (top.length == limit && compare(item, top.last) >= 0) continue;
        var low = 0;
        var high = top.length;
        while (low < high) {
          final mid = (low + high) >> 1;
          if (compare(item, top[mid]) < 0) {
            high = mid;
          } else {
            low = mid + 1;
          }
        }
        top.insert(low, item);
        if (top.length > limit) top.removeLast();
      }
    }
    _searchProfile['scoreMs'] = clock.elapsedMilliseconds;
    _searchProfile['scoredBlocks'] = scoredPages;
    _searchProfile['scoredDocuments'] = scoredDocuments;
    scores.addAll([
      for (final item in top)
        (
          score: item.$2,
          time: item.$1.startedAt.microsecondsSinceEpoch,
          id: item.$1.id,
        ),
    ]);
    return [for (final item in top) item.$1];
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _nativeCipher?.dispose();
    } finally {
      key.destroy();
      database.close();
    }
  }
}
