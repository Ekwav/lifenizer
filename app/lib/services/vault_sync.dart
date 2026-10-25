part of '../app_state.dart';

extension VaultSync on LifenizerAppState {
  Future<void> initialize() async {
    if (_localStore == null) {
      _localStore = await LocalVaultStore.open();
      _chunkStore ??= await openVaultChunkStore(_localStore!);
    }
    final settings = await _localStore!.read('settings');
    if (settings == null) return;
    apiBaseUrl = settings['apiBaseUrl'] as String? ?? apiBaseUrl;
    rememberedEmail = settings['email'] as String? ?? '';
    deviceId = settings['deviceId'] as String? ?? deviceId;
  }

  VaultChunkStore get _chunks =>
      _chunkStore ??= SembastVaultChunkStore(_localStore!);

  Future<void> login({
    required String baseUrl,
    required String email,
    required String passphrase,
    String? password,
    bool register = false,
    String? registrationToken,
    bool offline = false,
    AuthSession? pairedSession,
    String? deviceVaultKey,
    String? deviceVaultSalt,
  }) async {
    if (!pairing.busy) beginUnlockTiming();
    await _run(() async {
      if (passphrase.isEmpty || email.trim().isEmpty) {
        throw ArgumentError('Enter your email and vault passphrase.');
      }
      if (register && password == passphrase) {
        throw ArgumentError(
          'Use different account and vault passwords; your vault passphrase must stay on this device.',
        );
      }
      if (register && passphrase.length < 12) {
        throw ArgumentError(
          'Use a vault passphrase of at least 12 characters.',
        );
      }
      _unlocking = true;
      try {
        _setSyncProgress(
          SyncStage.readingLocal,
          downloaded: 0,
          uploaded: 0,
          batch: 0,
        );
        await initialize();
        apiBaseUrl = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
        final uri = Uri.tryParse(apiBaseUrl);
        if (uri == null ||
            !uri.hasAuthority ||
            !['http', 'https'].contains(uri.scheme)) {
          throw ArgumentError('Enter a valid API URL.');
        }
        final normalizedEmail = email.trim().toLowerCase();
        _localVaultKey = 'vault:${jsonEncode([apiBaseUrl, normalizedEmail])}';
        final local = await _localStore!.read(_localVaultKey!);
        markUnlock('localRead');
        final anonymous =
            apiFactory?.call(apiBaseUrl) ??
            LifenizerApiClient(baseUrl: apiBaseUrl);
        AuthSession? auth = pairedSession;
        if (!offline && auth == null) {
          _setSyncProgress(SyncStage.authenticating, detail: 'Signing in');
          auth = password == null
              ? await anonymous.devLogin(
                  email: normalizedEmail,
                  displayName: normalizedEmail.split('@').first,
                )
              : await anonymous.accountLogin(
                  email: normalizedEmail,
                  password: password,
                  register: register,
                  registrationToken: registrationToken,
                );
        } else if (offline && local == null) {
          throw StateError(
            'Unlock online once on this device before using offline mode.',
          );
        }
        _setSyncProgress(SyncStage.derivingKey);
        final salt = auth?.vaultSalt ?? local!['vaultSalt'] as String;
        if (deviceVaultKey != null && deviceVaultSalt == salt) {
          final bytes = base64Decode(deviceVaultKey);
          try {
            _crypto.unlockDeviceKey(bytes);
          } finally {
            bytes.fillRange(0, bytes.length, 0);
          }
        } else {
          await _crypto.unlock(
            email: normalizedEmail,
            passphrase: passphrase,
            vaultSalt: salt,
            background: true,
          );
        }
        _clearVault();
        markStartup('vaultKey');
        markUnlock('vaultKey');
        var repaired = false;
        var resyncRequired = false;
        if (local != null) {
          final restored = await _restoreLocalVault(local, offline: offline);
          repaired = restored.needsSave;
          resyncRequired = restored.resyncRequired;
          if (auth == null) await _restoreSessionForSnapshot(local);
        }
        session = auth ?? session;
        final current = session!;
        if (local != null && local['vaultSalt'] != current.vaultSalt) {
          throw StateError(
            'The server vault changed. Your local vault was preserved.',
          );
        }
        _api = anonymous.authenticated(
          current.authToken,
          refreshAuth: pairing.matchesVault(apiBaseUrl, normalizedEmail)
              ? pairing.refreshAccess
              : null,
        );
        rememberedEmail = normalizedEmail;
        final savedBeforeSync = _snapshotWriteRevision;
        Future<void> finishUnlock() async {
          if (!offline) {
            await _syncNow();
            if (register) {
              await _pushEntity('vault-check', current.vaultId, {
                'id': current.vaultId,
                'version': 1,
              });
              // Registration must publish its key check before another device
              // can connect; ordinary edits use the automatic batch window.
              await _syncNow(forceUpload: true);
            }
            try {
              importCapabilities
                ..clear()
                ..addAll(await anonymous.importCapabilities());
            } catch (_) {
              // Cached conversations and sync remain usable without discovery.
            }
          }
          _setSyncProgress(SyncStage.saving);
          if (_snapshotWriteRevision == savedBeforeSync) {
            if (local == null || repaired) {
              await _persistLocal();
            } else if (auth != null) {
              await _persistSessionForSnapshot(local);
            }
          }
          await _localStore!.write('settings', {
            'apiBaseUrl': apiBaseUrl,
            'email': rememberedEmail,
            'deviceId': deviceId,
          });
          await _prepareSearchIndex();
          _setSyncProgress(SyncStage.complete);
          status = offline
              ? 'Local vault unlocked · changes will sync when connected'
              : 'Vault unlocked';
        }

        if (local != null && !register && !resyncRequired) {
          // The cached vault is authenticated by its own AES-GCM tags, so the
          // UI opens now. Remote ciphertext is validated by the sync below,
          // which runs as the ordinary background sync: lock() waits for it and
          // a failure surfaces as syncError instead of failing the unlock.
          _unlocking = false;
          markStartup('searchReady');
          markUnlock('searchReady');
          status = offline
              ? 'Local vault unlocked · changes will sync when connected'
              : 'Vault unlocked · syncing in background';
          _runUnlockInBackground(finishUnlock);
          _notifyChanged();
        } else {
          // First unlock on this device (nothing cached), registration, or a
          // local vault that must be downloaded again: validate every remote
          // ciphertext before exposing the unlocked UI.
          await finishUnlock();
          markUnlock('searchReady');
        }
      } catch (_) {
        _crypto.lock();
        _api = null;
        session = null;
        _clearVault();
        rethrow;
      } finally {
        _unlocking = false;
      }
    }, prepareIndex: false);
  }

  /// Runs the remainder of an early unlock through [_syncInFlight] so that
  /// lock() waits for it, and reports failures as a paused sync.
  void _runUnlockInBackground(Future<void> Function() body) {
    final done = Completer<void>();
    _syncInFlight = done.future;
    unawaited(() async {
      try {
        await body();
      } catch (exception) {
        if (_crypto.isUnlocked) {
          syncError = 'Sync paused: $exception';
          status = 'Vault unlocked · sync interrupted';
          _setSyncProgress(SyncStage.failed);
        }
      } finally {
        if (identical(_syncInFlight, done.future)) _syncInFlight = null;
        done.complete();
        _notifyChanged();
      }
    }());
  }

  /// Resolves when any background unlock/sync work has finished.
  Future<void> waitForBackgroundSync() async {
    while (_syncInFlight != null) {
      try {
        await _syncInFlight;
      } catch (_) {}
    }
    await _storageTail;
  }

  Future<String> exportDeviceVaultKey() async {
    if (!isAuthenticated) throw StateError('Unlock the vault first.');
    final bytes = await _crypto.exportDeviceKey();
    try {
      return base64Encode(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void resumePairedSync() => _runUnlockInBackground(() async {
    await pairing.refreshAccess();
    await _syncNow();
  });

  Future<void> updatePairedSession(AuthSession auth) async {
    final current = session;
    if (current == null ||
        !_crypto.isUnlocked ||
        current.userId != auth.userId ||
        current.vaultId != auth.vaultId ||
        current.vaultSalt != auth.vaultSalt) {
      throw StateError('Paired session does not match this vault.');
    }
    session = auth;
    _api!.authToken = auth.authToken;
    await _persistLocal();
  }

  Future<void> lock() async {
    if (busy) return;
    busy = true;
    _notifyChanged();
    try {
      await stopRecording?.call();
      // A failed network request must not prevent the vault from locking.
      try {
        await _syncInFlight;
      } catch (_) {}
      await _storageTail;
      // Preserve the latest outbox and recording even if sync failed. A storage
      // failure leaves the unlocked data available so the user can retry.
      await _persistLocal();
      _crypto.lock();
      _api = null;
      session = null;
      _clearVault();
      pairing.onLocked();
      status = 'Vault locked';
    } catch (exception) {
      error = 'Could not save and lock the vault: $exception';
    } finally {
      busy = false;
      _notifyChanged();
    }
  }

  void _clearVault() {
    participants.clear();
    _invalidateParticipantLookup();
    conversations.clear();
    _importedConversationRepairs.clear();
    relations.clear();
    savedSearches.clear();
    images.clear();
    importCapabilities.clear();
    quotaStatus = null;
    audioDraft = null;
    _pendingDraftPayload = null;
    _draftPayloadCache = null;
    _pendingSync.clear();
    _pendingRecordingSync.clear();
    _lastSyncUploadAt = null;
    syncCursor = 0;
    syncError = null;
    _clearSyncProgress();
    lastSyncedAt = null;
    _searchGeneration++;
    _searchIndex = null;
    _searchSnapshotNonce = null;
    _searchDetailNonces = [];
    _searchPostingNonces = [];
    _searchCacheLoads.clear();
    _savedSearchRevision = -1;
    _unloadedChunks.clear();
    _chunkLoads.clear();
    _searchDirtyIds.clear();
    _indexedConversationCount = -1;
    _indexedRelationCount = -1;
    _indexedParticipantCount = -1;
    _markSearchIndexDirty();
    _chunkMigrationFrom = null;
    _chunkCount = 0;
    _chunkNonces = <String?>[];
    _chunkConversationCounts = <int>[];
    _chunkMessageCounts = <int>[];
    _savedCursor = 0;
    _unconfirmedChunkNonces.clear();
    _dirtyConversations.clear();
    _lastSearchQuery = null;
    _lastSearchAt = null;
    _lastSearchTopConversationIds = const [];
    _sessionQueryFrequency.clear();
  }

  void _clearSyncProgress() {
    syncProgress = null;
    _progressStageClock?.stop();
    _progressStageClock = null;
    _syncProgressTicker?.cancel();
    _syncProgressTicker = null;
  }

  Future<void> pullSync() => _run(() => _synchronize(forceUpload: true));

  Future<void> syncQuietly() async {
    if (!isAuthenticated || busy) return;
    try {
      await _synchronize();
    } catch (exception) {
      syncError = 'Sync paused: $exception';
      _notifyChanged();
    }
  }

  Future<void> _synchronize({bool forceUpload = false}) async {
    if (_syncInFlight != null) {
      await _syncInFlight;
      if (!forceUpload || _pendingSync.isEmpty) return;
    }
    final operation = _syncNow(forceUpload: forceUpload);
    _syncInFlight = operation;
    try {
      await operation;
    } finally {
      _syncInFlight = null;
    }
  }

  void _setSyncProgress(
    SyncStage stage, {
    int completed = 0,
    int? total,
    int receivedBytes = 0,
    int? totalBytes,
    int? downloaded,
    int? uploaded,
    int? batch,
    String? detail,
    bool force = true,
  }) {
    final nextBatch = batch ?? syncProgress?.batch ?? 0;
    if (syncProgress?.stage != stage ||
        syncProgress?.detail != detail ||
        syncProgress?.batch != nextBatch) {
      _progressStageClock?.stop();
      _progressStageClock = Stopwatch()..start();
    }
    syncProgress = SyncProgress(
      stage: stage,
      completed: completed,
      total: total,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
      downloaded: downloaded ?? syncProgress?.downloaded ?? 0,
      uploaded: uploaded ?? syncProgress?.uploaded ?? 0,
      batch: nextBatch,
      detail: detail,
      stageClock: _progressStageClock,
    );
    if (syncProgress!.active) {
      _syncProgressTicker ??= Timer.periodic(
        const Duration(milliseconds: 300),
        (_) {
          if (syncProgress?.active == true) _notifyChanged();
        },
      );
    } else {
      _syncProgressTicker?.cancel();
      _syncProgressTicker = null;
      _progressStageClock?.stop();
    }
    if (!force && _syncProgressClock.elapsedMilliseconds < 150) return;
    _syncProgressClock.reset();
    _notifyChanged();
  }

  Future<void> _syncNow({bool forceUpload = false}) async {
    try {
      await _transferSync(forceUpload: forceUpload);
      final recordingChanged = await _retryRecordingSync();
      if (forceUpload && recordingChanged) {
        await _transferSync(forceUpload: true);
      }
      _setSyncProgress(SyncStage.complete);
    } catch (_) {
      _setSyncProgress(SyncStage.failed);
      rethrow;
    }
  }

  Future<void> _transferSync({required bool forceUpload}) async {
    final api = _requireApi();
    const window = Duration(seconds: 20);
    final now = _syncClock().toUtc();
    final due =
        _pendingSync.isNotEmpty &&
        now.difference(_pendingSync.first.clientCreatedAt) >= window &&
        (_lastSyncUploadAt == null ||
            now.difference(_lastSyncUploadAt!) >= window);
    // Freeze this window. Edits arriving during network requests belong to the
    // next batch, rather than generating a tail of small immediate uploads.
    final uploadQueue = forceUpload || due
        ? _pendingSync.toList()
        : <SyncEnvelope>[];
    final uploadTotal = uploadQueue.length;
    if (uploadQueue.isNotEmpty) {
      _lastSyncUploadAt = now;
      // A failed request may already have reached storage. Keep the retry
      // deadline across lock/restart as well as within this session.
      await _persistLocal();
    }
    var uploaded = 0;
    var downloaded = 0;
    var page = 0;
    var acknowledgedChanges = false;
    while (uploadQueue.isNotEmpty) {
      final batch = <SyncEnvelope>[];
      var bytes = 0;
      for (final envelope in uploadQueue) {
        // Ciphertext is ASCII. Leave ample room for envelope JSON below
        // Kestrel's request limit when a large archive is imported offline.
        final size = envelope.cipherText.length + 1024;
        if (batch.isNotEmpty &&
            (batch.length == 100 || bytes + size > 8 * 1024 * 1024)) {
          break;
        }
        batch.add(envelope);
        bytes += size;
      }
      // The push cursor may include unseen writes from another device.
      // Only a successful pull is allowed to advance our read cursor.
      _setSyncProgress(
        SyncStage.uploading,
        completed: uploaded,
        total: uploadTotal,
        uploaded: uploaded,
        downloaded: 0,
        batch: 0,
      );
      await api.push(batch);
      uploaded += batch.length;
      acknowledgedChanges = true;
      uploadQueue.removeRange(0, batch.length);
      final acknowledged = batch.map((e) => e.id).toSet();
      _pendingSync.removeWhere((e) => acknowledged.contains(e.id));
    }
    while (true) {
      page++;
      _setSyncProgress(
        SyncStage.downloading,
        downloaded: downloaded,
        uploaded: uploaded,
        batch: page,
      );
      final pulled = await api.pull(
        syncCursor,
        onProgress: (received, total) {
          _setSyncProgress(
            SyncStage.downloading,
            receivedBytes: received,
            totalBytes: total,
            force: false,
          );
        },
      );
      _setSyncProgress(SyncStage.decrypting, total: pulled.envelopes.length);
      final decoded = <Map<String, dynamic>>[];
      for (final envelope in pulled.envelopes) {
        decoded.add(
          await _crypto.decryptJson(
            cipherText: envelope.cipherText,
            nonce: envelope.nonce,
            background: envelope.cipherText.length > 64 * 1024,
          ),
        );
        _setSyncProgress(
          SyncStage.decrypting,
          completed: decoded.length,
          total: pulled.envelopes.length,
          force: false,
        );
        if (decoded.length % 25 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      _setSyncProgress(SyncStage.applying, total: pulled.envelopes.length);
      for (var i = 0; i < pulled.envelopes.length; i++) {
        final envelope = pulled.envelopes[i];
        final pending = _pendingSync.any(
          (pending) =>
              pending.entityType == envelope.entityType &&
              pending.entityId == envelope.entityId,
        );
        final importedThread =
            envelope.entityType == 'conversation' &&
            decoded[i]['sourceThreadId'] != null;
        if (pending && !importedThread) {
          continue;
        }
        await _applyEntity(
          envelope.entityType,
          decoded[i],
          preserveLocalChanges: pending,
        );
        _setSyncProgress(
          SyncStage.applying,
          completed: i + 1,
          total: pulled.envelopes.length,
          force: false,
        );
        if ((i + 1) % 25 == 0) await Future<void>.delayed(Duration.zero);
      }
      downloaded += pulled.envelopes.length;
      await _queueImportedConversationRepairs();
      final advanced = pulled.cursor > syncCursor;
      syncCursor = pulled.cursor;
      final finished = pulled.envelopes.length < 500 || !advanced;
      if (finished) {
        // Coalescing queues participant writes. Apply every pull page first so
        // these writes cannot suppress later updates to the same person.
        await _coalesceParticipantIdentities();
      }
      if (acknowledgedChanges ||
          pulled.envelopes.isNotEmpty ||
          advanced ||
          _pendingSync.isNotEmpty) {
        _setSyncProgress(SyncStage.saving, downloaded: downloaded);
        await _persistLocal();
        acknowledgedChanges = false;
      }
      if (finished) break;
    }
    if (_needsSearchIndex) {
      await _prepareSearchIndex(complete: false);
    }
    if (_pendingSync.isEmpty || uploaded > 0) syncError = null;
    lastSyncedAt = DateTime.now();
    _notifyChanged();
  }

  Future<void> _pushEntity(
    String entityType,
    String entityId,
    Map<String, dynamic> json,
  ) async {
    final payload = await _crypto.encryptJson(json);
    final previousIndex = _pendingSync.indexWhere(
      (item) => item.entityType == entityType && item.entityId == entityId,
    );
    final queuedAt = previousIndex < 0
        ? _syncClock().toUtc()
        : _pendingSync[previousIndex].clientCreatedAt;
    // Keep the original enqueue time so continuous edits cannot postpone sync.
    // A fresh ID leaves any already captured/in-flight envelope immutable.
    _pendingSync.removeWhere(
      (item) => item.entityType == entityType && item.entityId == entityId,
    );
    _pendingSync.insert(
      previousIndex < 0 ? _pendingSync.length : previousIndex,
      SyncEnvelope(
        id: _uuid.v4(),
        deviceId: deviceId,
        entityType: entityType,
        entityId: entityId,
        operation: 'upsert',
        revision: 1,
        cipherText: payload.cipherText,
        nonce: payload.nonce,
        keyId: payload.keyId,
        clientCreatedAt: queuedAt,
      ),
    );
    if (_vaultBatchDepth > 0) {
      // A stream of immediately completed crypto futures otherwise starves
      // frames and input events during a large import.
      if (_pendingSync.length % 50 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      return;
    }
    // Save immediately; automatic sync collects at least 20 seconds of edits.
    await _persistLocal();
  }

  /// Save related edits together before publishing them. If parsing fails,
  /// completed edits still enter the encrypted outbox and can be retried.
  Future<T> batchVaultChanges<T>(Future<T> Function() action) async {
    if (_vaultBatchDepth == 0) {
      try {
        await _syncInFlight;
      } catch (_) {
        // Offline imports can proceed after a failed background sync.
      }
    }
    _vaultBatchDepth++;
    try {
      return await action();
    } finally {
      _vaultBatchDepth--;
      if (_vaultBatchDepth == 0 && _pendingSync.isNotEmpty) {
        await _persistLocal();
      }
    }
  }

  /// Plaintext of the core record: everything except conversation contents.
  /// `conversationBuckets` lets a loader verify every chunk and size progress.
  Map<String, dynamic> _coreSnapshot(
    AuthSession auth,
    int chunkCount,
    List<int> conversationCounts,
    List<int> messageCounts, {
    int? cursor,
  }) => {
    'session': auth.toJson(),
    'cursor': cursor ?? syncCursor,
    // Capture immutable records now; their JSON conversion runs in the worker.
    'participants': participants.toList(),
    'relations': relations.toList(),
    'savedSearches': savedSearches.toList(),
    'pending': _pendingSync.toList(),
    if (_pendingRecordingSync.isNotEmpty)
      'pendingRecordingSync': Map<String, bool>.of(_pendingRecordingSync),
    if (_lastSyncUploadAt != null)
      'lastSyncUploadAt': _lastSyncUploadAt!.toIso8601String(),
    if (audioDraft != null) 'audioDraft': audioDraft,
    if (cursor == null &&
        _searchSnapshotNonce != null &&
        _savedSearchRevision == _searchRevision &&
        !_needsSearchIndex)
      'searchIndexNonce': _searchSnapshotNonce,
    'conversationBuckets': {
      'count': chunkCount,
      'conversations': conversationCounts,
      'messages': messageCounts,
    },
  };

  static const _incompleteVaultMessage =
      'The local vault on this device is incomplete (a stored part is missing '
      'or damaged). Unsent changes were kept. Unlock online so the vault can be '
      're-downloaded.';

  /// Reads the local vault record: legacy v1 (one blob) or v2 (core + chunks).
  Future<({bool needsSave, bool resyncRequired})> _restoreLocalVault(
    Map<String, dynamic> local, {
    required bool offline,
  }) async {
    _setSyncProgress(SyncStage.decryptingLocal);
    final core = await _crypto.decryptJson(
      cipherText: local['cipherText'] as String,
      nonce: local['nonce'] as String,
      background: true,
    );
    markUnlock('coreDecrypted');
    final format = local['format'];
    if (format == null) {
      // Legacy single blob: restore as before; the first save converts it.
      await _restoreSnapshot(core);
      return (needsSave: true, resyncRequired: false);
    }
    if (format != 2) {
      throw StateError(
        'This local vault was written by a newer version of the app.',
      );
    }
    if (local['incomplete'] == true) {
      if (offline) throw StateError(_incompleteVaultMessage);
      await _restoreSnapshot(core);
      return (needsSave: true, resyncRequired: true);
    }
    final key = _localVaultKey!;
    final count = local['chunkCount'] as int? ?? 0;
    final nonces = [
      for (final nonce in local['chunkNonces'] as List? ?? const [])
        nonce as String?,
    ];
    // Vaults written before chunk files existed keep their chunks in Sembast;
    // they load from there and the next save moves them to the current store.
    final storage = local['chunkStorage'] as String? ?? 'sembast';
    final VaultChunkStore? source = storage == _chunks.kind
        ? _chunks
        : storage == 'sembast'
        ? SembastVaultChunkStore(_localStore!)
        : null;
    if (source == null || nonces.length != count) {
      await _quarantineIncompleteVault(core, local, key, count);
    }
    // A save that crashed between writing chunk files and its final core leaves
    // pendingChunkNonces: such a file may carry either nonce.
    final pending = <int, List<String>>{};
    for (final entry
        in (local['pendingChunkNonces'] as Map? ?? const {}).entries) {
      final value = entry.value;
      pending[int.parse(entry.key as String)] = value is List
          ? [for (final item in value) item as String]
          : [value as String];
    }
    try {
      ConversationSearchIndex? cachedIndex;
      var catalogInDatabase = false;
      var currentCatalog = false;
      final cacheNonce = core['searchIndexNonce'] as String?;
      if (cacheNonce != null &&
          pending.isEmpty &&
          source.kind == _chunks.kind) {
        try {
          var record = await _localStore!.read('$key:search-index');
          catalogInDatabase = record != null && record['nonce'] == cacheNonce;
          if (!catalogInDatabase) {
            record = await source.readBlob(key, 'search-index');
          }
          if (record != null && record['nonce'] == cacheNonce) {
            markUnlock('catalogRead');
            late Map<String, dynamic> snapshot;
            if (catalogInDatabase && record['cacheVersion'] == 4) {
              snapshot = await _crypto.decryptJson(
                cipherText: record['cipherText'] as String,
                nonce: cacheNonce,
                background: true,
              );
              final shardNonces = List<String>.from(
                snapshot['catalogNonces'] as List,
              );
              if (snapshot['cacheVersion'] != 4 ||
                  shardNonces.isEmpty ||
                  shardNonces.length > 6) {
                throw const FormatException('Invalid catalog manifest');
              }
              final shards = await Future.wait([
                for (var n = 0; n < shardNonces.length; n++)
                  _localStore!.read('$key:search-catalog:$n'),
              ]);
              for (var n = 0; n < shards.length; n++) {
                if (shards[n] == null ||
                    shards[n]!['nonce'] != shardNonces[n]) {
                  throw const FormatException('Missing catalog shard');
                }
              }
              cachedIndex = await decryptSearchCatalogShards(
                _crypto,
                shards.cast<Map<String, dynamic>>(),
              );
            } else {
              final decoded = await decryptSearchSnapshot(
                _crypto,
                cipherText: record['cipherText'] as String,
                nonce: cacheNonce,
              );
              snapshot = decoded.metadata;
              cachedIndex = decoded.index;
            }
            markUnlock('catalogDecoded');
            currentCatalog = snapshot['cacheVersion'] == 4;
            markStartup('searchCatalog');
            if (catalogInDatabase) {
              _searchDetailNonces = List<String>.from(
                snapshot['detailNonces'] as List,
              );
              _searchPostingNonces = List<String>.from(
                snapshot['postingNonces'] as List? ?? const [],
              );
              if (_searchDetailNonces.isEmpty) {
                throw const FormatException('Missing search detail buckets');
              }
              if (!cachedIndex.postingsLoaded && _searchPostingNonces.isEmpty) {
                throw const FormatException('Missing search posting buckets');
              }
            }
          }
        } catch (_) {
          // A disposable cache must never make the encrypted vault unreadable.
          cachedIndex = null;
          _searchDetailNonces = [];
          _searchPostingNonces = [];
        }
      }
      if (cachedIndex != null) {
        final counts = List<int>.from(
          core['conversationBuckets']['conversations'],
        );
        final actualCounts = List<int>.filled(count, 0);
        for (final id in cachedIndex.documents.keys) {
          actualCounts[vaultChunkFor(id, count)]++;
        }
        if (!listEquals(counts, actualCounts)) {
          cachedIndex = null;
          _searchDetailNonces = [];
          _searchPostingNonces = [];
        }
      }
      if (cachedIndex != null) {
        // Check file headers without decrypting their contents. Body integrity
        // is authenticated when a chunk is actually opened.
        final actual = await Future.wait([
          for (var n = 0; n < count; n++) source.chunkNonce(key, n),
        ]);
        if (!listEquals(actual, nonces)) throw const _IncompleteChunks();
        markUnlock('chunkHeaders');
      }
      final repaired = await _restoreSnapshot(
        core,
        chunks: cachedIndex == null ? (source, key, nonces, pending) : null,
        cachedIndex: cachedIndex,
      );
      for (final n in pending.keys) {
        // Remember which nonce the file really carries.
        final actual = n < count ? await source.chunkNonce(key, n) : null;
        if (actual == null) throw const _IncompleteChunks();
        nonces[n] = actual;
      }
      _savedCursor = syncCursor;
      _chunkMessageCounts = [
        for (final value
            in (core['conversationBuckets'] as Map?)?['messages'] as List? ??
                const [])
          value as int,
      ];
      _chunkCount = count;
      _chunkNonces = nonces;
      _chunkConversationCounts = [
        for (final value
            in (core['conversationBuckets'] as Map?)?['conversations']
                    as List? ??
                const [])
          value as int,
      ];
      final migrating = source.kind != _chunks.kind;
      if (migrating) _chunkMigrationFrom = count;
      if (cachedIndex != null) {
        _unloadedChunks.addAll(Iterable.generate(count));
        _searchSnapshotNonce = cacheNonce;
        _savedSearchRevision =
            catalogInDatabase &&
                currentCatalog &&
                _searchPostingNonces.isNotEmpty
            ? _searchRevision
            : -1;
      }
      return (
        needsSave:
            repaired ||
            migrating ||
            pending.isNotEmpty ||
            cachedIndex == null ||
            !catalogInDatabase ||
            !currentCatalog ||
            _searchPostingNonces.isEmpty,
        resyncRequired: false,
      );
    } on _IncompleteChunks {
      await _quarantineIncompleteVault(core, local, key, count);
    }
  }

  /// A part of the chunked vault is missing or damaged. The core decrypted, so
  /// the unsent outbox and microphone draft are rewritten into a minimal core
  /// (cursor 0) and the chunk records are dropped; an online unlock then
  /// downloads everything again. Always throws.
  Future<Never> _quarantineIncompleteVault(
    Map<String, dynamic> core,
    Map<String, dynamic> local,
    String key,
    int count,
  ) async {
    try {
      final payload = await _crypto.encryptJson({
        'session': core['session'],
        'cursor': 0,
        'participants': const [],
        'relations': const [],
        'savedSearches': const [],
        'pending': core['pending'] ?? const [],
        if (core['audioDraft'] != null) 'audioDraft': core['audioDraft'],
        if (core['pendingRecordingSync'] != null)
          'pendingRecordingSync': core['pendingRecordingSync'],
        'conversationBuckets': {
          'count': 0,
          'conversations': const [],
          'messages': const [],
        },
      }, background: true);
      await _localStore!.write(key, {
        'vaultSalt': local['vaultSalt'],
        'format': 2,
        'incomplete': true,
        'cipherText': payload.cipherText,
        'nonce': payload.nonce,
        'chunkCount': 0,
        'chunkNonces': const <String>[],
      });
      await _chunks.deleteAll(key);
      await _chunks.deleteBlob(key, 'search-index');
      await SembastVaultChunkStore(
        _localStore!,
      ).deleteChunks(key, [for (var n = 0; n < count; n++) n]);
    } catch (exception) {
      throw StateError(
        '$_incompleteVaultMessage (Recovery could not be saved: $exception)',
      );
    }
    throw StateError(_incompleteVaultMessage);
  }

  Future<bool> _restoreSnapshot(
    Map<String, dynamic> json, {
    (VaultChunkStore, String, List<String?>, Map<int, List<String>>)? chunks,
    ConversationSearchIndex? cachedIndex,
  }) async {
    audioDraft = json['audioDraft'] == null
        ? null
        : Map<String, dynamic>.from(json['audioDraft']);
    var legacyDraft = false;
    final legacyPayload = audioDraft?.remove('payload');
    if (legacyPayload is String) {
      // Older vaults kept the WAV inside the core; the next save moves it.
      _pendingDraftPayload = _draftPayloadCache = base64Decode(legacyPayload);
      audioDraft!['payloadBytes'] = _pendingDraftPayload!.length;
      legacyDraft = true;
    }
    session = AuthSession.fromJson(Map<String, dynamic>.from(json['session']));
    syncCursor = json['cursor'] as int;
    participants.addAll(
      json.parseObjectList('participants', Participant.fromJson),
    );
    _invalidateParticipantLookup();
    if (cachedIndex != null) {
      conversations.addAll(
        cachedIndex.documents.values.map((d) => d.conversation),
      );
    } else if (chunks == null) {
      final rawConversations = json['conversations'] as List? ?? const [];
      final progress = _RestoreProgress(
        messages: rawConversations.fold<int>(
          0,
          (count, raw) =>
              count + (((raw as Map)['segments'] as List?)?.length ?? 0),
        ),
        conversations: rawConversations.length,
      );
      _reportRestore(progress, force: true);
      await _restoreConversationList(rawConversations, progress);
      _reportRestore(progress, force: true);
    } else {
      await _restoreConversationChunks(json, chunks);
    }
    relations.addAll(json.parseObjectList('relations', RelationEdge.fromJson));
    savedSearches.addAll(
      json.parseObjectList('savedSearches', SavedSearch.fromJson),
    );
    _pendingSync.addAll(json.parseObjectList('pending', SyncEnvelope.fromJson));
    _lastSyncUploadAt = json.parseDateTime('lastSyncUploadAt');
    _pendingRecordingSync.addAll(
      Map<String, bool>.from(json['pendingRecordingSync'] as Map? ?? const {}),
    );
    var repaired = legacyDraft;
    _people;
    if (_hasParticipantRedirects && cachedIndex == null) {
      for (var i = 0; i < conversations.length; i++) {
        final canonical = _canonicalConversation(conversations[i]);
        if (!identical(canonical, conversations[i])) {
          conversations[i] = canonical;
          _markConversationChanged(canonical.id);
          repaired = true;
        }
        if (i % 50 == 0) {
          _setSyncProgress(
            SyncStage.restoring,
            completed: i + 1,
            total: conversations.length,
            detail: 'Connecting saved people',
            force: false,
          );
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    if (cachedIndex == null) {
      _markSearchIndexDirty();
    } else {
      _installSearchIndex(
        cachedIndex,
        conversationCount: conversations.length,
        participantCount: participants.length,
        relationCount: relations.length,
      );
      _searchFullRebuildNeeded = false;
    }
    return repaired;
  }

  /// Loads only the encrypted bucket containing this conversation. Concurrent
  /// requests share a read; newer in-memory edits always win over disk.
  Future<Conversation> _loadConversation(String id) async {
    Conversation? current() =>
        conversations.where((c) => c.id == id).firstOrNull;
    final existing = current();
    if (existing == null) throw StateError('Conversation no longer exists.');
    if (existing.isLoaded) return existing;
    if (!_crypto.isUnlocked) throw StateError('Unlock the vault first.');
    await _loadConversationChunk(vaultChunkFor(id, _chunkCount));
    final loaded = current();
    if (loaded == null || !loaded.isLoaded) {
      throw StateError('Conversation could not be loaded.');
    }
    return loaded;
  }

  Future<void> _loadConversationChunk(int n) async {
    if (!_unloadedChunks.contains(n)) return;
    final running = _chunkLoads[n];
    if (running != null) return running;
    final operation = _readConversationChunk(n);
    _chunkLoads[n] = operation;
    try {
      await operation;
    } finally {
      if (identical(_chunkLoads[n], operation)) _chunkLoads.remove(n);
    }
  }

  Future<void> _readConversationChunk(int n) async {
    final generation = _searchGeneration;
    final decoded = await _chunks.decryptChunk(
      _crypto,
      _localVaultKey!,
      n,
      _chunkNonces[n]!,
    );
    final restored = {
      for (final c in decoded.parseObjectList(
        'conversations',
        Conversation.fromJson,
      ))
        c.id: c,
    };
    if (generation != _searchGeneration || !_crypto.isUnlocked) {
      throw StateError('Vault was locked while loading.');
    }
    // Validate the complete bucket before replacing any summaries.
    for (final c in conversations) {
      if (!c.isLoaded &&
          vaultChunkFor(c.id, _chunkCount) == n &&
          (restored[c.id] == null ||
              restored[c.id]!.segmentCount != c.segmentCount)) {
        throw StateError(_incompleteVaultMessage);
      }
    }
    for (var i = 0; i < conversations.length; i++) {
      final summary = conversations[i];
      if (summary.isLoaded || vaultChunkFor(summary.id, _chunkCount) != n) {
        continue;
      }
      final loaded = _canonicalConversation(restored[summary.id]!);
      conversations[i] = loaded;
      _searchIndex?.documents[loaded.id]?.conversation = loaded;
      if (!identical(loaded, restored[summary.id])) {
        _markConversationChanged(loaded.id);
      }
    }
    _unloadedChunks.remove(n);
    _notifyChanged();
  }

  Future<void> _loadAllConversations() async {
    for (final n in _unloadedChunks.toList()) {
      await _loadConversationChunk(n);
    }
  }

  void _reportRestore(_RestoreProgress progress, {bool force = false}) =>
      _setSyncProgress(
        SyncStage.restoring,
        completed: progress.messages == 0
            ? conversations.length
            : progress.restoredMessages,
        total: progress.messages == 0
            ? progress.conversations
            : progress.messages,
        detail: progress.messages == 0 ? 'Restoring local conversations' : null,
        force: force,
      );

  Future<void> _restoreConversationList(
    List rawConversations,
    _RestoreProgress progress,
  ) async {
    for (final raw in rawConversations) {
      final item = Map<String, dynamic>.from(raw as Map);
      final conversation = Conversation.fromJson({
        ...item,
        'segments': const [],
      });
      for (final segment in item['segments'] as List? ?? const []) {
        conversation.segments.add(
          ConversationSegment.fromJson(
            Map<String, dynamic>.from(segment as Map),
          ),
        );
        progress.restoredMessages++;
        if (progress.restoredMessages % 250 == 0) {
          _reportRestore(progress);
          await Future<void>.delayed(Duration.zero);
        }
      }
      conversations.add(conversation);
      if (conversations.length % 50 == 0) {
        _reportRestore(progress);
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  /// Decrypts every chunk on up to [vaultWorkerCount] background isolates
  /// (decrypt + jsonDecode run in the worker) while this isolate builds models
  /// from finished chunks in yielding batches.
  Future<void> _restoreConversationChunks(
    Map<String, dynamic> core,
    (VaultChunkStore, String, List<String?>, Map<int, List<String>>) chunks,
  ) async {
    final (source, key, nonces, pending) = chunks;
    final chunkTotal = nonces.length;
    final buckets = core['conversationBuckets'] as Map?;
    int sum(String field) => ((buckets?[field] as List?) ?? const []).fold<int>(
      0,
      (total, value) => total + (value as int),
    );
    final expectedConversations = sum('conversations');
    final progress = _RestoreProgress(
      messages: sum('messages'),
      conversations: expectedConversations,
    );
    _setSyncProgress(
      SyncStage.decryptingLocal,
      completed: 0,
      total: chunkTotal,
      detail: 'Decrypting your cached vault',
    );
    var decrypted = 0;
    var next = 0;
    var failed = false;
    var parsed = Future<void>.value();
    Future<void> lane() async {
      while (!failed) {
        final n = next++;
        if (n >= chunkTotal) return;
        final Map<String, dynamic> decoded;
        try {
          decoded = await source.decryptChunk(
            _crypto,
            key,
            n,
            nonces[n] ?? '',
            alternateNonces: pending[n] ?? const [],
          );
        } catch (_) {
          failed = true;
          throw const _IncompleteChunks();
        }
        decrypted++;
        _setSyncProgress(
          SyncStage.decryptingLocal,
          completed: decrypted,
          total: chunkTotal,
          force: false,
        );
        final raw = decoded['conversations'] as List? ?? const [];
        parsed = parsed.then((_) {
          return _restoreConversationList(raw, progress);
        });
      }
    }

    Object? failure;
    try {
      await Future.wait([
        for (var i = 0; i < math.min(vaultWorkerCount(), chunkTotal); i++)
          lane(),
      ]);
    } catch (exception) {
      failure = exception;
    }
    try {
      await parsed;
    } catch (exception) {
      failure ??= exception;
    }
    if (failure != null) throw failure;
    _reportRestore(progress, force: true);
    // Chunks newer than the core (pending nonces) legitimately differ.
    if (buckets != null &&
        pending.isEmpty &&
        conversations.length != expectedConversations) {
      throw const _IncompleteChunks();
    }
  }

  Future<void> _restoreSessionForSnapshot(Map<String, dynamic> snapshot) async {
    final key = _localVaultKey!;
    final saved = await _localStore!.read('$key:session');
    if (saved == null || saved['snapshotNonce'] != snapshot['nonce']) return;
    try {
      final value = await _crypto.decryptJson(
        cipherText: saved['cipherText'] as String,
        nonce: saved['nonce'] as String,
      );
      if (value['vaultKey'] != key) return;
      final auth = AuthSession.fromJson(
        Map<String, dynamic>.from(value['session'] as Map),
      );
      final cached = session!;
      if (auth.userId == cached.userId &&
          auth.vaultId == cached.vaultId &&
          auth.vaultSalt == cached.vaultSalt) {
        session = auth;
      }
    } catch (_) {
      // The authenticated snapshot remains usable if its optional renewal is invalid.
    }
  }

  Future<void> _persistSessionForSnapshot(Map<String, dynamic> snapshot) async {
    final key = _localVaultKey!;
    final auth = session!;
    final operation = _storageTail.then((_) async {
      final payload = await _crypto.encryptJson({
        'vaultKey': key,
        'session': auth.toJson(),
      });
      await _localStore!.write('$key:session', {
        'snapshotNonce': snapshot['nonce'],
        'cipherText': payload.cipherText,
        'nonce': payload.nonce,
      });
    });
    _storageTail = operation.catchError((Object _) {});
    await operation;
  }

  static const _audioDraftBlob = 'audio-draft';

  Future<void> saveAudioDraft(
    List<int> bytes,
    DateTime recordedAt, {
    RecordingLocation? location,
  }) async {
    _pendingDraftPayload = bytes;
    _draftPayloadCache = bytes;
    audioDraft = {
      'recordedAt': recordedAt.toUtc().toIso8601String(),
      'payloadBytes': bytes.length,
      if (location != null) 'location': location.toJson(),
    };
    await _persistLocal();
    _notifyChanged();
  }

  Future<void> discardAudioDraft() async {
    audioDraft = null;
    _pendingDraftPayload = null;
    _draftPayloadCache = null;
    await _persistLocal();
    // Remove the payload only after the core no longer refers to it.
    final key = _localVaultKey;
    if (key != null && _localStore != null) {
      final operation = _storageTail.then(
        (_) => _chunks.deleteBlob(key, _audioDraftBlob),
      );
      _storageTail = operation.catchError((Object _) {});
      await operation;
    }
    _notifyChanged();
  }

  /// The pending recording's WAV bytes, read and decrypted on demand (the core
  /// record holds only its metadata). Null when there is no draft or its stored
  /// payload does not match the core.
  Future<List<int>?> loadAudioDraftPayload() async {
    final draft = audioDraft;
    if (draft == null) return null;
    final cached = _draftPayloadCache;
    if (cached != null) return cached;
    final key = _localVaultKey;
    if (key == null) return null;
    await _storageTail;
    final nonce = draft['payloadNonce'] as String?;
    final record = await _chunks.readBlob(key, _audioDraftBlob);
    if (nonce == null || record == null || record['nonce'] != nonce) {
      return null;
    }
    final plain = await _crypto.decryptJson(
      cipherText: record['cipherText'] as String,
      nonce: nonce,
      background: true,
    );
    return _draftPayloadCache = base64Decode(plain['payload'] as String);
  }

  /// Stores the title/people chosen for the pending recording with the draft so
  /// they survive navigation, restarts and lock/unlock. Only the core is
  /// rewritten, never the audio.
  Future<void> updateAudioDraftDetails({
    String? title,
    List<String>? participantNames,
    List<String>? participantIds,
    RecordingLocation? location,
    bool clearLocation = false,
    bool? detailsPrompted,
  }) async {
    final draft = audioDraft;
    if (draft == null) return;
    audioDraft = {
      ...draft,
      'title': ?title,
      'participantNames': ?participantNames,
      'participantIds': ?participantIds,
      if (location != null) 'location': location.toJson(),
      'detailsPrompted': ?detailsPrompted,
    };
    if (clearLocation) audioDraft!.remove('location');
    await _persistLocal();
    _notifyChanged();
  }

  Future<void> _persistLocal() async {
    final key = _localVaultKey;
    if (_localStore == null || key == null || session == null) return;
    final operation = _storageTail.then((_) => _writeVault(key));
    _storageTail = operation.catchError((Object _) {});
    await operation;
  }

  /// Encrypts and writes the core record plus only the chunks that contain a
  /// conversation changed since the last successful save.
  ///
  /// Saving existing chunks is two-phase so that a crash at any point still
  /// loads without a re-download: (1) write a core that keeps the current
  /// `chunkNonces` and the previous cursor and chunk counts, and lists the new
  /// nonces as `pendingChunkNonces`; (2) write the chunk files; (3) write the
  /// final core. A chunk is valid when its nonce equals `chunkNonces[n]` or a
  /// pending one. A chunk newer than the core's cursor is safe: sync re-applies
  /// the same entities idempotently (they replace conversations by id).
  Future<void> _writeVault(String key) async {
    final auth = session;
    if (_localStore == null ||
        auth == null ||
        _localVaultKey != key ||
        !_crypto.isUnlocked) {
      return;
    }
    await _prepareSearchIndex(complete: false);
    final payload = _pendingDraftPayload;
    if (payload != null && audioDraft != null) {
      // The audio goes into its own encrypted record before any core refers to
      // it, so core-only saves never re-encrypt it.
      final sealed = await _crypto.encryptJson({
        'payload': base64Encode(payload),
      }, background: true);
      await _chunks.writeBlob(key, _audioDraftBlob, {
        'cipherText': sealed.cipherText,
        'nonce': sealed.nonce,
      });
      if (identical(_pendingDraftPayload, payload) && audioDraft != null) {
        audioDraft = {...audioDraft!, 'payloadNonce': sealed.nonce};
        _pendingDraftPayload = null;
      }
    }
    final captured = _dirtyRevision;
    var chunkCount = _chunkCount;
    var rewriteAll = false;
    final desired = vaultChunkCountFor(conversations.length);
    // Chosen at the first v2 write; regrown (full rewrite) only if the vault
    // outgrew its layout fourfold.
    final migrateFrom = _chunkMigrationFrom;
    if (chunkCount == 0 || desired >= chunkCount * 4) {
      chunkCount = desired;
      rewriteAll = true;
    } else if (migrateFrom != null) {
      rewriteAll = true;
    }
    final conversationCounts = List<int>.filled(chunkCount, 0);
    final messageCounts = List<int>.filled(chunkCount, 0);
    for (final conversation in conversations) {
      final n = vaultChunkFor(conversation.id, chunkCount);
      conversationCounts[n]++;
      messageCounts[n] += conversation.segmentCount;
    }
    final dirty = rewriteAll
        ? {for (var n = 0; n < chunkCount; n++) n}
        : {
            for (final id in _dirtyConversations.keys)
              vaultChunkFor(id, chunkCount),
            // Safety net for code that changed the list without marking it.
            for (var n = 0; n < chunkCount; n++)
              if (n >= _chunkConversationCounts.length ||
                  _chunkConversationCounts[n] != conversationCounts[n])
                n,
          };
    if (rewriteAll) {
      await _loadAllConversations();
    } else {
      for (final n in dirty) {
        await _loadConversationChunk(n);
      }
    }
    if (_searchSnapshotNonce == null ||
        _savedSearchRevision != _searchRevision) {
      try {
        await _writeSearchCache(key);
      } catch (_) {
        // A cache failure must not prevent saving the outbox and original data.
        _searchSnapshotNonce = null;
        _savedSearchRevision = -1;
      }
    }
    final groups = {for (final n in dirty) n: <Conversation>[]};
    for (final conversation in conversations) {
      groups[vaultChunkFor(conversation.id, chunkCount)]?.add(conversation);
    }
    final coreSnapshot = _coreSnapshot(
      auth,
      chunkCount,
      conversationCounts,
      messageCounts,
    );
    final twoPhase =
        !rewriteAll &&
        dirty.isNotEmpty &&
        _chunkNonces.length == chunkCount &&
        _chunkConversationCounts.length == chunkCount &&
        _chunkMessageCounts.length == chunkCount;
    // The phase-1 core describes the chunks still on disk: old cursor/counts.
    final phaseOneSnapshot = twoPhase
        ? _coreSnapshot(
            auth,
            chunkCount,
            _chunkConversationCounts,
            _chunkMessageCounts,
            cursor: _savedCursor,
          )
        : null;
    final order = dirty.toList()..sort();
    final payloads = <int, EncryptedPayload>{};
    EncryptedPayload? corePayload;
    EncryptedPayload? phaseOnePayload;
    final tasks = <Future<void> Function()>[
      () async {
        corePayload = await _crypto.encryptJson(coreSnapshot, background: true);
      },
      if (phaseOneSnapshot != null)
        () async {
          phaseOnePayload = await _crypto.encryptJson(
            phaseOneSnapshot,
            background: true,
          );
        },
      for (final n in order)
        () async {
          payloads[n] = await _crypto.encryptJson({
            'conversations': groups[n],
          }, background: true);
        },
    ];
    var nextTask = 0;
    Future<void> lane() async {
      while (nextTask < tasks.length) {
        await tasks[nextTask++]();
      }
    }

    await Future.wait([
      for (var i = 0; i < math.min(vaultWorkerCount(), tasks.length); i++)
        lane(),
    ]);
    final nonces = [
      for (var n = 0; n < chunkCount; n++)
        payloads[n]?.nonce ??
            (n < _chunkNonces.length ? _chunkNonces[n] : null),
    ];
    final core = corePayload!;
    Map<String, dynamic> coreRecord(
      EncryptedPayload payload,
      List<String?> chunkNonces, [
      Map<String, Object>? pending,
    ]) => {
      'vaultSalt': auth.vaultSalt,
      'format': 2,
      'chunkStorage': _chunks.kind,
      'cipherText': payload.cipherText,
      'nonce': payload.nonce,
      'chunkCount': chunkCount,
      'chunkNonces': chunkNonces,
      if (pending != null && pending.isNotEmpty) 'pendingChunkNonces': pending,
    };
    if (twoPhase) {
      for (final n in order) {
        (_unconfirmedChunkNonces[n] ??= []).add(payloads[n]!.nonce);
      }
      await _localStore!.write(
        key,
        coreRecord(phaseOnePayload!, _chunkNonces, {
          for (final entry in _unconfirmedChunkNonces.entries)
            '${entry.key}': entry.value.length == 1
                ? entry.value.single
                : entry.value,
        }),
      );
    }
    // Chunk files (atomic per file, errors thrown), then the final core, which
    // keeps its explicit database compaction.
    if (order.isNotEmpty) {
      await _chunks.writeChunks(key, {
        for (final n in order)
          n: {
            'cipherText': payloads[n]!.cipherText,
            'nonce': payloads[n]!.nonce,
          },
      });
    }
    await _localStore!.write(key, coreRecord(core, nonces));
    _unconfirmedChunkNonces.clear();
    if (migrateFrom != null) {
      // The chunks now live in the new store and the core points at them.
      try {
        await SembastVaultChunkStore(
          _localStore!,
        ).deleteChunks(key, [for (var n = 0; n < migrateFrom; n++) n]);
      } catch (_) {
        // Orphaned old records are harmless; the migration itself succeeded.
      }
      _chunkMigrationFrom = null;
    }
    _chunkCount = chunkCount;
    _chunkNonces = nonces;
    _chunkConversationCounts = conversationCounts;
    _chunkMessageCounts = messageCounts;
    _savedCursor = coreSnapshot['cursor'] as int;
    _dirtyConversations.removeWhere((_, revision) => revision <= captured);
    _snapshotWriteRevision++;
  }
}

class _IncompleteChunks implements Exception {
  const _IncompleteChunks();
}

class _RestoreProgress {
  _RestoreProgress({required this.messages, required this.conversations});
  final int messages;
  final int conversations;
  int restoredMessages = 0;
}
