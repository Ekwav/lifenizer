part of '../app_state.dart';

extension VaultSync on LifenizerAppState {
  Future<void> initialize() async {
    _localStore ??= await LocalVaultStore.open();
    final settings = await _localStore!.read('settings');
    if (settings == null) return;
    apiBaseUrl = settings['apiBaseUrl'] as String? ?? apiBaseUrl;
    rememberedEmail = settings['email'] as String? ?? '';
    deviceId = settings['deviceId'] as String? ?? deviceId;
  }

  Future<void> login({
    required String baseUrl,
    required String email,
    required String passphrase,
    String? password,
    bool register = false,
    String? registrationToken,
    bool offline = false,
    AuthSession? pairedSession,
  }) async {
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
        await _crypto.unlock(
          email: normalizedEmail,
          passphrase: passphrase,
          vaultSalt: auth?.vaultSalt ?? local!['vaultSalt'] as String,
          background: true,
        );
        _clearVault();
        var repaired = false;
        if (local != null) {
          _setSyncProgress(SyncStage.decryptingLocal);
          final snapshot = await _crypto.decryptJson(
            cipherText: local['cipherText'] as String,
            nonce: local['nonce'] as String,
            background: true,
          );
          repaired = await _restoreSnapshot(snapshot);
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
        if (!offline) {
          // Validate every remote ciphertext before exposing the unlocked UI.
          await _syncNow();
          if (register) {
            await _pushEntity('vault-check', current.vaultId, {
              'id': current.vaultId,
              'version': 1,
            });
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
      } catch (_) {
        _crypto.lock();
        _api = null;
        session = null;
        _clearVault();
        rethrow;
      } finally {
        _unlocking = false;
      }
    });
  }

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
    _pendingSync.clear();
    syncCursor = 0;
    syncError = null;
    _clearSyncProgress();
    lastSyncedAt = null;
    _searchIndex = null;
    _markSearchIndexDirty();
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

  Future<void> pullSync() => _run(_synchronize);

  Future<void> syncQuietly() async {
    if (!isAuthenticated || busy) return;
    try {
      await _synchronize();
    } catch (exception) {
      syncError = 'Sync paused: $exception';
      _notifyChanged();
    }
  }

  Future<void> _synchronize() async {
    if (_syncInFlight != null) return _syncInFlight;
    final operation = _syncNow();
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

  Future<void> _syncNow() async {
    try {
      await _transferSync();
      _setSyncProgress(SyncStage.complete);
    } catch (_) {
      _setSyncProgress(SyncStage.failed);
      rethrow;
    }
  }

  Future<void> _transferSync() async {
    final api = _requireApi();
    final uploadTotal = _pendingSync.length;
    var uploaded = 0;
    var downloaded = 0;
    var page = 0;
    var acknowledgedChanges = _pendingSync.isNotEmpty;
    while (_pendingSync.isNotEmpty) {
      final batch = <SyncEnvelope>[];
      var bytes = 0;
      for (final envelope in _pendingSync) {
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
        _applyEntity(envelope.entityType, decoded[i]);
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
    syncError = null;
    lastSyncedAt = DateTime.now();
    _notifyChanged();
  }

  Future<void> _pushEntity(
    String entityType,
    String entityId,
    Map<String, dynamic> json,
  ) async {
    final payload = await _crypto.encryptJson(json);
    _pendingSync.add(
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
        clientCreatedAt: DateTime.now().toUtc(),
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
    await _flushVaultChanges();
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
        await _flushVaultChanges();
      }
    }
  }

  Future<void> _flushVaultChanges() async {
    // Persist the outbox before making a network request. Retrying the same
    // envelope ID is safe even when a response is lost after server acceptance.
    await _persistLocal();
    try {
      await _synchronize();
    } catch (exception) {
      syncError = 'Saved locally; sync will retry: $exception';
    }
  }

  Map<String, dynamic> _snapshot() => {
    'session': session!.toJson(),
    'cursor': syncCursor,
    // Capture immutable records now; their JSON conversion runs in the worker.
    'participants': participants.toList(),
    'conversations': conversations.toList(),
    'relations': relations.toList(),
    'savedSearches': savedSearches.toList(),
    'pending': _pendingSync.toList(),
    if (audioDraft != null) 'audioDraft': audioDraft,
  };

  Future<bool> _restoreSnapshot(Map<String, dynamic> json) async {
    audioDraft = json['audioDraft'] == null
        ? null
        : Map<String, dynamic>.from(json['audioDraft']);
    session = AuthSession.fromJson(Map<String, dynamic>.from(json['session']));
    syncCursor = json['cursor'] as int;
    participants.addAll(
      json.parseObjectList('participants', Participant.fromJson),
    );
    _invalidateParticipantLookup();
    final rawConversations = json['conversations'] as List? ?? const [];
    final totalMessages = rawConversations.fold<int>(
      0,
      (count, raw) =>
          count + (((raw as Map)['segments'] as List?)?.length ?? 0),
    );
    var messages = 0;
    void report({bool force = false}) => _setSyncProgress(
      SyncStage.restoring,
      completed: totalMessages == 0 ? conversations.length : messages,
      total: totalMessages == 0 ? rawConversations.length : totalMessages,
      detail: totalMessages == 0 ? 'Restoring local conversations' : null,
      force: force,
    );
    report(force: true);
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
        messages++;
        if (messages % 250 == 0) {
          report();
          await Future<void>.delayed(Duration.zero);
        }
      }
      conversations.add(conversation);
      if (conversations.length % 50 == 0) {
        report();
        await Future<void>.delayed(Duration.zero);
      }
    }
    report(force: true);
    relations.addAll(json.parseObjectList('relations', RelationEdge.fromJson));
    savedSearches.addAll(
      json.parseObjectList('savedSearches', SavedSearch.fromJson),
    );
    _pendingSync.addAll(json.parseObjectList('pending', SyncEnvelope.fromJson));
    var repaired = false;
    _people;
    if (_hasParticipantRedirects) {
      for (var i = 0; i < conversations.length; i++) {
        final canonical = _canonicalConversation(conversations[i]);
        if (!identical(canonical, conversations[i])) {
          conversations[i] = canonical;
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
    _markSearchIndexDirty();
    return repaired;
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

  Future<void> saveAudioDraft(List<int> bytes, DateTime recordedAt) async {
    audioDraft = {
      'payload': base64Encode(bytes),
      'recordedAt': recordedAt.toUtc().toIso8601String(),
    };
    await _persistLocal();
    _notifyChanged();
  }

  Future<void> discardAudioDraft() async {
    audioDraft = null;
    await _persistLocal();
    _notifyChanged();
  }

  Future<void> _persistLocal() async {
    final key = _localVaultKey;
    final auth = session;
    if (_localStore == null || key == null || auth == null) return;
    final snapshot = _snapshot();
    final operation = _storageTail.then((_) async {
      final payload = await _crypto.encryptJson(snapshot, background: true);
      await _localStore!.write(key, {
        'vaultSalt': auth.vaultSalt,
        'cipherText': payload.cipherText,
        'nonce': payload.nonce,
      });
      _snapshotWriteRevision++;
    });
    _storageTail = operation.catchError((Object _) {});
    await operation;
  }
}
