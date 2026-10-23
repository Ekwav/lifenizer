part of '../app_state.dart';

extension VaultSearchCache on LifenizerAppState {
  /// Desktop runners answer once; wait for the query's lazy cache reads before
  /// returning results. The app UI uses synchronous search and rebuilds on load.
  Future<List<Conversation>> searchAsync(
    String query, {
    int? maxResults,
  }) async {
    final generation = _searchGeneration;
    var results = search(query, maxResults: maxResults);
    while ((_searchCacheLoads.isNotEmpty || _searchBuild != null) &&
        generation == _searchGeneration) {
      final index = _searchIndex;
      try {
        await Future.wait([
          ..._searchCacheLoads.values,
          ?_searchBuild,
        ]);
      } catch (_) {
        await _rebuildSearchCache(index, generation);
      }
      if (generation != _searchGeneration || !isAuthenticated) return [];
      results = search(query, maxResults: maxResults);
    }
    return results;
  }

  void _requestSearchDetails(Set<String> ids) => _requestSearchData(ids);

  void _requestSearchPostings(Set<String> terms) =>
      _requestSearchData(terms, postings: true);

  void _requestSearchData(Set<String> ids, {bool postings = false}) {
    if ((postings ? _searchPostingNonces : _searchDetailNonces).isEmpty) return;
    final index = _searchIndex;
    final generation = _searchGeneration;
    unawaited(
      _loadSearchBuckets(
        ids,
        postings: postings,
      ).catchError((Object _) => _rebuildSearchCache(index, generation)),
    );
  }

  Future<void> _rebuildSearchCache(
    ConversationSearchIndex? index,
    int generation,
  ) async {
    if (generation != _searchGeneration || !identical(index, _searchIndex)) {
      return;
    }
    // Search caches are disposable; concurrent callers share one rebuild.
    if (_searchDetailNonces.isNotEmpty || _searchPostingNonces.isNotEmpty) {
      _searchDetailNonces = [];
      _searchPostingNonces = [];
      _searchFullRebuildNeeded = true;
    }
    try {
      await _prepareSearchIndex();
    } catch (error) {
      if (generation != _searchGeneration || !_crypto.isUnlocked) return;
      syncError = 'Could not restore search details: $error';
      _notifyChanged();
    }
  }

  Future<void> _loadSearchBuckets(
    Iterable<String> ids, {
    bool postings = false,
  }) async {
    final index = _searchIndex;
    final generation = _searchGeneration;
    final count =
        (postings ? _searchPostingNonces : _searchDetailNonces).length;
    if (index == null || count == 0) return;
    final buckets = {
      for (final id in ids)
        if (postings
            ? index.unloadedPostingTerms.contains(id)
            : index.documents[id]?.detailsLoaded == false)
          vaultChunkFor(id, count),
    }.toList();
    var next = 0;
    Future<void> lane() async {
      while (next < buckets.length) {
        if (generation != _searchGeneration ||
            !identical(index, _searchIndex)) {
          return;
        }
        await _loadSearchBucket(buckets[next++], postings: postings);
      }
    }

    await Future.wait([
      for (var n = 0; n < math.min(vaultWorkerCount(), buckets.length); n++)
        lane(),
    ]);
  }

  Future<void> _loadSearchBucket(int bucket, {required bool postings}) async {
    final key = (postings, bucket);
    final running = _searchCacheLoads[key];
    if (running != null) return running;
    final operation = _readSearchBucket(bucket, postings: postings);
    _searchCacheLoads[key] = operation;
    try {
      await operation;
    } finally {
      if (identical(_searchCacheLoads[key], operation)) {
        _searchCacheLoads.remove(key);
      }
      _notifyChanged();
    }
  }

  Future<void> _readSearchBucket(int bucket, {required bool postings}) async {
    final generation = _searchGeneration;
    final index = _searchIndex;
    final nonces = postings ? _searchPostingNonces : _searchDetailNonces;
    final nonce = nonces[bucket];
    final kind = postings ? 'posting' : 'detail';
    final record = await _localStore!.read(
      '$_localVaultKey:search-$kind:$bucket',
    );
    if (generation != _searchGeneration || !identical(index, _searchIndex)) {
      return;
    }
    if (record == null || record['nonce'] != nonce) {
      throw StateError('Stored search details do not match the catalog.');
    }
    final details = await decodeSearchDetails(
      await _crypto.decryptJson(
        cipherText: record['cipherText'] as String,
        nonce: nonce,
        background: true,
      ),
    );
    if (generation != _searchGeneration || !identical(index, _searchIndex)) {
      return;
    }
    final expected = postings
        ? index!.unloadedPostingTerms
        : index!.documents.values
              .where((doc) => !doc.detailsLoaded)
              .map((doc) => doc.conversation.id);
    for (final id in expected) {
      if (vaultChunkFor(id, nonces.length) == bucket &&
          !details.containsKey(id)) {
        throw StateError('Stored search details are incomplete.');
      }
    }
    if (postings) {
      index.loadPostings(details);
    } else {
      index.loadDetails(details);
    }
  }

  Future<void> _writeSearchCache(String key) async {
    final index = _searchIndex!;
    final generation = _searchGeneration;
    final revision = _searchRevision;
    void requireCurrent() {
      if (generation != _searchGeneration ||
          !identical(index, _searchIndex) ||
          revision != _searchRevision ||
          !_crypto.isUnlocked) {
        throw StateError('Search index changed while preparing its cache.');
      }
    }

    await _loadSearchBuckets(index.unloadedPostingTerms, postings: true);
    await _loadSearchBuckets(index.documents.keys);
    requireCurrent();
    final count = math.max(
      1,
      math.min(64, (index.documents.length / 64).ceil()),
    );
    final parts = await encodeSearchSnapshotParts(index, count);
    final records = <String, Map<String, dynamic>>{};
    final nonces = List<String>.filled(count, '');
    final postingNonces = List<String>.filled(count, '');
    var next = 0;
    Future<void> lane() async {
      while (next < count * 2) {
        final n = next++;
        final postings = n >= count;
        final bucket = n % count;
        final sealed = await _crypto.encryptJson(
          (postings ? parts.postings : parts.details)[bucket],
          background: true,
        );
        (postings ? postingNonces : nonces)[bucket] = sealed.nonce;
        final kind = postings ? 'posting' : 'detail';
        records['$key:search-$kind:$bucket'] = {
          'cipherText': sealed.cipherText,
          'nonce': sealed.nonce,
        };
      }
    }

    await Future.wait([
      for (var n = 0; n < math.min(vaultWorkerCount(), count); n++) lane(),
    ]);
    final catalog = await _crypto.encryptJson({
      ...parts.catalog,
      'cacheVersion': 3,
      'detailNonces': nonces,
      'postingNonces': postingNonces,
    }, background: true);
    records['$key:search-index'] = {
      'cipherText': catalog.cipherText,
      'nonce': catalog.nonce,
    };
    requireCurrent();
    // SQLite commits the compact catalog and its encrypted scoring buckets in
    // one transaction. The core refers to this catalog only after it succeeds.
    await _localStore!.writeMany(records);
    requireCurrent();
    _searchDetailNonces = nonces;
    _searchPostingNonces = postingNonces;
    _searchSnapshotNonce = catalog.nonce;
    _savedSearchRevision = revision;
  }
}
