part of '../app_state.dart';

extension VaultTraining on LifenizerAppState {
  Future<void> _cacheCorrectionAudio(
    String conversationId,
    List<int> bytes, {
    String contentType = 'audio/wav',
    String fileName = 'recording.wav',
  }) async {
    final vault = _localVaultKey;
    if (vault == null) return;
    final encoded = await base64EncodeInWorker(bytes);
    final payload = await _crypto.encryptJson({
      'vaultKey': vault,
      'vaultId': session?.vaultId,
      'contentType': contentType,
      'fileName': fileName,
      'conversationId': conversationId,
      'bytes': encoded,
    }, background: true);
    await audio_cache.writeAudioCache('$vault:audio:$conversationId', {
      'cipherText': payload.cipherText,
      'nonce': payload.nonce,
    });
  }

  Future<Map<String, dynamic>> tabTrainingNotice() {
    if (!isAuthenticated) throw StateError('Unlock the vault first.');
    return _requireApi().tabTrainingNotice();
  }

  Future<Map<String, dynamic>?> tabTrainingConsent() async {
    if (!isAuthenticated) throw StateError('Unlock the vault first.');
    final value = await _localStore!.read('$_localVaultKey:tab-training');
    if (value == null) return null;
    return _crypto.decryptJson(
      cipherText: value['cipherText'] as String,
      nonce: value['nonce'] as String,
    );
  }

  Future<void> _saveTrainingConsent(Map<String, dynamic> value) async {
    final payload = await _crypto.encryptJson(value);
    await _localStore!.write('$_localVaultKey:tab-training', {
      'cipherText': payload.cipherText,
      'nonce': payload.nonce,
    });
  }

  /// Loads only the selected sentence for both replay and contribution.
  Future<RecordingAudio> loadTranscriptionSentence({
    required Conversation conversation,
    required ConversationSegment segment,
    List<int>? audioOverride,
  }) async {
    final index = conversation.segments.indexWhere(
      (item) => item.id == segment.id,
    );
    if (conversation.source != 'audio' || index < 0) {
      throw StateError('Select a sentence from this recording.');
    }
    final nextStart = index + 1 < conversation.segments.length
        ? conversation.segments[index + 1].offsetMs
        : null;
    if (segment.endMs == null &&
        nextStart != null &&
        nextStart <= segment.offsetMs) {
      throw StateError(
        'This sentence has no usable audio end timestamp. Re-transcribe the original recording or record a replacement sentence.',
      );
    }
    final bytes =
        audioOverride ?? (await loadRecordingAudio(conversation.id)).bytes;
    return RecordingAudio(
      bytes: await compute(_trainingClip, (
        bytes,
        segment.offsetMs,
        segment.endMs ?? nextStart,
      )),
      fileName: 'sentence.wav',
    );
  }

  Future<bool> submitTranscriptionCorrection({
    required Conversation conversation,
    required ConversationSegment segment,
    required String correctedText,
    required bool acceptTerms,
    required String consentVersion,
    List<int>? audioOverride,
    ({List<int> audio, String text})? replacement,
  }) async {
    var submitted = false;
    await _run(() async {
      if (!isAuthenticated) throw StateError('Unlock the vault first.');
      final api = _requireApi();
      final identity = recordingIdentity;
      try {
        await _syncInFlight;
      } catch (_) {}
      final current = await loadConversation(conversation.id);
      final index = current.segments.indexWhere(
        (item) => item.id == segment.id,
      );
      if (current.source != 'audio' ||
          index < 0 ||
          correctedText.trim().isEmpty ||
          correctedText.trim() == segment.text.trim()) {
        throw ArgumentError('Enter a corrected audio transcription.');
      }
      if (current.segments[index].text != segment.text ||
          current.segments[index].offsetMs != segment.offsetMs ||
          current.segments[index].endMs != segment.endMs) {
        throw StateError(
          'This transcript changed. Reopen the sentence before correcting it.',
        );
      }
      if (replacement != null && replacement.text.trim().isEmpty) {
        throw ArgumentError('Enter the sentence you recorded.');
      }
      final clip = replacement == null
          ? (await loadTranscriptionSentence(
              conversation: current,
              segment: segment,
              audioOverride: audioOverride,
            )).bytes
          : await compute(_trainingClip, (replacement.audio, 0, null));
      _checkRecordingSession(api, identity);
      var consent = await tabTrainingConsent();
      var receipts = (consent?['receipts'] as List? ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      var receipt = receipts.lastOrNull;
      final key =
          consent?['contributionKey'] as String? ?? await _newContributionKey();
      if (receipt == null ||
          receipt['version'] != consentVersion ||
          ((receipt['purposes'] as int? ?? 0) & 4) == 0) {
        if (!acceptTerms) {
          throw StateError(
            'Accept the current TAB training notice before sharing this sentence.',
          );
        }
        receipt = await _requireApi().grantTabTrainingConsent({
          'contributionKey': key,
          'version': consentVersion,
          'acceptTerms': true,
        });
        receipts.add({...receipt, 'version': consentVersion});
        consent = {'contributionKey': key, 'receipts': receipts};
        await _saveTrainingConsent(consent);
      }
      _checkRecordingSession(api, identity);
      final result = await api.submitTabCorrection({
        'contributionKey': key,
        'consentId': receipt['id'],
        'payloadBase64': base64Encode(clip),
        'originalText': replacement == null ? segment.text : '',
        'correctedText': replacement?.text.trim() ?? correctedText.trim(),
        if (replacement != null) 'isReplacement': true,
      });
      _checkRecordingSession(api, identity);
      final segments = [...current.segments];
      segments[index] = ConversationSegment.fromJson({
        ...segments[index].toJson(),
        'text': correctedText.trim(),
      });
      final updated = Conversation.fromJson({
        ...current.toJson(),
        'segments': segments.map((segment) => segment.toJson()).toList(),
        'metadata': {
          ...current.metadata,
          'tabSubmission:${segment.id}': jsonEncode({
            ...result,
            'originalText': segment.text,
            'submittedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        },
      });
      final position = conversations.indexWhere(
        (item) => item.id == current.id,
      );
      if (position < 0) {
        throw StateError('This recording is no longer available.');
      }
      conversations[position] = updated;
      _markConversationChanged(updated.id);
      await _pushEntity('conversation', updated.id, updated.toJson());
      submitted = true;
      status =
          'Sentence submitted to TAB for validation and training · ${result['audioId'] ?? result['id']}';
    });
    return submitted;
  }

  Future<bool> withdrawTabTrainingConsent() async {
    var withdrawn = false;
    await _run(() async {
      final consent = await tabTrainingConsent();
      if (consent == null) return;
      for (final raw in consent['receipts'] as List) {
        final receipt = raw as Map;
        if (((receipt['purposes'] as int? ?? 0) & 4) == 0) continue;
        await _requireApi().withdrawTabTrainingConsent(
          receipt['id'] as String,
          consent['contributionKey'] as String,
        );
        receipt['purposes'] = (receipt['purposes'] as int) & ~4;
        await _saveTrainingConsent(consent);
      }
      withdrawn = true;
      status = 'TAB training consent withdrawn';
    });
    return withdrawn;
  }

  Future<String> _newContributionKey() async {
    final key = await AesGcm.with256bits().newSecretKey();
    try {
      return (await key.extractBytes())
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
    } finally {
      key.destroy();
    }
  }
}

Uint8List _trainingClip((List<int>, int, int?) input) =>
    clipWav(input.$1, startMs: input.$2, endMs: input.$3);
