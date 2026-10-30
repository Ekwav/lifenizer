part of 'disk_search_index_io.dart';

/// Encrypted block extrema and score tiles support exact bounded ranking.
class _DiskRanking {
  _DiskRanking(this.store);
  final _DiskStore store;
  static const version = 6;
  static const postingFormat = 5;
  // Length, TF norm, start/end microseconds, and category weight.
  static const numericBytes = 40;
  static const numericPageBytes = numericBytes * _DiskStore.postingPageSize;
  static const numericCachePages = (96 * 1024 * 1024) ~/ numericPageBytes;
  static const tileSize = 8;
  static const tilesPerPage = _DiskStore.docPageSize ~/ tileSize;
  static const bitmapBytes = _DiskStore.postingPageSize ~/ 8;
  static const impactBytes = 5;
  static const postingBytes = bitmapBytes + 8 * impactBytes;
  // Seven doubles: minimum length, start-time extrema, span extrema, maximum
  // category weight, and minimum TF norm; then live count and reserved uint32.
  static const recordBytes = 64;
  static const recordsPerPage = 128;
  final _cache = <int, Uint8List>{};
  final _numericCache = <int, Uint8List>{};
  bool _numericReady = false;
  bool? _ready;
  bool _writing = false;

  void initialize() {
    store.database.execute(
      'CREATE TABLE IF NOT EXISTS rankdocuments '
      '(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)',
    );
    store.database.execute(
      'CREATE TABLE IF NOT EXISTS scoretiles '
      '(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)',
    );
    store.database.execute(
      'CREATE TABLE IF NOT EXISTS rankingpages '
      '(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)',
    );
  }

  void invalidate() {
    _cache.clear();
    _numericCache.clear();
    _numericReady = false;
    _ready = null;
    _writing = false;
  }

  Future<Uint8List> _page(int number) async {
    final cached = _cache.remove(number);
    if (cached != null) {
      _cache[number] = cached;
      return cached;
    }
    final rows = store.database.select(
      'SELECT payload FROM rankingpages WHERE id = ?',
      [number],
    );
    final data = rows.isEmpty
        ? Uint8List(recordBytes * recordsPerPage)
        : await store.unsealBytes(rows.single['payload'] as List<int>);
    _cache[number] = data;
    if (!_writing && _cache.length > 256) _cache.remove(_cache.keys.first);
    return data;
  }

  Future<Uint8List> numericPage(int page, {bool create = false}) async {
    final cached = _numericCache.remove(page);
    if (cached != null) {
      _numericCache[page] = cached;
      return cached;
    }
    final rows = store.database.select(
      'SELECT payload FROM rankdocuments WHERE id = ?',
      [page],
    );
    if (rows.isEmpty && !create) {
      throw StateError('Incomplete numeric search metadata.');
    }
    final bytes = rows.isEmpty
        ? Uint8List(numericPageBytes)
        : await store.unsealBytes(rows.single['payload'] as List<int>);
    if (bytes.length != numericPageBytes) {
      throw StateError('Invalid numeric search metadata.');
    }
    _numericCache[page] = bytes;
    if (!_writing && _numericCache.length > numericCachePages) {
      _numericCache.remove(_numericCache.keys.first);
    }
    return bytes;
  }

  Future<bool> warmNumeric(int? generation) async {
    if (_numericReady) return true;
    for (
      var page = store.rangeStart ~/ _DiskStore.postingPageSize;
      page * _DiskStore.postingPageSize < store.rangeLimit;
      page++
    ) {
      if ((page & 7) == 0) await Future<void>.delayed(Duration.zero);
      if (generation != null && generation != store.searchGeneration) {
        return false;
      }
      await numericPage(page);
    }
    _numericReady = true;
    return generation == null || generation == store.searchGeneration;
  }

  ByteData? cachedRecord(int block) {
    final number = block ~/ recordsPerPage;
    final data = _cache.remove(number);
    if (data == null) return null;
    _cache[number] = data;
    return ByteData.sublistView(
      data,
      (block % recordsPerPage) * recordBytes,
      (block % recordsPerPage + 1) * recordBytes,
    );
  }

  Future<ByteData> record(int block) async => ByteData.sublistView(
    await _page(block ~/ recordsPerPage),
    (block % recordsPerPage) * recordBytes,
    (block % recordsPerPage + 1) * recordBytes,
  );

  static double documentNorm(Map data) {
    if (data['n'] case final num norm) return norm.toDouble();
    final frequency = data['f'] as List;
    var sum = 0.0;
    for (var n = 1; n < frequency.length; n += 2) {
      final weight = 1 + math.log(frequency[n] as int);
      sum += weight * weight;
    }
    final norm = math.sqrt(sum);
    data['n'] = norm;
    return norm;
  }

  Future<void> writeTiles(
    Map<int, List<dynamic>> summaries, [
    Set<int>? changedIds,
  ]) async {
    final Iterable<int> tiles = changedIds == null
        ? [
            for (final block in summaries.keys)
              for (var n = 0; n < tilesPerPage; n++) block * tilesPerPage + n,
          ]
        : {for (final id in changedIds) id ~/ tileSize};
    for (final tile in tiles) {
      final block = tile ~/ tilesPerPage;
      final offset = (tile % tilesPerPage) * tileSize;
      await store.writePage('scoretiles', tile, [
        for (var n = offset; n < offset + tileSize; n++) summaries[block]![n],
      ]);
    }
  }

  static bool hasFieldBoosts(Uint8List payload) =>
      payload.length > postingBytes && payload[postingBytes] == postingFormat;

  static final NativePostingInflate? _queryInflater =
      NativePostingInflate.tryCreate();

  static Uint8List postingData(Uint8List payload, {bool queryNative = false}) {
    final compressed = Uint8List.sublistView(
      payload,
      postingBytes + (hasFieldBoosts(payload) ? 1 : 0),
    );
    if (queryNative) {
      final decoded = _queryInflater?.decode(compressed);
      if (decoded != null) return decoded;
    }
    return _managedDecode(compressed);
  }

  ({Map<int, List<int>> positions, Map<int, int> boosts}) decodePosting(
    Uint8List payload,
  ) {
    final boosts = <int, int>{};
    final positions = payload.length <= postingBytes
        ? <int, List<int>>{}
        : decodePostingPositions(
            Uint8List.sublistView(payload, 0, bitmapBytes),
            postingData(payload),
            hasFieldBoosts: hasFieldBoosts(payload),
            fieldBoosts: boosts,
          );
    return (positions: positions, boosts: boosts);
  }

  Uint8List packPosting(
    Uint8List payload,
    Map<int, List<int>> positions,
    Map<int, int> boosts,
  ) {
    final compressed = _managedEncode(
      encodePostingPositions(
        Uint8List.sublistView(payload, 0, bitmapBytes),
        positions,
        fieldBoosts: boosts,
      ),
    );
    return Uint8List(postingBytes + 1 + compressed.length)
      ..setRange(0, postingBytes, payload)
      ..[postingBytes] = postingFormat
      ..setRange(
        postingBytes + 1,
        postingBytes + 1 + compressed.length,
        compressed,
      );
  }

  Future<void> update(
    Map<int, List<dynamic>> documents,
    Map<int, List<dynamic>> summaries,
    Map<(int, int), Uint8List> postings,
    Map<(int, int), Map<int, List<int>>> positionPages,
    Map<(int, int), Map<int, int>> fieldPages,
  ) async {
    _writing = true;
    final vocabulary = <int, List<dynamic>>{};
    final dirty = <int>{};
    final numericDirty = <int>{};
    for (final entry in documents.entries) {
      final block = entry.key;
      final values = await record(block);
      final numericBytes = await numericPage(block ~/ 8, create: true);
      final numeric = ByteData.sublistView(numericBytes);
      numericDirty.add(block ~/ 8);
      dirty.add(block ~/ recordsPerPage);
      var count = 0;
      var minimumLength = double.infinity;
      var earliest = double.infinity;
      var latest = -double.infinity;
      var firstSpan = double.infinity;
      var lastSpan = -double.infinity;
      var category = 0.0;
      var minimumNorm = double.infinity;
      for (var n = 0; n < entry.value.length; n++) {
        final offset =
            ((block % 8) * _DiskStore.docPageSize + n) *
            _DiskRanking.numericBytes;
        numericBytes.fillRange(offset, offset + _DiskRanking.numericBytes, 0);
        final data = entry.value[n] as Map?;
        final summary = summaries[block]![n] as Map?;
        if (data == null || summary == null) continue;
        final conversation = Conversation.fromSummaryJson(
          Map<String, dynamic>.from(summary),
        );
        count++;
        minimumLength = math.min(minimumLength, (data['l'] as int).toDouble());
        final time = conversation.startedAt.microsecondsSinceEpoch.toDouble();
        final end = conversation.endedAt.microsecondsSinceEpoch.toDouble();
        earliest = math.min(earliest, time);
        latest = math.max(latest, time);
        firstSpan = math.min(firstSpan, math.min(time, end));
        lastSpan = math.max(lastSpan, math.max(time, end));
        category = math.max(category, weightForSource(conversation.source));
        final frequency = data['f'] as List;
        final norm = documentNorm(data);
        if (frequency.isNotEmpty) minimumNorm = math.min(minimumNorm, norm);
        numeric.setFloat64(offset, (data['l'] as int).toDouble());
        numeric.setFloat64(offset + 8, norm);
        numeric.setFloat64(offset + 16, time);
        numeric.setFloat64(offset + 24, end);
        numeric.setFloat64(offset + 32, weightForSource(conversation.source));
        final title = (data['t'] as List).cast<String>().toSet();
        final people = (data['p'] as List).cast<String>().toSet();
        final tags = conversation.tags.map((tag) => tag.toLowerCase()).toSet();
        final location = conversation.location;
        final town = ConversationSearchIndex.tokenize(
          location?.town ?? '',
        ).toSet();
        final place = ConversationSearchIndex.tokenize(
          location == null ? '' : '${location.venue} ${location.address}',
        ).toSet();
        final occurrences = <String, List<int>>{};
        final wordsInOrder = (data['h'] as String).split(' ');
        for (var position = 0; position < wordsInOrder.length; position++) {
          occurrences
              .putIfAbsent(wordsInOrder[position], () => [])
              .add(position);
        }
        for (var f = 0; f < frequency.length; f += 2) {
          final term = frequency[f] as int;
          final tf = frequency[f + 1] as int;
          final wordPage = term ~/ _DiskStore.vocabPageSize;
          final words = vocabulary[wordPage] ??= await store.readPage(
            'vocabulary',
            wordPage,
            _DiskStore.vocabPageSize,
          );
          final word = words[term % _DiskStore.vocabPageSize] as String;
          final boost =
              (title.contains(word) ? 4 : 0) +
              (people.contains(word) ? 5 : 0) +
              (tags.contains(word) ? 2 : 0) +
              (town.contains(word) ? 5 : 0) +
              (place.contains(word) ? 2 : 0);
          final address = (term, block ~/ 8);
          var packed = postings[address];
          if (packed == null) {
            final row = store.database.select(
              'SELECT payload FROM postings WHERE term = ? AND page = ?',
              [address.$1, address.$2],
            );
            if (row.isEmpty) continue;
            packed = await store.unsealBytes(
              row.single['payload'] as List<int>,
            );
          }
          if (!positionPages.containsKey(address)) {
            final decoded = decodePosting(packed);
            positionPages[address] = decoded.positions;
            fieldPages[address] = decoded.boosts;
          }
          final doc = (block % 8) * _DiskStore.docPageSize + n;
          positionPages[address]![doc] = occurrences[word]!;
          fieldPages[address]![doc] = boost;
          if (packed.length < postingBytes) {
            packed = Uint8List(postingBytes)
              ..setRange(0, packed.length, packed);
          }
          postings[address] = packed;
          final impact = ByteData.sublistView(packed);
          final offset = bitmapBytes + (block % 8) * impactBytes;
          impact.setUint32(offset, math.max(tf, impact.getUint32(offset)));
          impact.setUint8(
            offset + 4,
            math.max(boost, impact.getUint8(offset + 4)),
          );
        }
      }
      for (final (offset, value) in [
        (0, minimumLength),
        (8, earliest),
        (16, latest),
        (24, firstSpan),
        (32, lastSpan),
        (40, category),
        (48, minimumNorm.isFinite ? minimumNorm : 0.0),
      ]) {
        values.setFloat64(offset, value);
      }
      values.setUint32(56, count);
      values.setUint32(60, 0);
    }
    for (final page in dirty) {
      store.database.execute(
        'INSERT OR REPLACE INTO rankingpages VALUES (?, ?)',
        [page, await store.sealBytes(await _page(page))],
      );
    }
    for (final page in numericDirty) {
      store.database.execute(
        'INSERT OR REPLACE INTO rankdocuments VALUES (?, ?)',
        [page, await store.sealBytes(await numericPage(page))],
      );
    }
    _writing = false;
    while (_numericCache.length > numericCachePages) {
      _numericCache.remove(_numericCache.keys.first);
    }
    while (_cache.length > 256) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<bool> ensure(int? generation, {bool warmNumericCache = true}) async {
    if (_ready == true) {
      return !warmNumericCache || await warmNumeric(generation);
    }
    final previousVersion = await store.readMetadata('_rankingVersion');
    _ready = previousVersion == version;
    if (_ready!) return !warmNumericCache || await warmNumeric(generation);
    final migration = await store.readMetadata('_rankingMigrationVersion');
    var block = migration == version
        ? (await store.readMetadata('_rankingCursor') as int?) ?? 0
        : 0;
    final count =
        (store.nextDocument + _DiskStore.docPageSize - 1) ~/
        _DiskStore.docPageSize;
    while (block < count) {
      await Future<void>.delayed(Duration.zero);
      if (generation != null && generation != store.searchGeneration) {
        return false;
      }
      final documents = <int, List<dynamic>>{};
      final summaries = <int, List<dynamic>>{};
      final postings = <(int, int), Uint8List>{};
      final positions = <(int, int), Map<int, List<int>>>{};
      final fields = <(int, int), Map<int, int>>{};
      store.database.execute('BEGIN IMMEDIATE');
      try {
        final end = math.min((block ~/ 8 + 1) * 8, count);
        while (block < end) {
          documents[block] = await store.readPage(
            'docpages',
            block,
            _DiskStore.docPageSize,
          );
          summaries[block] = await store.readPage(
            'summarypages',
            block,
            _DiskStore.docPageSize,
          );
          block++;
        }
        await update(documents, summaries, postings, positions, fields);
        for (final entry in postings.entries) {
          store.database
              .execute('INSERT OR REPLACE INTO postings VALUES (?, ?, ?)', [
                entry.key.$1,
                entry.key.$2,
                await store.sealBytes(
                  packPosting(
                    entry.value,
                    positions[entry.key]!,
                    fields[entry.key]!,
                  ),
                ),
              ]);
        }
        await writeTiles(summaries);
        await store.writeMetadata('_rankingCursor', block);
        await store.writeMetadata('_rankingMigrationVersion', version);
        store.database.execute('COMMIT');
      } catch (_) {
        store.database.execute('ROLLBACK');
        invalidate();
        rethrow;
      }
    }
    store.database.execute('BEGIN IMMEDIATE');
    try {
      await store.writeMetadata('_rankingVersion', version);
      store.database.execute('DROP TABLE IF EXISTS ranking_witnesses');
      store.database.execute('DROP INDEX IF EXISTS terms_df');
      store.database.execute(
        "DELETE FROM metadata WHERE key IN ('_rankingCursor', '_rankingMigrationVersion')",
      );
      store.database.execute('COMMIT');
    } catch (_) {
      store.database.execute('ROLLBACK');
      invalidate();
      rethrow;
    }
    _ready = true;
    return !warmNumericCache || await warmNumeric(generation);
  }
}

class _NumericResult {
  _NumericResult(this.ordinal, this.score, this.time);
  final int ordinal;
  final double score;
  final int time;
  String? id;
}

class _RankingQuery {
  _RankingQuery(
    this.store,
    this.criteria,
    this.scorer,
    this.tokens,
    this.normalized,
  );
  final _DiskStore store;
  final SearchCriteria criteria;
  final SearchScorer scorer;
  final List<String> tokens;
  final String normalized;
  // Query-local authenticated payloads; compressed tails stay compressed.
  static const _payloadLimit = 16 * 1024 * 1024;
  static const _entryLimit = 65536;
  final _payloads = <(int, int), Uint8List>{};
  var _payloadBytes = 0;
  var _payloadPeak = 0;
  var _payloadHits = 0;
  Uint8List? cachedPosting(int term, int page) {
    final address = (term, page);
    final value = _payloads.remove(address);
    if (value != null) {
      _payloads[address] = value;
      _payloadHits++;
    }
    return value;
  }

  void cachePosting(int term, int page, Uint8List value) {
    final size = value.buffer.lengthInBytes;
    if (size > _payloadLimit) return;
    final address = (term, page);
    final previous = _payloads.remove(address);
    if (previous != null) _payloadBytes -= previous.buffer.lengthInBytes;
    _payloads[address] = value;
    _payloadBytes += size;
    while (_payloadBytes > _payloadLimit || _payloads.length > _entryLimit) {
      _payloadBytes -= _payloads
          .remove(_payloads.keys.first)!
          .buffer
          .lengthInBytes;
    }
    _payloadPeak = math.max(_payloadPeak, _payloadBytes);
  }

  final _seen = <int>{};
  final matchingTerms = <int, _Term>{};
  final _best = <int, List<double>>{};
  final _dot = <int, double>{};
  final _phraseMatches = <int, Uint8List>{};
  late final _phraseTokens = normalized.split(' ');
  late final _phraseKnown =
      normalized.isNotEmpty && _phraseTokens.every(tokens.contains);
  // Phrase scoring is substring-based. Some numeric/one-character boundary
  // matches are absent from lexical expansions, so they cannot rule it out.
  late final _phraseChecks = [
    if (_phraseKnown)
      for (var n = 0; n < _phraseTokens.length; n++)
        if (_phraseTokens.length == 1 ||
            ((n != 0 ||
                    (_phraseTokens[n].length >= 2 &&
                        !_DiskStore.digits.hasMatch(_phraseTokens[n]))) &&
                (n != _phraseTokens.length - 1 ||
                    !_DiskStore.digits.hasMatch(_phraseTokens[n]))))
          n,
  ];
  final _queryWeights = <String, double>{};
  late final queryNorm = tokens.fold(0.0, (sum, word) {
    final weight = _queryWeights[word] ?? 0;
    return sum + weight * weight;
  });

  _Term? term(int term, String word) {
    if (!_seen.add(term)) return null;
    final row = store.database.select('SELECT df FROM terms WHERE id = ?', [
      term,
    ]);
    final df = row.single['df'] as int;
    final idf = math.log(1 + (store.documentCount - df + .5) / (df + .5));
    final exact = tokens.contains(word);
    final quality = [
      for (final token in tokens) _DiskStore.quality(token, word),
    ];
    if (exact && df > 0) _queryWeights[word] = idf;
    final phrase = [
      for (final n in _phraseChecks)
        if (_phraseTokens.length == 1
            ? word.contains(_phraseTokens[n])
            : n == 0
            ? word.endsWith(_phraseTokens[n])
            : n == _phraseTokens.length - 1
            ? word.startsWith(_phraseTokens[n])
            : word == _phraseTokens[n])
          n,
    ];
    final info = _Term(word, idf, quality, exact, phrase);
    matchingTerms[term] = info;
    return info;
  }

  Future<void> posting(int page, Uint8List payload, _Term info) async {
    if (payload.length <= _DiskRanking.postingBytes) {
      throw StateError('Incomplete search ranking index.');
    }
    final impact = ByteData.sublistView(payload);
    final average = math.max(1.0, store.totalLength / store.documentCount);
    for (var n = 0; n < 8; n++) {
      final offset = _DiskRanking.bitmapBytes + n * _DiskRanking.impactBytes;
      final tf = impact.getUint32(offset);
      if (tf == 0) continue;
      final block = page * 8 + n;
      final metadata =
          store.ranking.cachedRecord(block) ??
          await store.ranking.record(block);
      if (metadata.getUint32(56) == 0) continue;
      final bm25 =
          info.idf *
          tf *
          2.2 /
          (tf + 1.2 * (.25 + .75 * metadata.getFloat64(0) / average));
      final value = 4 + math.log(1 + bm25) + impact.getUint8(offset + 4);
      final best = _best.putIfAbsent(
        block,
        () => List.filled(tokens.length, 0),
      );
      for (var t = 0; t < tokens.length; t++) {
        best[t] = math.max(best[t], info.matches[t] * value);
      }
      if (info.phrase.isNotEmpty) {
        final phrase = _phraseMatches.putIfAbsent(
          block,
          () => Uint8List(_phraseTokens.length),
        );
        for (final n in info.phrase) {
          phrase[n] = 1;
        }
      }
      if (info.exact && criteria.useVector) {
        _dot.update(
          block,
          (dot) => dot + info.idf * (1 + math.log(tf)),
          ifAbsent: () => info.idf * (1 + math.log(tf)),
        );
      }
    }
  }

  Future<List<({int page, double bound})>> order(Iterable<int> pages) async {
    final result = <({int page, double bound})>[];
    final from = criteria.normalizedFrom?.microsecondsSinceEpoch;
    final to = criteria.normalizedTo?.microsecondsSinceEpoch;
    for (final page in pages) {
      final metadata =
          store.ranking.cachedRecord(page) ?? await store.ranking.record(page);
      if (metadata.getUint32(56) == 0 ||
          (from != null && metadata.getFloat64(32) < from) ||
          (to != null && metadata.getFloat64(24) > to)) {
        continue;
      }
      final best = _best[page];
      if (tokens.isNotEmpty &&
          (best == null || best.any((value) => value == 0))) {
        continue;
      }
      var bound = best?.fold(0.0, (sum, value) => sum + value) ?? 0.0;
      if (!criteria.isEmptyQuery &&
          normalized.isNotEmpty &&
          (!_phraseKnown ||
              _phraseChecks.every((n) => _phraseMatches[page]?[n] == 1))) {
        bound += 4;
      }
      if (criteria.useVector && queryNorm > 0 && (_dot[page] ?? 0) > 0) {
        final norm = metadata.getFloat64(48);
        bound +=
            2.5 * math.min(1.0, _dot[page]! / (norm * math.sqrt(queryNorm)));
      }
      final latest = DateTime.fromMicrosecondsSinceEpoch(
        metadata.getFloat64(16).toInt(),
        isUtc: true,
      );
      final age = math.max(0.0, scorer.now.difference(latest).inHours / 24);
      final freshness = math.exp(-age / 180);
      if (scorer.normalizedQuery.isEmpty) {
        bound += 2 * freshness;
      } else {
        bound += freshness;
        final intent = scorer.temporalIntent;
        if (intent != null) {
          final earliest = DateTime.fromMicrosecondsSinceEpoch(
            metadata.getFloat64(8).toInt(),
            isUtc: true,
          );
          if (latest.isBefore(intent.targetStart)) {
            bound += intent.alignmentScore(latest);
          } else if (earliest.isAfter(intent.targetEnd)) {
            bound += intent.alignmentScore(earliest);
          } else {
            bound += math.max(
              .8,
              2 * intent.weight +
                  (intent.hourStart != null && intent.hourEnd != null
                      ? 1.4
                      : 0),
            );
          }
        }
        if (TemporalIntent.referencesPrevious(scorer.normalizedQuery) &&
            scorer.lastSearchTopIds.isNotEmpty) {
          bound += 1;
        }
      }
      bound *= metadata.getFloat64(40);
      result.add((page: page, bound: bound + 1e-10 * (1 + bound.abs())));
    }
    result.sort((a, b) => b.bound.compareTo(a.bound));
    return result;
  }

  Future<List<Conversation>> rankDocuments(
    Uint8List candidates,
    List<({int page, double bound})> blocks,
    int limit,
    int generation,
    List<_SearchScore> scores,
  ) async {
    final clock = Stopwatch()..start();
    final inflater = _DiskRanking._queryInflater;
    final nativeBefore = inflater?.successfulInflates ?? 0;
    store._searchProfile['nativePostingInflaterAvailable'] = inflater == null
        ? 0
        : 1;
    final top = <_NumericResult>[];
    final tiles = <int, List<dynamic>>{};
    Future<Map<String, dynamic>> summary(int ordinal) async {
      final tile = ordinal ~/ _DiskRanking.tileSize;
      final values =
          tiles.remove(tile) ??
          await store.readPage('scoretiles', tile, _DiskRanking.tileSize);
      tiles[tile] = values;
      if (tiles.length > 64) tiles.remove(tiles.keys.first);
      final value = values[ordinal % _DiskRanking.tileSize];
      if (value is! Map) throw StateError('Incomplete search result tile.');
      return Map<String, dynamic>.from(value);
    }

    // Only unsupported substring boundaries need original text. Ordinary
    // searches rank numerically and decode summaries for the final winners.
    final documents = <int, List<dynamic>>{};
    Future<bool> literalPhrase(int ordinal) async {
      final page = ordinal ~/ _DiskStore.docPageSize;
      final values =
          documents.remove(page) ??
          await store.readPage('docpages', page, _DiskStore.docPageSize);
      documents[page] = values;
      if (documents.length > 8) documents.remove(documents.keys.first);
      final value = values[ordinal % _DiskStore.docPageSize];
      if (value is! Map || value['h'] is! String) {
        throw StateError('Incomplete search phrase data.');
      }
      return (value['h'] as String).contains(normalized);
    }

    Future<String> identifier(_NumericResult item) async =>
        item.id ??= (await summary(item.ordinal))['id'] as String;
    int compareNumbers(double score, int time, _NumericResult other) {
      final order = other.score.compareTo(score);
      return order != 0 ? order : other.time.compareTo(time);
    }

    bool canEnter(double score, int time) =>
        top.length < limit || compareNumbers(score, time, top.last) <= 0;
    Future<void> insert(int ordinal, double score, int time) async {
      if (!canEnter(score, time)) return;
      final item = _NumericResult(ordinal, score, time);
      var low = 0;
      var high = top.length;
      while (low < high) {
        final mid = (low + high) >> 1;
        var order = compareNumbers(score, time, top[mid]);
        if (order == 0) {
          order = (await identifier(
            item,
          )).compareTo(await identifier(top[mid]));
        }
        if (order < 0) {
          high = mid;
        } else {
          low = mid + 1;
        }
      }
      top.insert(low, item);
      if (top.length > limit) top.removeLast();
    }

    final previous = <int>{};
    if (TemporalIntent.referencesPrevious(scorer.normalizedQuery)) {
      for (final id in scorer.lastSearchTopIds) {
        final rows = store.database.select(
          'SELECT id FROM documents WHERE lookup = ?',
          [await store.lookup('document', id)],
        );
        if (rows.isNotEmpty) previous.add(rows.single['id'] as int);
      }
    }
    final from = criteria.normalizedFrom?.microsecondsSinceEpoch;
    final to = criteria.normalizedTo?.microsecondsSinceEpoch;
    final average = math.max(1.0, store.totalLength / store.documentCount);
    final queryLength = math.sqrt(queryNorm);
    final coveredPhrase =
        _phraseKnown && _phraseChecks.length == _phraseTokens.length;
    final positionsNeeded = coveredPhrase && _phraseTokens.length > 1;
    final phraseFallback = normalized.isNotEmpty && !coveredPhrase;
    final locationCheck = criteria.locationLabels.isNotEmpty;
    final terms = matchingTerms.keys.toList();
    final blockBounds = Float64List(
      (store.nextDocument + _DiskStore.docPageSize - 1) ~/
          _DiskStore.docPageSize,
    );
    blockBounds.fillRange(0, blockBounds.length, double.negativeInfinity);
    for (final block in blocks) {
      blockBounds[block.page] = block.bound;
    }
    final eligible = Uint8List(_DiskRanking.bitmapBytes);
    final best = List.generate(
      tokens.length,
      (_) => Float64List(_DiskStore.postingPageSize),
    );
    final vector = criteria.useVector
        ? List.generate(
            tokens.length,
            (_) => Float64List(_DiskStore.postingPageSize),
          )
        : const <Float64List>[];
    final phrase = Uint8List(_DiskStore.postingPageSize);
    final starts = positionsNeeded
        ? List.generate(
            _phraseTokens.length,
            (_) => List<List<int>?>.filled(_DiskStore.postingPageSize, null),
          )
        : const <List<List<int>?>>[];
    final cursors = positionsNeeded ? Uint32List(starts.length) : Uint32List(0);
    final boosts = Uint8List(_DiskStore.postingPageSize);
    var boundedOut = 0;
    final groups = <int>{};
    var reads = 0;
    var sqlReads = 0;
    var scored = 0;
    var fallbackReads = 0;
    var positionalReads = 0;
    for (final block in blocks) {
      if (top.length == limit && block.bound < top.last.score) break;
      final page = block.page ~/ 8;
      if (!groups.add(page)) continue;
      await Future<void>.delayed(Duration.zero);
      if (generation != store.searchGeneration) return [];
      final numeric = ByteData.sublistView(
        await store.ranking.numericPage(page),
      );
      eligible.fillRange(0, eligible.length, 0);
      final base = page * _DiskStore.postingPageSize;
      var count = 0;
      for (
        var doc = 0;
        doc < _DiskStore.postingPageSize && base + doc < store.nextDocument;
        doc++
      ) {
        final ordinal = base + doc;
        if ((candidates[ordinal >> 3] & (1 << (ordinal & 7))) == 0) continue;
        final bound = blockBounds[ordinal ~/ _DiskStore.docPageSize];
        if (bound == double.negativeInfinity ||
            (top.length == limit && bound < top.last.score)) {
          boundedOut++;
          continue;
        }
        final offset = doc * _DiskRanking.numericBytes;
        if (numeric.getFloat64(offset + 32) <= 0 ||
            numeric.getFloat64(offset + 8) <= 0) {
          throw StateError('Incomplete numeric search metadata.');
        }
        final start = numeric.getFloat64(offset + 16);
        final end = numeric.getFloat64(offset + 24);
        if ((from != null && math.max(start, end) < from) ||
            (to != null && math.min(start, end) > to)) {
          continue;
        }
        eligible[doc >> 3] |= 1 << (doc & 7);
        count++;
      }
      if (count == 0) continue;
      for (final values in best) {
        values.fillRange(0, values.length, 0);
      }
      for (final values in vector) {
        values.fillRange(0, values.length, 0);
      }
      phrase.fillRange(0, phrase.length, 0);
      for (final values in starts) {
        values.fillRange(0, values.length, null);
      }
      boosts.fillRange(0, boosts.length, 0);
      bool included(int doc) => (eligible[doc >> 3] & (1 << (doc & 7))) != 0;
      for (var offset = 0; offset < terms.length; offset += 500) {
        final part = terms.sublist(
          offset,
          math.min(offset + 500, terms.length),
        );
        final payloads = <(int, List<int>, bool)>[];
        final missing = <int>[];
        for (final term in part) {
          final cached = cachedPosting(term, page);
          if (cached == null) {
            missing.add(term);
          } else {
            payloads.add((term, cached, false));
          }
        }
        if (missing.isNotEmpty) {
          final marks = List.filled(missing.length, '?').join(',');
          final rows = store.database.select(
            'SELECT term, payload FROM postings WHERE page = ? AND term IN ($marks)',
            [page, ...missing],
          );
          for (final row in rows) {
            sqlReads++;
            final term = row['term'] as int;
            payloads.add((term, row['payload'] as List<int>, true));
          }
        }
        for (final (term, bytes, encrypted) in payloads) {
          final payload = encrypted
              ? await store.unsealBytes(bytes)
              : bytes as Uint8List;
          if (encrypted) cachePosting(term, page, payload);
          reads++;
          final info = matchingTerms[term]!;
          final exactAt = info.exact ? tokens.indexOf(info.word) : -1;
          if (!_DiskRanking.hasFieldBoosts(payload)) {
            throw StateError('Incomplete scoring postings.');
          }
          final bitmap = Uint8List.sublistView(
            payload,
            0,
            _DiskRanking.bitmapBytes,
          );
          final data = _DiskRanking.postingData(payload, queryNative: true);
          // Repeated TF/length share arithmetic; boosts stay per document.
          final exactVector = criteria.useVector && exactAt >= 0;
          var lastTf = 0;
          var lastLength = 0.0;
          var baseScore = 0.0;
          var vectorScore = 0.0;
          void score(int doc, int tf, int boost) {
            final length = numeric.getFloat64(doc * _DiskRanking.numericBytes);
            if (tf != lastTf || length != lastLength) {
              final bm25 =
                  info.idf *
                  tf *
                  2.2 /
                  (tf + 1.2 * (.25 + .75 * length / average));
              baseScore = 4 + math.log(1 + bm25);
              if (exactVector && tf != lastTf) {
                vectorScore = info.idf * (1 + math.log(tf));
              }
              lastTf = tf;
              lastLength = length;
            }
            final value = baseScore + boost;
            for (var t = 0; t < tokens.length; t++) {
              best[t][doc] = math.max(best[t][doc], info.matches[t] * value);
            }
            if (exactVector) {
              vector[exactAt][doc] = vectorScore;
            }
            if (coveredPhrase && !positionsNeeded && info.phrase.isNotEmpty) {
              phrase[doc] = 1;
            }
          }

          if (positionsNeeded && info.phrase.isNotEmpty) {
            positionalReads++;
            visitPostingPositions(
              bitmap,
              data,
              (doc, values) {
                score(doc, values.length, boosts[doc]);
                for (final component in info.phrase) {
                  final previous = starts[component][doc];
                  if (previous == null) {
                    starts[component][doc] = values;
                  } else {
                    final merged = <int>[];
                    var a = 0;
                    var b = 0;
                    while (a < previous.length || b < values.length) {
                      final next =
                          b == values.length ||
                              (a < previous.length && previous[a] < values[b])
                          ? previous[a++]
                          : values[b++];
                      if (merged.isEmpty || merged.last != next) {
                        merged.add(next);
                      }
                    }
                    starts[component][doc] = merged;
                  }
                }
              },
              hasFieldBoosts: true,
              onFieldBoost: (doc, boost) => boosts[doc] = boost,
              include: included,
            );
          } else {
            visitPostingScores(bitmap, data, score, include: included);
          }
        }
      }
      for (var doc = 0; doc < _DiskStore.postingPageSize; doc++) {
        if (!included(doc)) continue;
        scored++;
        var lexical = 0.0;
        var dot = 0.0;
        for (var t = 0; t < tokens.length; t++) {
          lexical += best[t][doc];
          if (criteria.useVector) dot += vector[t][doc];
        }
        if (positionsNeeded) {
          if (starts.every((component) => component[doc] != null)) {
            cursors.fillRange(0, cursors.length, 0);
            candidates:
            for (final start in starts.first[doc]!) {
              for (var component = 1; component < starts.length; component++) {
                final values = starts[component][doc]!;
                var cursor = cursors[component];
                while (cursor < values.length &&
                    values[cursor] - component < start) {
                  cursor++;
                }
                cursors[component] = cursor;
                if (cursor == values.length) break candidates;
                if (values[cursor] - component != start) continue candidates;
              }
              phrase[doc] = 1;
              break;
            }
          }
        }
        final offset = doc * _DiskRanking.numericBytes;
        final ordinal = base + doc;
        final time = numeric.getFloat64(offset + 16).toInt();
        final norm = numeric.getFloat64(offset + 8);
        final cosine = criteria.useVector && queryLength > 0
            ? dot / (norm * queryLength) * 2.5
            : 0.0;
        final temporal = scorer.scoreTimestamp(
          utcMicroseconds: time,
          previousResult: previous.contains(ordinal),
        );
        final category = numeric.getFloat64(offset + 32);
        double scoreWithPhrase(bool present) =>
            (lexical + (present ? 4 : 0) + cosine + temporal) * category;
        var score = scoreWithPhrase(phraseFallback || phrase[doc] != 0);
        if (!canEnter(score, time)) continue;
        if (phraseFallback || locationCheck) {
          fallbackReads++;
          if (locationCheck &&
              !criteria.matchesLocation(
                Conversation.fromSummaryJson(await summary(ordinal)).location,
              )) {
            continue;
          }
          if (phraseFallback) {
            score = scoreWithPhrase(await literalPhrase(ordinal));
          }
        }
        await insert(ordinal, score, time);
      }
    }
    store._searchProfile['blockBoundExcludedDocuments'] = boundedOut;
    store._searchProfile['postingCachePeakBytes'] = _payloadPeak;
    store._searchProfile['postingCacheEntries'] = _payloads.length;
    store._searchProfile['postingCacheHits'] = _payloadHits;
    store._searchProfile['scorePostingSqlReads'] = sqlReads;
    store._searchProfile['numericMs'] = clock.elapsedMilliseconds;
    store._searchProfile['scorePostingReads'] = reads;
    final nativeInflates = (inflater?.successfulInflates ?? 0) - nativeBefore;
    store._searchProfile['nativePostingInflates'] = nativeInflates;
    store._searchProfile['managedPostingInflates'] = reads - nativeInflates;
    store._searchProfile['positionReads'] = positionalReads;
    store._searchProfile['scoredDocuments'] = scored;
    store._searchProfile['numericPostingPages'] = groups.length;
    store._searchProfile['scoredBlocks'] = groups.length * 8;
    store._searchProfile['fallbackDocuments'] = fallbackReads;
    final result = <Conversation>[];
    for (final item in top) {
      result.add(Conversation.fromSummaryJson(await summary(item.ordinal)));
      scores.add((score: item.score, time: item.time, id: result.last.id));
    }
    store._searchProfile['scoreMs'] = clock.elapsedMilliseconds;
    return result;
  }
}
