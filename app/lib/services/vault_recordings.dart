part of '../app_state.dart';

class RecordingAudio {
  RecordingAudio({
    required List<int> bytes,
    this.contentType = 'audio/wav',
    this.fileName = 'recording.wav',
  }) : bytes = Uint8List.fromList(bytes);
  final Uint8List bytes;
  final String contentType;
  final String fileName;
}

extension VaultRecordings on LifenizerAppState {
  /// Changes with the account, server, vault or locked state.
  String? get recordingIdentity => isAuthenticated && session != null
      ? jsonEncode([apiBaseUrl, session!.userId, session!.vaultId])
      : null;

  LifenizerApiClient get recordingApi => _requireApi();

  void _checkRecordingSession(LifenizerApiClient api, String? identity) {
    if (identity == null ||
        recordingIdentity != identity ||
        !identical(_api, api) ||
        _disposed) {
      throw StateError('The vault changed while loading the recording.');
    }
  }

  bool _knownRecording(String id) =>
      conversations.any((c) => c.id == id && c.source == 'audio');

  Future<RecordingAudio> _decodeRecording(
    Map<String, dynamic> value,
    String id, {
    required bool local,
  }) async {
    if (value['conversationId'] != id ||
        (local
            ? value['vaultKey'] != _localVaultKey
            : value['vaultId'] != session?.vaultId)) {
      throw StateError(
        'The recording does not belong to this vault and conversation.',
      );
    }
    final bytes = await base64DecodeInWorker(value['bytes'] as String);
    if (bytes.isEmpty) throw StateError('The recording is empty.');
    return RecordingAudio(
      bytes: bytes,
      contentType: value['contentType'] as String? ?? 'audio/wav',
      fileName: value['fileName'] as String? ?? 'recording.wav',
    );
  }

  Future<RecordingAudio?> _localRecordingAudio(
    String id,
    LifenizerApiClient api,
    String identity,
  ) async {
    final saved = await audio_cache.readAudioCache('$_localVaultKey:audio:$id');
    _checkRecordingSession(api, identity);
    if (saved == null) return null;
    final value = await _crypto.decryptJson(
      cipherText: saved['cipherText'] as String,
      nonce: saved['nonce'] as String,
      background: true,
    );
    _checkRecordingSession(api, identity);
    return _decodeRecording(value, id, local: true);
  }

  /// Uses the encrypted local cache first, then online storage or a live peer.
  Future<RecordingAudio> loadRecordingAudio(String id) async {
    final api = _requireApi();
    final identity = recordingIdentity;
    _checkRecordingSession(api, identity);
    if (!_knownRecording(id)) {
      throw StateError('Recording not found in this vault.');
    }
    final local = await _localRecordingAudio(id, api, identity!);
    if (local != null) return local;
    final encrypted = await api.getRecording(id);
    _checkRecordingSession(api, identity);
    if (encrypted['keyId'] != VaultCrypto.keyId) {
      throw StateError('Unsupported recording encryption key.');
    }
    final value = await _crypto.decryptJson(
      cipherText: encrypted['cipherText'] as String,
      nonce: encrypted['nonce'] as String,
      background: true,
    );
    _checkRecordingSession(api, identity);
    final audio = await _decodeRecording(value, id, local: false);
    await _cacheCorrectionAudio(
      id,
      audio.bytes,
      contentType: audio.contentType,
      fileName: audio.fileName,
    );
    _checkRecordingSession(api, identity);
    return audio;
  }

  Future<Map<String, dynamic>> _sealRecording(
    String id,
    RecordingAudio audio,
  ) async {
    final encrypted = await _crypto.encryptJson({
      'vaultId': session!.vaultId,
      'conversationId': id,
      'bytes': base64Encode(audio.bytes),
      'contentType': audio.contentType,
      'fileName': audio.fileName,
    }, background: true);
    return {
      'cipherText': encrypted.cipherText,
      'nonce': encrypted.nonce,
      'keyId': encrypted.keyId,
    };
  }

  /// A provider only serves known recordings already cached on this device.
  Future<Map<String, dynamic>?> encryptedRecordingForRelay(String id) async {
    final api = _requireApi();
    final identity = recordingIdentity;
    _checkRecordingSession(api, identity);
    if (!_knownRecording(id)) return null;
    final audio = await _localRecordingAudio(id, api, identity!);
    if (audio == null) return null;
    final encrypted = await _sealRecording(id, audio);
    _checkRecordingSession(api, identity);
    return encrypted;
  }

  /// Acknowledges a service capture only after both audio and metadata persist.
  Future<void> _importPendingRecording(
    List<int> bytes,
    DateTime recordedAt,
    String captureId, {
    RecordingLocation? location,
  }) async {
    if (busy) throw StateError('Wait for the current vault operation.');
    if (bytes.isEmpty || captureId.isEmpty) {
      throw StateError('The recording is empty.');
    }
    final api = _requireApi();
    final identity = recordingIdentity;
    _checkRecordingSession(api, identity);
    if (_localVaultKey == null) throw StateError('No local vault is open.');
    await _run(() async {
      final id = _uuid.v5(
        Namespace.url.value,
        'lifenizer:capture:${session!.vaultId}:$captureId',
      );
      await _cacheCorrectionAudio(id, bytes);
      _checkRecordingSession(api, identity);
      final existing = conversations.where((c) => c.id == id).firstOrNull;
      final conversation = existing == null
          ? Conversation(
              id: id,
              title: 'Voice recording',
              source: 'audio',
              location: location,
              participantIds: [],
              segments: [],
              artifactNames: ['recording.wav'],
              startedAt: recordedAt,
              endedAt: recordedAt,
            )
          : await loadConversation(id);
      _checkRecordingSession(api, identity);
      if (existing == null) conversations.add(conversation);
      _markConversationChanged(id);
      // Also persist on retry: a previous write may have failed after updating
      // memory, or completed before Android acknowledged the capture.
      await _pushEntity('conversation', id, conversation.toJson());
      _checkRecordingSession(api, identity);
      status = 'Recording saved encrypted and added to search.';
    });
    if (error != null) throw StateError(error!);
  }

  /// Transcription is explicit because it sends audio to the configured server.
  Future<void> _transcribeRecording(String id) async {
    if (busy) throw StateError('Wait for the current vault operation.');
    final api = _requireApi();
    final identity = recordingIdentity;
    _checkRecordingSession(api, identity);
    final conversation = await loadConversation(id);
    if (conversation.source != 'audio' || conversation.segments.isNotEmpty) {
      throw StateError('Choose a recording without a transcript.');
    }
    final audio = await loadRecordingAudio(id);
    _checkRecordingSession(api, identity);
    if (busy) throw StateError('Wait for the current vault operation.');
    await importAudioBytes(
      bytes: audio.bytes,
      fileName: audio.fileName,
      mimeType: audio.contentType,
      title: conversation.title,
      participantNames: conversation.participantIds
          .map(participantName)
          .join(','),
      participantIds: conversation.participantIds,
      location: conversation.location,
      recordedAt: conversation.startedAt,
      recordingId: id,
    );
    if (error != null) throw StateError(error!);
  }

  /// Keeps a pending microphone recording without requiring transcription.
  Future<bool> retainAudioDraft() async {
    var retained = false;
    await _run(() async {
      final api = _requireApi();
      final identity = recordingIdentity;
      _checkRecordingSession(api, identity);
      final draft = audioDraft;
      if (draft == null || _localVaultKey == null) {
        throw StateError('No pending recording is available.');
      }
      final bytes = await loadAudioDraftPayload();
      _checkRecordingSession(api, identity);
      if (bytes == null || bytes.isEmpty) {
        throw StateError('The recording is empty.');
      }
      final recordedAt = DateTime.parse(draft['recordedAt'] as String);
      final id = _uuid.v5(
        Namespace.url.value,
        'lifenizer:recording:${session!.vaultId}:${draft['recordedAt']}:${draft['payloadNonce']}',
      );
      await _cacheCorrectionAudio(id, bytes);
      _checkRecordingSession(api, identity);
      final existing = conversations.where((c) => c.id == id).firstOrNull;
      final conversation = existing == null
          ? Conversation(
              id: id,
              title: (draft['title'] as String?)?.trim().isNotEmpty == true
                  ? (draft['title'] as String).trim()
                  : 'Voice recording',
              source: 'audio',
              participantIds: await ensureParticipantSelection(
                (draft['participantNames'] as List? ?? const []).join(','),
                (draft['participantIds'] as List? ?? const []).cast<String>(),
              ),
              location: draft['location'] is Map
                  ? RecordingLocation.fromJson(
                      Map<String, dynamic>.from(draft['location'] as Map),
                    )
                  : null,
              segments: [],
              artifactNames: ['recording.wav'],
              startedAt: recordedAt,
              endedAt: recordedAt,
            )
          : await loadConversation(id);
      _checkRecordingSession(api, identity);
      if (existing == null) conversations.add(conversation);
      _markConversationChanged(id);
      await _pushEntity('conversation', id, conversation.toJson());
      _checkRecordingSession(api, identity);
      final pending = _pendingDraftPayload;
      final cached = _draftPayloadCache;
      try {
        await discardAudioDraft();
      } catch (_) {
        audioDraft = draft;
        _pendingDraftPayload = pending;
        _draftPayloadCache = cached;
        rethrow;
      }
      retained = true;
      status = 'Recording saved encrypted; transcription is optional.';
    });
    return retained;
  }

  /// Updates searchable context without changing the recording or transcript.
  Future<bool> updateRecordingDetails(
    String id, {
    required String title,
    required String participantNames,
    required List<String> participantIds,
    RecordingLocation? location,
    String? expectedIdentity,
  }) async {
    var saved = false;
    await _run(() async {
      if (expectedIdentity != null && recordingIdentity != expectedIdentity) {
        throw StateError(
          'The library changed. Reopen the original recording to edit its details.',
        );
      }
      final api = _requireApi();
      final identity = recordingIdentity;
      final current = await loadConversation(id);
      _checkRecordingSession(api, identity);
      if (current.source != 'audio') {
        throw StateError('Choose an audio recording.');
      }
      final people = await ensureParticipantSelection(
        participantNames,
        participantIds,
      );
      _checkRecordingSession(api, identity);
      final updated = Conversation.fromJson({
        ...current.toJson(),
        'title': title.trim().isEmpty ? current.title : title.trim(),
        'participantIds': people,
        'location': location?.toJson(),
      });
      conversations[conversations.indexWhere((c) => c.id == id)] = updated;
      _markConversationChanged(id);
      await _pushEntity('conversation', id, updated.toJson());
      saved = true;
    });
    return saved;
  }

  /// A device-local request waiting for confirmed online storage or removal.
  bool? pendingRecordingOnlineSync(String id) => _pendingRecordingSync[id];

  /// Saves opt-in intent locally; transfer and retries run in background sync.
  Future<void> setRecordingOnlineSync(String id, bool enabled) async {
    if (busy) throw StateError('Wait for the current vault operation.');
    final api = _requireApi();
    final identity = recordingIdentity;
    _checkRecordingSession(api, identity);
    if (!_knownRecording(id)) {
      throw StateError('Recording not found in this vault.');
    }
    await _run(() async {
      _checkRecordingSession(api, identity);
      _pendingRecordingSync[id] = enabled;
      await _persistLocal();
    }, prepareIndex: false);
    if (error != null) throw StateError(error!);
    unawaited(() async {
      if (_syncInFlight != null) {
        try {
          await _syncInFlight;
        } catch (_) {
          // A preceding offline sync must not drop the newly saved request.
        }
      }
      if (!_disposed && recordingIdentity == identity && identical(_api, api)) {
        await syncQuietly();
      }
    }());
  }

  Future<bool> _retryRecordingSync() async {
    final pending = _pendingRecordingSync.entries.toList();
    Object? failure;
    for (final entry in pending) {
      if (_pendingRecordingSync[entry.key] != entry.value) continue;
      try {
        await _syncRecording(entry.key, entry.value);
      } catch (exception) {
        failure ??= exception;
      }
    }
    if (failure != null) throw failure;
    if (pending.isNotEmpty) syncError = null;
    return pending.isNotEmpty;
  }

  Future<void> _syncRecording(String id, bool enabled) async {
    final api = _requireApi();
    final identity = recordingIdentity;
    _checkRecordingSession(api, identity);
    if (enabled) {
      final audio = await loadRecordingAudio(id);
      _checkRecordingSession(api, identity);
      final encrypted = await _sealRecording(id, audio);
      _checkRecordingSession(api, identity);
      await api.putRecording(id, encrypted);
    } else {
      await api.deleteRecording(id);
    }
    _checkRecordingSession(api, identity);
    final current = await loadConversation(id);
    _checkRecordingSession(api, identity);
    final updated = Conversation.fromJson({
      ...current.toJson(),
      'metadata': {...current.metadata, 'recordingSync': '$enabled'},
    });
    conversations[conversations.indexOf(current)] = updated;
    _markConversationChanged(id);
    await _pushEntity('conversation', id, updated.toJson());
    _checkRecordingSession(api, identity);
    if (_pendingRecordingSync[id] == enabled) _pendingRecordingSync.remove(id);
    await _persistLocal();
    _notifyChanged();
  }
}
