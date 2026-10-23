part of '../app_state.dart';

extension VaultSearchCache on LifenizerAppState {
  void _requestSearchDetails(Set<String> ids) {
    if (_searchDetailNonces.isEmpty) return;
    final index = _searchIndex;
    final generation = _searchGeneration;
    unawaited(
      _loadSearchDetailsForIds(ids).catchError((Object _) {
        if (generation != _searchGeneration ||
            !identical(index, _searchIndex)) {
          return;
        }
        // Scoring details are disposable. The authenticated posting catalog still
        // gives matching IDs while original conversations rebuild a damaged cache.
        _searchDetailNonces = [];
        _searchFullRebuildNeeded = true;
        unawaited(
          _prepareSearchIndex().catchError((Object error) {
            if (generation != _searchGeneration || !_crypto.isUnlocked) return;
            syncError = 'Could not restore search details: $error';
            _notifyChanged();
          }),
        );
      }),
    );
  }

  Future<void> _loadSearchDetailsForIds(Iterable<String> ids) async {
    final index = _searchIndex;
    final generation = _searchGeneration;
    final count = _searchDetailNonces.length;
    if (index == null || count == 0) return;
    final buckets = {
      for (final id in ids)
        if (index.documents[id]?.detailsLoaded == false)
          vaultChunkFor(id, count),
    }.toList();
    var next = 0;
    Future<void> lane() async {
      while (next < buckets.length) {
        if (generation != _searchGeneration ||
            !identical(index, _searchIndex)) {
          return;
        }
        await _loadSearchDetailBucket(buckets[next++]);
      }
    }

    await Future.wait([
      for (var n = 0; n < math.min(vaultWorkerCount(), buckets.length); n++)
        lane(),
    ]);
  }

  Future<void> _loadSearchDetailBucket(int bucket) async {
    final running = _searchDetailLoads[bucket];
    if (running != null) return running;
    final operation = _readSearchDetailBucket(bucket);
    _searchDetailLoads[bucket] = operation;
    try {
      await operation;
    } finally {
      if (identical(_searchDetailLoads[bucket], operation)) {
        _searchDetailLoads.remove(bucket);
      }
      _notifyChanged();
    }
  }

  Future<void> _readSearchDetailBucket(int bucket) async {
    final generation = _searchGeneration;
    final index = _searchIndex;
    final nonce = _searchDetailNonces[bucket];
    final record = await _localStore!.read(
      '$_localVaultKey:search-detail:$bucket',
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
    for (final doc in index!.documents.values) {
      if (!doc.detailsLoaded &&
          vaultChunkFor(doc.conversation.id, _searchDetailNonces.length) ==
              bucket &&
          !details.containsKey(doc.conversation.id)) {
        throw StateError('Stored search details are incomplete.');
      }
    }
    index.loadDetails(details);
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

    await _loadSearchDetailsForIds(index.documents.keys);
    requireCurrent();
    final count = math.max(
      1,
      math.min(64, (index.documents.length / 64).ceil()),
    );
    final parts = await encodeSearchSnapshotParts(index, count);
    final records = <String, Map<String, dynamic>>{};
    final nonces = List<String>.filled(count, '');
    var next = 0;
    Future<void> lane() async {
      while (next < count) {
        final bucket = next++;
        final sealed = await _crypto.encryptJson(
          parts.details[bucket],
          background: true,
        );
        nonces[bucket] = sealed.nonce;
        records['$key:search-detail:$bucket'] = {
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
      'detailNonces': nonces,
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
    _searchSnapshotNonce = catalog.nonce;
    _savedSearchRevision = revision;
  }
}
