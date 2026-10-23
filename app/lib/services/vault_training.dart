part of '../app_state.dart';

extension VaultTraining on LifenizerAppState {
  Future<void> _cacheCorrectionAudio(
    String conversationId,
    List<int> bytes,
  ) async {
    final vault = _localVaultKey;
    if (vault == null) return;
    final payload = await _crypto.encryptJson({
      'vaultKey': vault,
      'conversationId': conversationId,
      'bytes': base64Encode(bytes),
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

  Future<bool> submitTranscriptionCorrection({
    required Conversation conversation,
    required ConversationSegment segment,
    required String correctedText,
    required bool acceptTerms,
    required String consentVersion,
    List<int>? audioOverride,
  }) async {
    var submitted = false;
    await _run(() async {
      if (!isAuthenticated) throw StateError('Unlock the vault first.');
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
      String? savedAudio;
      if (audioOverride == null) {
        final saved = await audio_cache.readAudioCache(
          '$_localVaultKey:audio:${current.id}',
        );
        if (saved == null) {
          throw StateError(
            'Original audio is not available on this device. Attach the original WAV recording.',
          );
        }
        final value = await _crypto.decryptJson(
          cipherText: saved['cipherText'] as String,
          nonce: saved['nonce'] as String,
          background: true,
        );
        if (value['vaultKey'] != _localVaultKey ||
            value['conversationId'] != current.id) {
          throw StateError(
            'The original recording does not belong to this conversation.',
          );
        }
        savedAudio = value['bytes'] as String;
      }
      final nextStart = index + 1 < current.segments.length
          ? current.segments[index + 1].offsetMs
          : null;
      if (segment.endMs == null &&
          nextStart != null &&
          nextStart <= segment.offsetMs) {
        throw StateError(
          'This sentence has no usable audio end timestamp. Re-transcribe the original recording before contributing it.',
        );
      }
      final end = segment.endMs ?? nextStart;
      final clip = await compute(_trainingClip, (
        audioOverride,
        savedAudio,
        segment.offsetMs,
        end,
      ), debugLabel: 'training-audio-clip');
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
      final result = await _requireApi().submitTabCorrection({
        'contributionKey': key,
        'consentId': receipt['id'],
        'payloadBase64': base64Encode(clip),
        'originalText': segment.text,
        'correctedText': correctedText.trim(),
      });
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
      conversations[conversations.indexOf(current)] = updated;
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

Uint8List _trainingClip((List<int>?, String?, int, int?) input) => clipWav(
  input.$1 ?? base64Decode(input.$2!),
  startMs: input.$3,
  endMs: input.$4,
);
