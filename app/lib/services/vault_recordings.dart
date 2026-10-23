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

  RecordingAudio _decodeRecording(
    Map<String, dynamic> value,
    String id, {
    required bool local,
  }) {
    if (value['conversationId'] != id ||
        (local
            ? value['vaultKey'] != _localVaultKey
            : value['vaultId'] != session?.vaultId)) {
      throw StateError(
        'The recording does not belong to this vault and conversation.',
      );
    }
    final bytes = base64Decode(value['bytes'] as String);
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
    final audio = _decodeRecording(value, id, local: false);
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
              participantIds: await ensureParticipants(
                (draft['participantNames'] as List? ?? const []).join(','),
              ),
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

  /// Online persistence is opt-in; the relay never enables it.
  Future<void> setRecordingOnlineSync(String id, bool enabled) async {
    if (busy) throw StateError('Wait for the current vault operation.');
    final api = _requireApi();
    final identity = recordingIdentity;
    _checkRecordingSession(api, identity);
    if (!_knownRecording(id)) {
      throw StateError('Recording not found in this vault.');
    }
    await _run(() async {
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
    });
    if (error != null) throw StateError(error!);
  }
}
