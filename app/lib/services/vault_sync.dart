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
        await _crypto.unlock(
          email: normalizedEmail,
          passphrase: passphrase,
          vaultSalt: auth?.vaultSalt ?? local!['vaultSalt'] as String,
        );
        _clearVault();
        if (local != null) {
          final snapshot = await _crypto.decryptJson(
            cipherText: local['cipherText'] as String,
            nonce: local['nonce'] as String,
          );
          _restoreSnapshot(snapshot);
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
        await _persistLocal();
        await _localStore!.write('settings', {
          'apiBaseUrl': apiBaseUrl,
          'email': rememberedEmail,
          'deviceId': deviceId,
        });
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
    conversations.clear();
    relations.clear();
    savedSearches.clear();
    images.clear();
    importCapabilities.clear();
    quotaStatus = null;
    audioDraft = null;
    _pendingSync.clear();
    syncCursor = 0;
    syncError = null;
    lastSyncedAt = null;
    _searchIndex = null;
    _markSearchIndexDirty();
    _lastSearchQuery = null;
    _lastSearchAt = null;
    _lastSearchTopConversationIds = const [];
    _sessionQueryFrequency.clear();
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

  Future<void> _syncNow() async {
    final api = _requireApi();
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
      await api.push(batch);
      final acknowledged = batch.map((e) => e.id).toSet();
      _pendingSync.removeWhere((e) => acknowledged.contains(e.id));
    }
    while (true) {
      final pulled = await api.pull(syncCursor);
      final decoded = <Map<String, dynamic>>[];
      for (final envelope in pulled.envelopes) {
        decoded.add(
          await _crypto.decryptJson(
            cipherText: envelope.cipherText,
            nonce: envelope.nonce,
          ),
        );
      }
      for (var i = 0; i < pulled.envelopes.length; i++) {
        final envelope = pulled.envelopes[i];
        if (_pendingSync.any(
          (pending) =>
              pending.entityType == envelope.entityType &&
              pending.entityId == envelope.entityId,
        )) {
          continue;
        }
        _applyEntity(envelope.entityType, decoded[i]);
      }
      final advanced = pulled.cursor > syncCursor;
      syncCursor = pulled.cursor;
      await _persistLocal();
      if (pulled.envelopes.length < 500 || !advanced) break;
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
    if (_vaultBatchDepth > 0) return;
    await _flushVaultChanges();
  }

  /// Save related edits together before publishing them. If parsing fails,
  /// completed edits still enter the encrypted outbox and can be retried.
  Future<T> batchVaultChanges<T>(Future<T> Function() action) async {
    if (_vaultBatchDepth == 0) await _syncInFlight;
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
    'participants': participants.map((e) => e.toJson()).toList(),
    'conversations': conversations.map((e) => e.toJson()).toList(),
    'relations': relations.map((e) => e.toJson()).toList(),
    'savedSearches': savedSearches.map((e) => e.toJson()).toList(),
    'pending': _pendingSync.map((e) => e.toJson()).toList(),
    if (audioDraft != null) 'audioDraft': audioDraft,
  };

  void _restoreSnapshot(Map<String, dynamic> json) {
    audioDraft = json['audioDraft'] == null
        ? null
        : Map<String, dynamic>.from(json['audioDraft']);
    session = AuthSession.fromJson(Map<String, dynamic>.from(json['session']));
    syncCursor = json['cursor'] as int;
    participants.addAll(
      json.parseObjectList('participants', Participant.fromJson),
    );
    conversations.addAll(
      json.parseObjectList('conversations', Conversation.fromJson),
    );
    relations.addAll(json.parseObjectList('relations', RelationEdge.fromJson));
    savedSearches.addAll(
      json.parseObjectList('savedSearches', SavedSearch.fromJson),
    );
    _pendingSync.addAll(json.parseObjectList('pending', SyncEnvelope.fromJson));
    _markSearchIndexDirty();
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
      final payload = await _crypto.encryptJson(snapshot);
      await _localStore!.write(key, {
        'vaultSalt': auth.vaultSalt,
        'cipherText': payload.cipherText,
        'nonce': payload.nonce,
      });
    });
    _storageTail = operation.catchError((Object _) {});
    await operation;
  }
}
