part of 'disk_search_index_io.dart';

/// Exact facet bitmaps prevent sparse filters from decoding unrelated pages.
class _DiskFilters {
  _DiskFilters(this.store);
  final _DiskStore store;
  final _keys = <String, Uint8List>{};
  bool? _ready;
  static const bitmapBytes = _DiskStore.postingPageSize ~/ 8;

  void initialize() => store.database.execute(
    'CREATE TABLE IF NOT EXISTS filterpostings '
    '(lookup BLOB NOT NULL, page INTEGER NOT NULL, payload BLOB NOT NULL, '
    'PRIMARY KEY (lookup, page)) WITHOUT ROWID',
  );

  void invalidate() {
    _ready = null;
    _keys.clear();
  }

  Future<Uint8List> key(String value) async {
    final found = _keys.remove(value);
    final result = found ?? await store.lookup('filter', value);
    _keys[value] = result;
    if (_keys.length > 4096) _keys.remove(_keys.keys.first);
    return result;
  }

  static Set<String> terms(Map summary) => {
    'source:${summary['source']}',
    'group:${groupForSource(summary['source'] as String).name}',
    for (final id in summary['participantIds'] as List) 'person:$id',
    for (final tag in summary['tags'] as List)
      'tag:${(tag as String).toLowerCase()}',
    if (summary['isFavorite'] == true) 'favorite:1',
    if (summary['location'] != null) 'location:1',
  };

  Future<void> complete() async {
    await store.writeMetadata('_filterVersion', 1);
    store.database.execute("DELETE FROM metadata WHERE key = '_filterCursor'");
    _ready = true;
  }

  Future<bool> ensure(int generation) async {
    _ready ??= await store.readMetadata('_filterVersion') == 1;
    if (_ready!) return true;
    var page = await store.readMetadata('_filterCursor') as int? ?? 0;
    final count =
        (store.nextDocument + _DiskStore.docPageSize - 1) ~/
        _DiskStore.docPageSize;
    while (page < count) {
      await Future<void>.delayed(Duration.zero);
      if (generation != store.searchGeneration) return false;
      store.database.execute('BEGIN IMMEDIATE');
      try {
        final writer = _FilterWrites(this);
        final end = math.min(page + 8, count);
        for (; page < end; page++) {
          final summaries = await store.readPage(
            'summarypages',
            page,
            _DiskStore.docPageSize,
          );
          for (var slot = 0; slot < summaries.length; slot++) {
            if (summaries[slot] case final Map summary) {
              await writer.change(
                page * _DiskStore.docPageSize + slot,
                summary,
                true,
              );
            }
          }
        }
        await writer.flush();
        await store.writeMetadata('_filterCursor', page);
        store.database.execute('COMMIT');
      } catch (_) {
        store.database.execute('ROLLBACK');
        invalidate();
        rethrow;
      }
    }
    store.database.execute('BEGIN IMMEDIATE');
    try {
      await complete();
      store.database.execute('COMMIT');
    } catch (_) {
      store.database.execute('ROLLBACK');
      invalidate();
      rethrow;
    }
    return generation == store.searchGeneration;
  }

  Future<Uint8List?> candidates(SearchCriteria criteria, int generation) async {
    final source = criteria.normalizedSource;
    final positive = <String>[
      if (source != null)
        if (groupFromSourceFilter(source) case final SearchSourceGroup group)
          'group:${group.name}'
        else
          'source:$source',
      if (criteria.normalizedParticipantId case final String id) 'person:$id',
      if (criteria.normalizedTag case final String tag) 'tag:$tag',
      if (criteria.favoritesOnly) 'favorite:1',
      if (criteria.locationLabels.isNotEmpty) 'location:1',
    ];
    if (positive.isEmpty && criteria.includeConsumed) return null;
    if (!await ensure(generation)) return Uint8List(0);
    final size = (store.nextDocument + 7) ~/ 8;
    Uint8List? result;
    for (final (term, exclude) in [
      for (final term in positive) (term, false),
      if (!criteria.includeConsumed) ('group:consumed', true),
    ]) {
      final bits = Uint8List(size);
      final lookup = await key(term);
      var after = -1;
      while (true) {
        await Future<void>.delayed(Duration.zero);
        if (generation != store.searchGeneration) return Uint8List(0);
        final rows = store.database.select(
          'SELECT page, payload FROM filterpostings '
          'WHERE lookup = ? AND page > ? ORDER BY page LIMIT 32',
          [lookup, after],
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          after = row['page'] as int;
          final data = await store.unsealBytes(row['payload'] as List<int>);
          if (data.length != bitmapBytes) {
            throw StateError('Incomplete search filter index.');
          }
          final start = after * bitmapBytes;
          final length = math.min(data.length, bits.length - start);
          if (length > 0) bits.setRange(start, start + length, data);
        }
      }
      result ??= Uint8List(size)..fillRange(0, size, 255);
      for (var i = 0; i < size; i++) {
        result[i] &= exclude ? (bits[i] ^ 255) : bits[i];
      }
      if (result.every((byte) => byte == 0)) return result;
    }
    return result;
  }
}

class _FilterWrites {
  _FilterWrites(this.filters);
  final _DiskFilters filters;
  final _pages = <(String, int), Uint8List>{};

  Future<void> change(int id, Map summary, bool present) async {
    for (final term in _DiskFilters.terms(summary)) {
      final address = (term, id ~/ _DiskStore.postingPageSize);
      var bits = _pages[address];
      if (bits == null) {
        final rows = filters.store.database.select(
          'SELECT payload FROM filterpostings WHERE lookup = ? AND page = ?',
          [await filters.key(term), address.$2],
        );
        bits = rows.isEmpty
            ? Uint8List(_DiskFilters.bitmapBytes)
            : await filters.store.unsealBytes(
                rows.single['payload'] as List<int>,
              );
        if (bits.length != _DiskFilters.bitmapBytes) {
          throw StateError('Incomplete search filter index.');
        }
        _pages[address] = bits;
      }
      final offset = id % _DiskStore.postingPageSize;
      if (present) {
        bits[offset >> 3] |= 1 << (offset & 7);
      } else {
        bits[offset >> 3] &= ~(1 << (offset & 7));
      }
    }
  }

  Future<void> flush() async {
    for (final entry in _pages.entries) {
      final lookup = await filters.key(entry.key.$1);
      if (entry.value.every((byte) => byte == 0)) {
        filters.store.database.execute(
          'DELETE FROM filterpostings WHERE lookup = ? AND page = ?',
          [lookup, entry.key.$2],
        );
      } else {
        filters.store.database.execute(
          'INSERT OR REPLACE INTO filterpostings VALUES (?, ?, ?)',
          [lookup, entry.key.$2, await filters.store.sealBytes(entry.value)],
        );
      }
    }
  }
}
