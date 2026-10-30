part of '../app_state.dart';

extension VaultDiskSearch on LifenizerAppState {
  Future<void> _cleanupObsoleteChunkLayouts(
    String key, [
    Map<String, dynamic>? saved,
  ]) async {
    final before = _obsoleteChunkLayouts.length;
    final remaining = <Map<String, dynamic>>[];
    for (final layout in _obsoleteChunkLayouts) {
      final generation = layout['generation'] as String?;
      final count = layout['count'] as int;
      final oldKey = generation == null ? key : '$key:chunks:$generation';
      final storage = layout['storage'] as String;
      if (oldKey == _conversationStorageKey) continue;
      final store = storage == _chunks.kind
          ? _chunks
          : storage == 'sembast'
          ? SembastVaultChunkStore(_localStore!)
          : null;
      if (store == null || count < 0 || count > 4096) {
        remaining.add(layout);
        continue;
      }
      try {
        await store.deleteChunks(oldKey, Iterable.generate(count));
      } catch (_) {
        remaining.add(layout);
      }
    }
    _obsoleteChunkLayouts = remaining;
    if (saved != null && remaining.length != before) {
      final acknowledged = Map<String, dynamic>.of(saved);
      if (remaining.isEmpty) {
        acknowledged.remove('obsoleteChunkLayouts');
      } else {
        acknowledged['obsoleteChunkLayouts'] = remaining;
      }
      // Cleanup acknowledgements can wait for the next save if storage is
      // temporarily unavailable; the committed vault is already authoritative.
      try {
        await _localStore!.write(key, acknowledged);
      } catch (_) {}
    }
  }

  Future<void> _recoverDiskSearch() async {
    if (_diskSearch == null) return;
    try {
      await _syncInFlight;
    } catch (_) {}
    await _storageTail;
    await _diskSearch!.cancelSearch();
    _searchGeneration++;
    searchError = null;
    _diskQueryKey = null;
    _diskResults = const [];
    await _diskSearch!.clear();
    conversations.clear();
    final auth = session!;
    await _restoreConversationChunks(
      _coreSnapshot(
        auth,
        _chunkCount,
        _chunkConversationCounts,
        _chunkMessageCounts,
      ),
      (_chunks, _conversationStorageKey, _chunkNonces, _unconfirmedChunkNonces),
    );
    _diskIndexReady();
    // The authenticated outbox can contain changes newer than the source
    // chunks. Reapply them before publishing the rebuilt cache or saving data.
    for (final envelope in _pendingSync.toList()) {
      if (envelope.entityType != 'conversation') continue;
      final payload = await _crypto.decryptJson(
        cipherText: envelope.cipherText,
        nonce: envelope.nonce,
        background: true,
      );
      await _applyEntity(envelope.entityType, payload);
    }
    await _prepareDiskSearch();
    await _persistLocal();
  }

  Future<bool> _openDiskSearch({int? conversationCount}) async {
    if (_diskSearch != null) return true;
    if (kIsWeb ||
        _localStore == null ||
        !_crypto.isUnlocked ||
        (conversationCount ?? conversations.length) < 1000) {
      return false;
    }
    final generation = _searchGeneration;
    final path = await _localStore!.sqlitePath;
    if (path == null ||
        generation != _searchGeneration ||
        !_crypto.isUnlocked) {
      return false;
    }
    final hash = await Sha256().hash(utf8.encode(_localVaultKey!));
    final name = hash.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final key = await _crypto.exportDeviceKey();
    try {
      // Crossing the native threshold can leave older bodies in vault chunks.
      // Load those before replacing the in-memory index with an empty sidecar.
      await _loadAllConversations();
      final index = await DiskSearchIndex.open(
        path: '$path.search-$name',
        vaultKey: key,
        recreateOnFailure: true,
      );
      if (generation != _searchGeneration || !_crypto.isUnlocked) {
        await index.close();
        return false;
      }
      _diskSearch = index;
      _searchIndex = null;
      _searchDetailNonces = [];
      _searchPostingNonces = [];
      _searchFullRebuildNeeded = true;
      return true;
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  void _diskIndexReady() {
    _indexedConversationCount = conversations.length;
    _indexedParticipantCount = participants.length;
    _indexedRelationCount = relations.length;
    _searchDirtyIds.clear();
    _searchFullRebuildNeeded = false;
    _searchRevision++;
    _diskQueryKey = null;
    _diskResults = const [];
  }

  Future<void> _prepareDiskSearch() async {
    if (!_needsSearchIndex) return;
    final generation = _searchGeneration;
    final index = _diskSearch!;
    final inputs = _searchIndexInputs(includeConversations: false);
    final participantCount = participants.length;
    final relationCount = relations.length;
    final full = _searchFullRebuildNeeded;
    final dirty = {..._searchDirtyIds};
    final missing = {...dirty};
    final positions = <int>[];
    for (var i = 0; i < conversations.length; i++) {
      if (full || dirty.contains(conversations[i].id)) {
        positions.add(i);
        missing.remove(conversations[i].id);
      }
    }
    _searchDirtyIds.removeAll(dirty);
    _searchFullRebuildNeeded = false;
    try {
      await index.remove(missing.toList());
      for (
        var offset = 0;
        offset < positions.length;
        offset += DiskSearchIndex.writeBatchSize
      ) {
        if (generation != _searchGeneration) return;
        final slots = positions
            .skip(offset)
            .take(DiskSearchIndex.writeBatchSize)
            .toList();
        final originals = [for (final slot in slots) conversations[slot]];
        final bodies = (await index.loadConversations([
          for (final doc in originals)
            if (!doc.isLoaded) doc.id,
        ])).iterator;
        final batch = <Conversation>[];
        for (final original in originals) {
          if (original.isLoaded) {
            batch.add(_canonicalConversation(original));
          } else {
            bodies.moveNext();
            batch.add(_canonicalConversation(bodies.current));
          }
        }
        await index.upsert(
          batch,
          participantById: inputs.$2,
          relationTextByConversation: inputs.$3,
        );
        if (generation != _searchGeneration) return;
        for (var n = 0; n < slots.length; n++) {
          if (identical(conversations[slots[n]], originals[n])) {
            conversations[slots[n]] = Conversation.fromSummaryJson(
              batch[n].toSummaryJson(previewLength: 180),
            );
          }
        }
        _setSyncProgress(
          SyncStage.indexing,
          completed: math.min(offset + batch.length, positions.length),
          total: positions.length,
          force: false,
        );
      }
      if (full) {
        fullSearchBuilds++;
      } else {
        incrementalSearchUpdates++;
      }
      _indexedConversationCount = await index.count;
      _indexedParticipantCount = participantCount;
      _indexedRelationCount = relationCount;
      _searchRevision++;
      _diskQueryKey = null;
      _diskResults = const [];
    } catch (_) {
      if (generation == _searchGeneration) {
        _searchDirtyIds.addAll(dirty);
        _searchFullRebuildNeeded |= full;
      }
      rethrow;
    }
  }

  Future<void> _restoreDiskConversations(
    List raw,
    _RestoreProgress progress,
  ) async {
    final inputs = _searchIndexInputs(includeConversations: false);
    for (
      var offset = 0;
      offset < raw.length;
      offset += DiskSearchIndex.writeBatchSize
    ) {
      final batch = [
        for (final row in raw.skip(offset).take(DiskSearchIndex.writeBatchSize))
          _canonicalConversation(
            Conversation.fromJson(Map<String, dynamic>.from(row as Map)),
          ),
      ];
      await _diskSearch!.upsert(
        batch,
        participantById: inputs.$2,
        relationTextByConversation: inputs.$3,
      );
      for (final doc in batch) {
        conversations.add(
          Conversation.fromSummaryJson(doc.toSummaryJson(previewLength: 180)),
        );
        progress.restoredMessages += doc.segmentCount;
      }
      _reportRestore(progress, force: false);
    }
  }

  Future<void> _writeDiskSearchCache(String key) async {
    final payload = await _crypto.encryptJson({'cacheVersion': 5});
    await _diskSearch!.writeMetadata('snapshotNonce', payload.nonce);
    await _localStore!.write('$key:search-index', {
      'cacheVersion': 5,
      'cipherText': payload.cipherText,
      'nonce': payload.nonce,
    });
    _searchSnapshotNonce = payload.nonce;
    _savedSearchRevision = _searchRevision;
  }

  List<Conversation> _searchDisk(
    SearchCriteria criteria,
    SearchScorer scorer,
    List<String> tokens,
    String normalized, {
    int? maxResults,
    required String contextQuery,
  }) {
    if (_locking) return const [];
    final key = jsonEncode([
      _searchRevision,
      criteria.normalized,
      criteria.source,
      criteria.participantId,
      criteria.tag,
      criteria.favoritesOnly,
      criteria.useVector,
      criteria.from?.toIso8601String(),
      criteria.to?.toIso8601String(),
      criteria.includeConsumed,
      criteria.locationLabels,
      tokens,
      maxResults,
    ]);
    if (_diskQueryKey == key) return _diskResults;
    _diskQueryKey = key;
    searchError = null;
    _diskResults = const [];
    final generation = _searchGeneration;
    final engine = _diskSearch!;
    final request = () async {
      try {
        final found = await engine.search(
          criteria,
          scorer,
          tokens,
          normalized,
          maxResults: (maxResults ?? 100).clamp(1, 100),
        );
        if (generation == _searchGeneration && _diskQueryKey == key) {
          _diskResults = found;
          _updateSearchContext(contextQuery, found, DateTime.now().toUtc());
        }
      } catch (_) {
        if (generation == _searchGeneration && _diskQueryKey == key) {
          searchError =
              'Could not read the search index. Rebuild search to retry.';
        }
      }
    }();
    _diskQuery = request;
    unawaited(
      request.whenComplete(() {
        if (identical(_diskQuery, request)) _diskQuery = null;
        if (generation == _searchGeneration) _notifyChanged();
      }),
    );
    return const [];
  }

  Future<void> _writeDiskVault(String key, AuthSession auth) async {
    // Resident edits can be newer than the index prepared by this save.
    final captured = _dirtyRevision;
    final desired = vaultChunkCountFor(conversations.length);
    final rewrite =
        _chunkCount == 0 ||
        desired >= _chunkCount * 4 ||
        _chunkMigrationFrom != null;
    final count = rewrite ? desired : _chunkCount;
    final previousKey = _conversationStorageKey;
    final previousCount = _chunkCount;
    final migrating = _chunkMigrationFrom != null;
    final generation = rewrite ? _uuid.v4() : _chunkGeneration;
    final storageKey = generation == null ? key : '$key:chunks:$generation';
    final groups = List.generate(count, (_) => <Conversation>[]);
    final messages = List<int>.filled(count, 0);
    for (final doc in conversations) {
      final n = vaultChunkFor(doc.id, count);
      groups[n].add(doc);
      messages[n] += doc.segmentCount;
    }
    final counts = [for (final group in groups) group.length];
    final dirty = rewrite
        ? {for (var n = 0; n < count; n++) n}
        : {
            for (final id in _dirtyConversations.keys) vaultChunkFor(id, count),
            for (var n = 0; n < count; n++)
              if (counts[n] != _chunkConversationCounts[n]) n,
          };
    await _cleanupObsoleteChunkLayouts(key);
    await _writeDiskSearchCache(key);
    Map<String, dynamic> record(
      EncryptedPayload payload,
      List<String?> nonces, {
      bool pending = false,
    }) => {
      'vaultSalt': auth.vaultSalt,
      'format': 2,
      'chunkStorage': _chunks.kind,
      'cipherText': payload.cipherText,
      'nonce': payload.nonce,
      'chunkCount': count,
      'chunkNonces': nonces,
      if (_obsoleteChunkLayouts.isNotEmpty)
        'obsoleteChunkLayouts': _obsoleteChunkLayouts,
      'chunkGeneration': ?generation,
      if (pending)
        'pendingChunkNonces': {
          for (final entry in _unconfirmedChunkNonces.entries)
            '${entry.key}': entry.value,
        },
    };
    final nonces = [
      for (var n = 0; n < count; n++)
        n < _chunkNonces.length ? _chunkNonces[n] : null,
    ];
    final order = dirty.toList()..sort();
    if (rewrite && previousCount > 0) {
      final previous = await _crypto.encryptJson(
        _coreSnapshot(
          auth,
          previousCount,
          _chunkConversationCounts,
          _chunkMessageCounts,
          cursor: _savedCursor,
        ),
        background: true,
      );
      await _localStore!.write(key, {
        'vaultSalt': auth.vaultSalt,
        'format': 2,
        'chunkStorage': migrating ? 'sembast' : _chunks.kind,
        'cipherText': previous.cipherText,
        'nonce': previous.nonce,
        'chunkCount': previousCount,
        'chunkNonces': _chunkNonces,
        if (_obsoleteChunkLayouts.isNotEmpty)
          'obsoleteChunkLayouts': _obsoleteChunkLayouts,
        if (_chunkGeneration != null) 'chunkGeneration': _chunkGeneration,
        'pendingChunkGeneration': generation,
      });
    }
    for (var offset = 0; offset < order.length;) {
      final payloads = <int, EncryptedPayload>{};
      var documents = 0;
      while (offset < order.length &&
          (payloads.isEmpty ||
              (payloads.length < 16 &&
                  documents + counts[order[offset]] <= 5000))) {
        final n = order[offset++];
        final unloaded = (await _diskSearch!.loadConversations([
          for (final doc in groups[n])
            if (!doc.isLoaded) doc.id,
        ])).iterator;
        final bodies = <Conversation>[];
        for (final doc in groups[n]) {
          if (doc.isLoaded) {
            bodies.add(doc);
          } else {
            unloaded.moveNext();
            bodies.add(unloaded.current);
          }
        }
        payloads[n] = await _crypto.encryptJson({
          'conversations': bodies,
        }, background: true);
        documents += bodies.length;
      }
      if (!rewrite) {
        for (final entry in payloads.entries) {
          (_unconfirmedChunkNonces[entry.key] ??= []).add(entry.value.nonce);
        }
        final before = await _crypto.encryptJson(
          _coreSnapshot(
            auth,
            count,
            _chunkConversationCounts,
            _chunkMessageCounts,
            cursor: _savedCursor,
          ),
          background: true,
        );
        await _localStore!.write(
          key,
          record(before, _chunkNonces, pending: true),
        );
      }
      await _chunks.writeChunks(storageKey, {
        for (final entry in payloads.entries)
          entry.key: {
            'cipherText': entry.value.cipherText,
            'nonce': entry.value.nonce,
          },
      });
      for (final entry in payloads.entries) {
        nonces[entry.key] = entry.value.nonce;
      }
    }
    final core = await _crypto.encryptJson(
      _coreSnapshot(auth, count, counts, messages),
      background: true,
    );
    if (rewrite && previousCount > 0 && previousKey != storageKey) {
      _obsoleteChunkLayouts.add({
        'generation': _chunkGeneration,
        'count': previousCount,
        'storage': migrating ? 'sembast' : _chunks.kind,
      });
    }
    final committed = record(core, nonces);
    await _localStore!.write(key, committed);
    _chunkGeneration = generation;
    _chunkCount = count;
    _chunkNonces = nonces;
    _chunkConversationCounts = counts;
    _chunkMessageCounts = messages;
    _savedCursor = syncCursor;
    _chunkMigrationFrom = null;
    _unconfirmedChunkNonces.clear();
    _dirtyConversations.removeWhere((_, revision) => revision <= captured);
    _unloadedChunks.addAll(Iterable.generate(count));
    _snapshotWriteRevision++;
    await _cleanupObsoleteChunkLayouts(key, committed);
  }
}
