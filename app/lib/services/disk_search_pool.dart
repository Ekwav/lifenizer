part of 'disk_search_index_io.dart';

typedef _SearchScore = ({double score, int time, String id});

class _SearchReply {
  const _SearchReply(this.results, this.profile, this.scores);
  final List<Conversation> results;
  final Map<String, int> profile;
  final List<_SearchScore> scores;
}

class _DiskSearchPool {
  _DiskSearchPool(this.writer, this.path, List<int> bytes, this.workers)
    : key = SecretKeyData(bytes.toList(), overwriteWhenDestroyed: true);
  final DiskSearchIndex writer;
  final String path;
  final SecretKeyData key;
  final int? workers;
  List<DiskSearchIndex> _readers = [];
  Future<void>? _opening;
  Future<void> _writes = Future.value();
  Future<Object?>? _closing;
  final _queries = <Future<Object?>>{};
  Map<String, int> _profile = {};
  int _generation = 0;
  bool _closed = false;

  Future<void> _cancel({bool initialization = false}) async {
    await Future.wait([
      if (_opening == null || initialization) writer.cancelSearch(),
      for (final reader in _readers) reader.cancelSearch(),
    ]);
  }

  Future<void> _openReaders(Future<void> writes) async {
    final opened = <DiskSearchIndex>[];
    try {
      final limit =
          workers ??
          DiskSearchIndex.automaticSearchWorkers(
            await writer.count,
            Platform.numberOfProcessors,
          );
      if (_closed || !identical(writes, _writes)) {
        throw StateError('Search pool preparation was cancelled.');
      }
      final next = await writer._request('documentCapacity', null) as int;
      final pages = (next + 1023) ~/ 1024;
      final count = math.min(limit, pages);
      // Only the query readers need hydrated numeric pages after migrations.
      await writer._request('prepare', count < 2);
      if (count < 2) return;
      if (await writer._request('releaseQueryBuffers', null) != 0) {
        throw StateError('Primary numeric query buffers were not released.');
      }
      for (var i = 0; i < count; i++) {
        if (_closed || !identical(writes, _writes)) {
          throw StateError('Search pool preparation was cancelled.');
        }
        final reader = await DiskSearchIndex._openWorker(
          path: path,
          vaultKey: key.bytes,
          readOnly: true,
          rangeStart: (pages * i ~/ count) * 1024,
          rangeEnd: math.min(next, (pages * (i + 1) ~/ count) * 1024),
          sqliteCacheKiB: 16384 ~/ count + (i < 16384 % count ? 1 : 0),
        );
        opened.add(reader);
        await reader.prepare();
      }
      if (_closed || !identical(writes, _writes)) {
        throw StateError('Search pool preparation was cancelled.');
      }
      _readers = opened;
    } catch (_) {
      // Each close waits for worker exit, including after a startup failure.
      try {
        await Future.wait(opened.map((reader) => reader.close()));
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _prepare({int? generation}) async {
    final writes = _writes;
    await writes;
    if (generation != null && (_closed || generation != _generation)) return;
    if (!identical(writes, _writes)) return _prepare(generation: generation);
    if (_closed) throw StateError('The disk search index is closed.');
    if (_readers.isNotEmpty) return;
    if (_opening case final Future<void> opening) return opening;
    final opening = _openReaders(writes);
    _opening = opening;
    try {
      await opening;
    } finally {
      _opening = null;
    }
  }

  Future<void> _closeReaders() async {
    // Failed initialization already closed its partial pool; repair writes may
    // proceed even when the original preparation caller received an error.
    try {
      await _opening;
    } catch (_) {}
    final readers = _readers;
    _readers = [];
    await Future.wait(readers.map((reader) => reader.close()));
  }

  Future<Object?> _barrier(Future<Object?> Function() operation) {
    final queries = _queries.toList();
    final result = _writes.then((_) async {
      try {
        await _cancel(initialization: true);
      } catch (_) {}
      await Future.wait(
        queries.map((query) async {
          try {
            await query;
          } catch (_) {}
        }),
      );
      await _closeReaders();
      return operation();
    });
    // Preserve the operation's error for its caller, while allowing the next
    // write to repair the index after an unsuccessful mutation.
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<_SearchReply> _search(Object? value, int generation) async {
    await _writes;
    if (_closed || generation != _generation) {
      return const _SearchReply([], {}, []);
    }
    await _cancel();
    if (_closed || generation != _generation) {
      return const _SearchReply([], {}, []);
    }
    final (criteria, scorer, tokens, _, limit) =
        value as (SearchCriteria, SearchScorer, List<String>, String, int);
    if (_usesRecent(criteria, scorer, tokens)) {
      // An initializer can be using the primary; wait before its recent query.
      try {
        await _opening;
      } catch (_) {}
      if (_closed || generation != _generation) {
        return const _SearchReply([], {}, []);
      }
      final reply = await writer._request('search', value) as _SearchReply;
      if (generation != _generation) return const _SearchReply([], {}, []);
      _profile = reply.profile;
      _markProfile(1);
      return reply;
    }
    try {
      await _prepare(generation: generation);
    } catch (_) {
      if (_closed || generation != _generation) {
        return const _SearchReply([], {}, []);
      }
      rethrow;
    }
    if (_closed || generation != _generation) {
      return const _SearchReply([], {}, []);
    }
    final replies = await Future.wait([
      for (final reader in _readers.isEmpty ? [writer] : _readers)
        reader._request('search', value).then((reply) => reply as _SearchReply),
    ]);
    if (_closed || generation != _generation) {
      return const _SearchReply([], {}, []);
    }
    final candidates =
        <(Conversation, _SearchScore)>[
          for (final reply in replies)
            for (var i = 0; i < reply.results.length; i++)
              (reply.results[i], reply.scores[i]),
        ]..sort((a, b) {
          final score = b.$2.score.compareTo(a.$2.score);
          if (score != 0) return score;
          final time = b.$2.time.compareTo(a.$2.time);
          return time != 0 ? time : a.$2.id.compareTo(b.$2.id);
        });
    _profile = {};
    for (final reply in replies) {
      for (final entry in reply.profile.entries) {
        _profile[entry.key] =
            const {
              'nativeAead',
              'nativePostingInflaterAvailable',
            }.contains(entry.key)
            ? math.min(_profile[entry.key] ?? entry.value, entry.value)
            : (_profile[entry.key] ?? 0) + entry.value;
      }
    }
    _markProfile(replies.length);
    final top = candidates.take(limit).toList();
    return _SearchReply(
      [for (final item in top) item.$1],
      _profile,
      [for (final item in top) item.$2],
    );
  }

  void _markProfile(int activeWorkers) {
    final configuredWorkers = math.max(1, _readers.length);
    _profile['searchWorkers'] = activeWorkers;
    _profile['configuredSearchWorkers'] = configuredWorkers;
    _profile['automaticSearchWorkers'] = workers == null ? 1 : 0;
    if (_readers.isNotEmpty) {
      _profile['primaryNumericCacheBytesAfterRelease'] = 0;
    }
    _profile['phaseTimesAreWorkSums'] = activeWorkers > 1 ? 1 : 0;
    _profile['postingPayloadCacheTotalLimitBytes'] =
        configuredWorkers * 16 * 1024 * 1024;
    _profile['sqliteCacheTotalBudgetKiB'] = _readers.isEmpty
        ? (_profile['sqliteCacheKiB'] ?? 0)
        : 16384;
  }

  Future<Object?> request(String operation, Object? value) async {
    if (_closed) {
      if (operation == 'close') return _closing;
      throw StateError('The disk search index is closed.');
    }
    if (operation == 'search') {
      final generation = ++_generation;
      late final Future<Object?> query;
      query = _search(value, generation).whenComplete(() {
        _queries.remove(query);
      });
      _queries.add(query);
      return query;
    }
    if (operation == 'cancelSearch') {
      _generation++;
      await _cancel();
      return null;
    }
    if (operation == 'close') {
      _closed = true;
      _generation++;
      return _closing = _barrier(() async => null).whenComplete(() async {
        try {
          await writer.close();
        } finally {
          key.destroy();
        }
      });
    }
    if (const {
      'upsert',
      'remove',
      'clear',
      'writeMetadata',
    }.contains(operation)) {
      _generation++;
      return _barrier(() => writer._request(operation, value));
    }
    if (operation == 'prepare') {
      final generation = _generation;
      await _prepare();
      if (generation != _generation) {
        throw StateError('Search index preparation was cancelled.');
      }
      return null;
    }
    if (operation == 'searchProfile') return Map<String, int>.of(_profile);
    await _writes;
    if (_closed) throw StateError('The disk search index is closed.');
    return writer._request(operation, value);
  }
}

bool _usesRecent(
  SearchCriteria criteria,
  SearchScorer scorer,
  List<String> tokens,
) =>
    criteria.isEmptyQuery &&
    tokens.isEmpty &&
    scorer.normalizedQuery.isEmpty &&
    criteria.normalizedSource == null &&
    criteria.normalizedParticipantId == null &&
    criteria.normalizedTag == null &&
    criteria.locationLabels.isEmpty &&
    !criteria.favoritesOnly &&
    criteria.from == null &&
    criteria.to == null &&
    criteria.includeConsumed;
