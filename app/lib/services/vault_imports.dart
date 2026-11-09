part of '../app_state.dart';

/// Outcome of the latest [VaultImports.importSource] call, for panels that
/// summarize an import (for example viewing history).
class ImportSummary {
  const ImportSummary({
    required this.source,
    required this.added,
    required this.skipped,
    this.diagnostics = const {},
  });
  final String source;

  /// Conversations created or updated.
  final int added;

  /// Conversations that were already present and unchanged.
  final int skipped;
  final Map<String, String> diagnostics;
}

/// Where a transcribed recording is filed, and how its audio is labelled.
typedef _AudioImportTarget = ({
  String? recordingId,
  List<String> participantIds,
  RecordingLocation? location,
  String fileName,
  String contentType,
});

extension VaultImports on LifenizerAppState {
  Future<Map<String, dynamic>> paperlessSettings() =>
      _requireApi().paperlessSettings();

  Future<void> importSource({
    required String source,
    String? title,
    String? participantNames,
    String? text,
    String? originalFileName,
    String? mimeType,
    Map<String, String> metadata = const {},
    String? payloadBase64,
    List<String> participantIds = const [],
  }) async {
    await _run(() async {
      final api = _requireApi();
      final content = payloadBase64 == null
          ? utf8.encode(text?.trim() ?? '')
          : base64Decode(payloadBase64);
      final fingerprint = content.isEmpty
          ? null
          : base64UrlEncode(
              (await Sha256().hash([
                ...utf8.encode('$source\u0000'),
                ...content,
              ])).bytes,
            );
      status = 'Importing $source…';
      _notifyChanged();
      final normalized = await api.importSource(
        source,
        ImportSourceRequest(
          title: title?.trim().isEmpty == true ? null : title?.trim(),
          text: text?.trim().isEmpty == true ? null : text,
          originalFileName: originalFileName,
          mimeType: mimeType,
          metadata: metadata,
          participantNames: participantNames == null
              ? const []
              : participantNames
                    .split(',')
                    .map((name) => name.trim())
                    .where((name) => name.isNotEmpty)
                    .toList(),
          payloadBase64: payloadBase64,
        ),
        timeout: source == 'scanned-pdf'
            ? const Duration(minutes: 10)
            : const Duration(minutes: 2),
      );
      final added = await _ingestNormalizedImport(
        normalized,
        fingerprint: fingerprint,
        selectedParticipantIds: participantIds,
      );
      final skipped = normalized.conversations.length - added;
      lastImportSummary = ImportSummary(
        source: source,
        added: added,
        skipped: skipped,
        diagnostics: normalized.diagnostics,
      );
      status = added == 0 && skipped > 0
          ? 'Already imported · $skipped conversation(s) skipped ($source)'
          : 'Imported $added conversation(s) from $source · saved encrypted'
                '${skipped > 0 ? ' · $skipped duplicate(s) skipped' : ''}';
    });
  }

  /// Folder cursors advance only after the encrypted vault save succeeds.
  ///
  /// Camera-style images (JPEG/PNG/WebP/HEIC) go to the `photo` source with the
  /// file's modification time as capture-time fallback; PDFs and other scans
  /// stay `scanned-pdf`.
  Future<bool> importDocumentFile(String path) async {
    var saved = false;
    await _run(() async {
      if (!isAuthenticated) {
        throw StateError('Unlock the vault to import documents.');
      }
      final file = XFile(path);
      final bytes = await readExportBytes(
        PlatformFile(
          name: file.name,
          size: await file.length(),
          readStream: file.openRead(),
        ),
        maxBytes: 25 * 1024 * 1024,
      );
      if (isPhotoFile(file.name)) {
        await _importPhotoBytes(bytes, file.name, await _lastModified(file));
        status = 'Photo indexed · saved encrypted';
        saved = true;
        return;
      }
      final documentId = base64UrlEncode(
        (await Sha256().hash(utf8.encode(path))).bytes,
      );
      final result = await _requireApi().importSource(
        'scanned-pdf',
        ImportSourceRequest(
          title: file.name,
          originalFileName: file.name,
          payloadBase64: base64Encode(bytes),
          metadata: {'documentId': documentId},
        ),
        timeout: const Duration(minutes: 10),
      );
      await _ingestNormalizedImport(result);
      status = 'Document indexed · saved encrypted';
      saved = true;
    });
    return saved;
  }

  Future<DateTime?> _lastModified(XFile file) async {
    try {
      return await file.lastModified();
    } catch (_) {
      return null;
    }
  }

  /// Imports one camera photo through the `photo` source (OCR conversation).
  ///
  /// Returns the id of the created or updated conversation, or null when the
  /// import failed ([error] then holds the reason). [capturedAt] is only a
  /// fallback; the server prefers the EXIF capture time.
  Future<String?> importPhotoFile(String path, {DateTime? capturedAt}) async {
    String? conversationId;
    await _run(() async {
      if (!isAuthenticated) {
        throw StateError('Unlock the vault to import photos.');
      }
      final file = XFile(path);
      final size = await file.length();
      if (size > maxPhotoBytes) {
        throw const FormatException('Photos larger than 25 MiB are skipped.');
      }
      final bytes = await readExportBytes(
        PlatformFile(name: file.name, size: size, readStream: file.openRead()),
        maxBytes: maxPhotoBytes,
      );
      conversationId = await _importPhotoBytes(
        bytes,
        file.name,
        capturedAt ?? await _lastModified(file),
      );
      status = 'Photo indexed · saved encrypted';
    });
    return conversationId;
  }

  /// Stores a compressed copy of an imported photo in the image vault, linked
  /// to [conversationId] so it appears in that conversation's gallery. Throws
  /// [QuotaExceededException] when the storage quota is used up; callers treat
  /// that as a non-fatal status.
  Future<void> keepPhotoInVault(String path, String conversationId) async {
    final file = XFile(path);
    final raw = await file.readAsBytes();
    final captured = await ImageService.processBytes(raw, file.name);
    await uploadCapturedImage(captured, conversationId: conversationId);
  }

  Future<String?> _importPhotoBytes(
    List<int> bytes,
    String fileName,
    DateTime? capturedAt,
  ) async {
    final normalized = await _requireApi().importSource(
      'photo',
      ImportSourceRequest(
        title: fileName,
        originalFileName: fileName,
        mimeType: _photoMimeType(fileName),
        payloadBase64: base64Encode(bytes),
        metadata: photoMetadata(capturedAt),
      ),
      timeout: const Duration(minutes: 5),
    );
    await _ingestNormalizedImport(normalized);
    final threadId = normalized.conversations.firstOrNull?.sourceThreadId;
    return conversations
        .where((c) => c.source == 'photo' && c.sourceThreadId == threadId)
        .firstOrNull
        ?.id;
  }

  /// `metadata` of a `photo` import: client capture time fallback and the
  /// device's UTC offset (used when the EXIF date has no offset).
  static Map<String, String> photoMetadata(DateTime? capturedAt) {
    final moment = capturedAt ?? DateTime.now();
    return {
      'capturedAt': moment.toUtc().toIso8601String(),
      'utcOffsetMinutes': '${moment.toLocal().timeZoneOffset.inMinutes}',
    };
  }

  static String _photoMimeType(String fileName) {
    final extension = fileName.toLowerCase().split('.').last;
    return switch (extension) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      _ => 'image/jpeg',
    };
  }

  Future<NormalizedImportResult?> importPaperlessPage(
    Map<String, String> metadata, {
    Future<NormalizedImportResult> Function()? fetch,
  }) async {
    NormalizedImportResult? saved;
    await _run(() async {
      if (!isAuthenticated) {
        throw StateError('Unlock the vault to import documents.');
      }
      final owner = session;
      final result = await (fetch != null
          ? fetch()
          : _requireApi().importSource(
              'paperless',
              ImportSourceRequest(metadata: metadata),
              timeout: const Duration(minutes: 10),
            ));
      if (!isAuthenticated || !identical(session, owner)) {
        throw StateError(
          'The vault changed before the document import completed.',
        );
      }
      await _ingestNormalizedImport(result);
      saved = result;
    });
    return saved;
  }

  /// Imports locally observed browser messages through the encrypted vault pipeline.
  Future<int?> importBrowserMessages(NormalizedImportResult result) async {
    int? imported;
    await _run(() async {
      if (!isAuthenticated) {
        throw StateError('Unlock the vault to import browser messages.');
      }
      imported = await _ingestNormalizedImport(result);
    });
    return error == null ? imported : null;
  }

  Future<bool> importDiscordBotBatch(NormalizedImportResult result) async {
    var saved = false;
    await _run(() async {
      if (!isAuthenticated) {
        throw StateError('Unlock the vault to import Discord messages.');
      }
      await _ingestNormalizedImport(result);
      saved = true;
    });
    return saved;
  }

  /// Upper bound for one audio upload plus transcription. Long enough for a
  /// 30-minute recording on a slow CPU server; users can cancel earlier.
  static const _audioTranscriptionTimeout = Duration(minutes: 45);

  /// Imports an audio recording for server-side transcription.
  ///
  /// Takes raw [bytes] and a [fileName] directly (rather than a
  /// `PlatformFile`) so this can be driven by the file picker in the UI or
  /// called directly from tests with a stubbed HTTP client. The resulting
  /// conversation is ingested through the same normalized-import path as
  /// every other import source, so it is tagged, encrypted, and synced
  /// identically.
  ///
  /// Returns true once the transcript and its audio are saved, even if search
  /// indexing fails afterwards; false when the caller must keep its audio, for
  /// example after [cancelAudioTranscription].
  Future<bool> importAudioBytes({
    required List<int> bytes,
    required String fileName,
    String? mimeType,
    String? title,
    String? participantNames,
    String? language,
    DateTime? recordedAt,
    String? recordingId,
    List<String> participantIds = const [],
    RecordingLocation? location,
  }) async {
    if (bytes.isEmpty) return false;
    if (busy) {
      status = 'Wait for the current vault operation to finish.';
      _notifyChanged();
      return false;
    }
    final contentType = _audioContentType(bytes, fileName, mimeType);
    final request = ImportSourceRequest(
      title: title?.trim().isEmpty == true ? null : title?.trim(),
      originalFileName: fileName,
      mimeType: contentType,
      metadata: _audioMetadata(language, recordedAt),
      participantNames: _splitParticipantNames(participantNames),
    );
    final target = (
      recordingId: recordingId,
      participantIds: participantIds,
      location: location,
      fileName: fileName,
      contentType: contentType,
    );
    var saved = false;
    final run = _run(
      () async => saved = await _transcribeAudio(request, bytes, target),
    );
    _audioImport = run;
    try {
      await run;
    } finally {
      if (identical(_audioImport, run)) _audioImport = null;
    }
    return saved;
  }

  Future<bool> _transcribeAudio(
    ImportSourceRequest request,
    List<int> bytes,
    _AudioImportTarget target,
  ) async {
    final api = _requireApi();
    final identity = recordingIdentity;
    final normalized = await _uploadAudio(api, request, bytes);
    if (normalized == null) return false;
    if (target.recordingId != null) _checkRecordingSession(api, identity);
    final added = await _ingestTranscribedAudio(normalized, target);
    // Only once the audio is cached may the caller drop its copy.
    await _cacheTranscribedAudio(added, bytes, target);
    status = '${normalized.message} Saved encrypted; queued for sync.';
    return true;
  }

  /// Uploads while [cancelAudioTranscription] can abort it. Null if cancelled.
  Future<NormalizedImportResult?> _uploadAudio(
    LifenizerApiClient api,
    ImportSourceRequest request,
    List<int> bytes,
  ) async {
    final cancellation = RequestCancellation();
    _audioTranscription = cancellation;
    status = 'Transcribing audio… you can cancel at any time.';
    _notifyChanged();
    try {
      return await api.importAudio(
        request,
        audio: bytes,
        timeout: _audioTranscriptionTimeout,
        cancellation: cancellation,
      );
    } on RequestCancelledException {
      status = 'Transcription cancelled.';
      return null;
    } finally {
      _audioTranscription = null;
      _notifyChanged();
    }
  }

  /// Ingests the transcript and returns the audio conversations it added.
  Future<List<Conversation>> _ingestTranscribedAudio(
    NormalizedImportResult normalized,
    _AudioImportTarget target,
  ) async {
    final previousIds = conversations.map((c) => c.id).toSet();
    await _ingestNormalizedImport(
      normalized,
      recordingId: target.recordingId,
      selectedParticipantIds: target.participantIds,
      location: target.location,
    );
    return conversations
        .where((c) => c.source == 'audio' && !previousIds.contains(c.id))
        .toList();
  }

  Future<void> _cacheTranscribedAudio(
    List<Conversation> added,
    List<int> bytes,
    _AudioImportTarget target,
  ) async {
    for (final conversation in added) {
      await _cacheCorrectionAudio(
        conversation.id,
        bytes,
        fileName: target.fileName,
        contentType: target.contentType,
      );
    }
  }

  /// Our own recordings are identified by content, never by name.
  String _audioContentType(List<int> bytes, String fileName, String? claimed) =>
      RecordingFormat.detect(bytes)?.contentType ??
      claimed ??
      _guessAudioMimeType(fileName);

  Map<String, String> _audioMetadata(String? language, DateTime? recordedAt) {
    final trimmed = language?.trim() ?? '';
    return {
      if (trimmed.isNotEmpty) 'language': trimmed,
      if (recordedAt != null)
        'recordedAt': recordedAt.toUtc().toIso8601String(),
    };
  }

  List<String> _splitParticipantNames(String? names) => names == null
      ? const []
      : names
            .split(',')
            .map((name) => name.trim())
            .where((name) => name.isNotEmpty)
            .toList();

  static const Map<String, String> _audioMimeTypesByExtension = {
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'wav': 'audio/wav',
    'ogg': 'audio/ogg',
    'opus': 'audio/opus',
    'flac': 'audio/flac',
    'aac': 'audio/aac',
    'webm': 'audio/webm',
  };

  static String _guessAudioMimeType(String fileName) {
    final extension = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    return _audioMimeTypesByExtension[extension] ?? 'application/octet-stream';
  }

  Future<void> importSample(String source) async {
    switch (source) {
      case 'whatsapp':
        return importSource(
          source: source,
          title: 'WhatsApp project export',
          text:
              '[20.05.2026, 10:00] Alice: Person X works with Person Z.\n[20.05.2026, 10:01] Bob: Person Y is Person X\'s sister.',
        );
      case 'telegram':
        return importSource(
          source: source,
          text:
              '{"name":"Telegram Project","messages":[{"from":"Mira","text":"Ship the Flutter Android app.","date":"2026-05-20T11:00:00Z"}]}',
        );
      case 'signal':
        return importSource(
          source: source,
          text:
              'timestamp,sender,message\n2026-05-20T12:00:00Z,Sam,Signal CSV import works',
        );
      case 'slack':
        return importSource(
          source: source,
          title: 'Slack project channel',
          text:
              '[{"user_profile":{"display_name":"Nina"},"text":"Slack export sample message.","ts":"1716206400.0"}]',
        );
      case 'teams':
        return importSource(
          source: source,
          title: 'Teams planning thread',
          text:
              '{"messages":[{"fromDisplayName":"Jon","content":"<p>Teams export sample message.</p>","createdDateTime":"2026-05-20T13:10:00Z"}]}',
        );
      case 'facebook-messenger':
        return importSource(
          source: source,
          title: 'Messenger thread sample',
          text:
              '{"title":"Friends Thread","participants":[{"name":"Ava"},{"name":"Liam"}],"messages":[{"sender_name":"Ava","content":"Messenger export sample message.","timestamp_ms":1716206400000}]}',
        );
      case 'instagram':
        return importSource(
          source: source,
          title: 'Instagram DM sample',
          text:
              '{"title":"DM with Sam","participants":[{"name":"Sam"}],"messages":[{"sender_name":"Sam","content":"Instagram export sample message.","timestamp_ms":1716207400000}]}',
        );
      case 'imessage':
        return importSource(
          source: source,
          title: 'iMessage sample',
          text: '5/20/2026, 9:41 AM - Alex: iMessage export sample message.',
        );
      case 'mbox':
        return importSource(
          source: source,
          title: 'Mbox sample',
          text:
              'From sender@example.test Tue May 20 10:15:00 2026\nFrom: Sender <sender@example.test>\nTo: Receiver <receiver@example.test>\nSubject: Mbox sample\nDate: Tue, 20 May 2026 10:15:00 +0000\n\nThis is a sample mbox message body.',
        );
      case 'git':
        return importSource(
          source: source,
          title: 'Git sample',
          text:
              'commit 0f4e9b7\nAuthor: Dev One <dev1@example.test>\nDate: 2026-05-20T14:00:00Z\n\nAdd importer support for browser extension payloads',
        );
      case 'browser-capture':
        return importSource(
          source: source,
          title: 'Captured reading session',
          text:
              '{"events":[{"title":"Importer docs","url":"https://docs.example.test/importers","content":"Read about browser capture format.","timestamp":"2026-05-20T15:00:00Z"}]}',
        );
      case 'google-search-history':
        return importSource(
          source: source,
          title: 'Google search sample',
          text:
              'query,url,time\nflutter receive sharing intent,https://www.google.com/search?q=flutter+receive+sharing+intent,2026-05-20T15:30:00Z',
        );
      case 'bookmarks':
        return importSource(
          source: source,
          title: 'Bookmarks sample',
          text:
              '{"roots":{"bookmark_bar":{"children":[{"type":"url","name":"Lifenizer","url":"https://github.com/Ekwav/lifenizer"}]}}}',
        );
      case 'lifenizer-backup':
        return importSource(
          source: source,
          title: 'Backup sample',
          text:
              '{"conversations":[{"title":"Backup conversation","source":"manual-text","participantNames":["Alice"],"segments":[{"text":"Recovered from backup","participantName":"Alice","offsetMs":0}]}]}',
        );
      case 'browser-history':
        return importSource(
          source: source,
          title: 'Browser research trail',
          text:
              'title,url,time\nPaperless docs,https://paperless.example.test,2026-05-20T12:30:00Z',
        );
      case 'youtube-transcript':
        return importSource(
          source: source,
          title: 'YouTube transcript sample',
          text:
              '{"segments":[{"text":"Private archive demo transcript.","start":0},{"text":"Transcript segments are searchable after encryption.","start":2.5}]}',
        );
      case 'audio':
        return importSource(
          source: source,
          title: 'Audio transcript sample',
          originalFileName: 'meeting.wav',
          mimeType: 'audio/wav',
          text: 'Alice described the TAP transcription import plan.',
        );
      case 'scanned-pdf':
        return importSource(
          source: source,
          title: 'Scanned invoice sample',
          originalFileName: 'invoice.pdf',
          mimeType: 'application/pdf',
          text: 'OCR text from a scanned Paperless invoice.',
        );
      default:
        status =
            'This source needs provider credentials or pasted export data.';
        _notifyChanged();
    }
  }

  Future<void> importDiscordArchive(String path) => _run(() async {
    if (!isAuthenticated) {
      throw StateError('Unlock the vault before importing a Discord export.');
    }
    var changed = 0;
    var read = 0;
    await for (final result in readDiscordArchive(
      path,
      onProgress: (channels, total, messages) {
        read = messages;
        status =
            'Reading Discord export · $channels/$total channels · $messages messages';
        _notifyChanged();
      },
    )) {
      changed += await _ingestNormalizedImport(result);
    }
    status =
        'Discord export · $read messages · $changed conversation(s) added or updated · saved encrypted';
  });

  Future<int> _ingestNormalizedImport(
    NormalizedImportResult result, {
    String? fingerprint,
    String? recordingId,
    List<String> selectedParticipantIds = const [],
    RecordingLocation? location,
  }) => batchVaultChanges(() async {
    if (recordingId != null &&
        (result.conversations.length != 1 ||
            result.conversations.single.source != 'audio' ||
            !_knownRecording(recordingId))) {
      throw StateError('The transcript does not match this recording.');
    }
    var changed = 0;
    final receipts = {
      for (var i = 0; i < conversations.length; i++)
        if (conversations[i].importFingerprint != null)
          conversations[i].importFingerprint!: i,
    };
    final threads = <String, int>{
      for (var i = 0; i < conversations.length; i++)
        if (conversations[i].sourceThreadId != null)
          '${conversations[i].source}\u0000${conversations[i].sourceThreadId}':
              i,
    };
    final identities = <String, String>{};
    final names = <String, Set<String>>{};
    final selected = await ensureParticipantSelection(
      '',
      selectedParticipantIds,
    );
    for (final id in selected) {
      final person = participantById(id)!;
      for (final name in [person.displayName, ...person.aliases]) {
        names.putIfAbsent(name.toLowerCase(), () => {}).add(id);
      }
    }
    for (final person in result.participants) {
      if (person.identifiers.isEmpty &&
          names.containsKey(person.displayName.toLowerCase())) {
        continue;
      }
      final resolved = await ensureParticipantIdentity(
        person.displayName,
        identifiers: person.identifiers,
        aliases: person.aliases,
      );
      for (final identifier in person.identifiers) {
        identities[identifier] = resolved.id;
      }
      for (final name in [person.displayName, ...person.aliases]) {
        names.putIfAbsent(name.toLowerCase(), () => {}).add(resolved.id);
      }
    }
    Future<String> identity(String identifier) async {
      final existing = identities[identifier];
      if (existing != null) return resolveParticipantId(existing);
      final person = await ensureParticipantIdentity(
        identifier,
        identifiers: [identifier],
      );
      return identities[identifier] = person.id;
    }

    for (var index = 0; index < result.conversations.length; index++) {
      final normalized = result.conversations[index];
      final receipt = fingerprint == null ? null : '$fingerprint:$index';
      final duplicateIndex = receipt == null ? null : receipts[receipt];
      if (duplicateIndex != null) {
        final existing = conversations[duplicateIndex];
        if (selected.every(existing.participantIds.contains)) continue;
        final current = await loadConversation(existing.id);
        final updated = Conversation.fromJson({
          ...current.toJson(),
          'participantIds': {...current.participantIds, ...selected}.toList(),
        });
        conversations[duplicateIndex] = updated;
        _markConversationChanged(updated.id);
        await _pushEntity('conversation', updated.id, updated.toJson());
        changed++;
        continue;
      }
      final threadKey = normalized.sourceThreadId == null
          ? null
          : '${normalized.source}\u0000${normalized.sourceThreadId}';
      final previousIndex = recordingId != null
          ? conversations.indexWhere((c) => c.id == recordingId)
          : threadKey == null
          ? null
          : threads[threadKey];
      final previous = previousIndex == null
          ? null
          : await loadConversation(conversations[previousIndex].id);
      final conversationId =
          previous?.id ??
          (threadKey == null
              ? _uuid.v4()
              : _uuid.v5(Namespace.url.value, 'lifenizer:thread:$threadKey'));
      final participantIds = <String>{
        ...?previous?.participantIds.map(resolveParticipantId),
        ...selected,
      };
      for (final identifier in normalized.participantIdentifiers) {
        participantIds.add(await identity(identifier));
      }
      for (final name in normalized.participantNames) {
        final candidates = names[name.toLowerCase()];
        if (candidates?.length == 1) {
          participantIds.add(resolveParticipantId(candidates!.single));
        } else if (candidates == null) {
          final person = await ensureParticipantIdentity(name);
          participantIds.add(person.id);
          names.putIfAbsent(name.toLowerCase(), () => {}).add(person.id);
        }
      }
      final segments = [...?previous?.segments];
      final messages = <String, int>{
        for (var i = 0; i < segments.length; i++)
          if (segments[i].sourceMessageId != null)
            segments[i].sourceMessageId!: i,
      };
      for (final segment in normalized.segments) {
        final messageIndex = segment.sourceMessageId == null
            ? null
            : messages[segment.sourceMessageId];
        final old = messageIndex == null ? null : segments[messageIndex];
        String? participantId;
        if (segment.participantIdentifier != null) {
          participantId = await identity(segment.participantIdentifier!);
        } else if (segment.participantName != null) {
          final candidates = names[segment.participantName!.toLowerCase()];
          if (candidates?.length == 1) {
            participantId = resolveParticipantId(candidates!.single);
          }
          if (candidates == null) {
            participantId = (await ensureParticipantIdentity(
              segment.participantName!,
            )).id;
            names
                .putIfAbsent(segment.participantName!.toLowerCase(), () => {})
                .add(participantId);
          }
        }
        if (participantId != null) participantIds.add(participantId);
        final imported = ConversationSegment(
          id:
              old?.id ??
              (segment.sourceMessageId == null
                  ? _uuid.v4()
                  : _uuid.v5(
                      Namespace.url.value,
                      'lifenizer:message:$conversationId:${segment.sourceMessageId}',
                    )),
          sourceMessageId: segment.sourceMessageId,
          text: segment.text,
          participantId: participantId,
          offsetMs: segment.offsetMs,
          endMs: segment.endMs,
          createdAt: segment.createdAt ?? old?.createdAt,
          attachmentUrls: segment.attachmentUrls,
        );
        if (messageIndex == null) {
          if (segment.sourceMessageId != null) {
            messages[segment.sourceMessageId!] = segments.length;
          }
          segments.add(imported);
        } else {
          segments[messageIndex] = imported;
        }
      }
      if (segments.isEmpty) {
        segments.add(
          ConversationSegment(
            id: _uuid.v4(),
            text: 'Imported ${result.source} item without text.',
          ),
        );
      }
      if (normalized.sourceThreadId != null) {
        segments.sort((a, b) {
          final byTime = a.createdAt.compareTo(b.createdAt);
          return byTime != 0
              ? byTime
              : (a.sourceMessageId ?? a.id).compareTo(
                  b.sourceMessageId ?? b.id,
                );
        });
      }
      final dates = segments.map((s) => s.createdAt).toList()..sort();
      final conversation = Conversation(
        id: conversationId,
        sourceThreadId: normalized.sourceThreadId,
        sourceUrl: normalized.sourceUrl ?? previous?.sourceUrl,
        metadata: _mergeImportMetadata(previous?.metadata, normalized.metadata),
        importFingerprint: previous?.importFingerprint ?? receipt,
        title: normalized.title.trim().isEmpty
            ? 'Imported ${result.source}'
            : normalized.title.trim(),
        source: normalized.source,
        location: location ?? previous?.location,
        participantIds: participantIds.toList(),
        artifactNames: {
          ...?previous?.artifactNames,
          ...normalized.artifactNames,
        }.toList(),
        tags: {
          ...?previous?.tags,
          ..._suggestTags(
            source: normalized.source,
            title: normalized.title,
            text: normalized.segments.map((s) => s.text).join('\n'),
            artifactNames: normalized.artifactNames,
          ),
        }.toList(),
        isFavorite: previous?.isFavorite ?? false,
        startedAt: dates.first,
        endedAt: dates.last,
        segments: segments,
      );
      if (previous != null &&
          jsonEncode(previous.toJson()) == jsonEncode(conversation.toJson())) {
        continue;
      }
      if (previousIndex == null) {
        if (threadKey != null) threads[threadKey] = conversations.length;
        conversations.add(conversation);
      } else {
        conversations[previousIndex] = conversation;
      }
      _markConversationChanged(conversation.id);
      if (receipt != null) {
        receipts[receipt] = previousIndex ?? conversations.length - 1;
      }
      changed++;
      await _pushEntity('conversation', conversation.id, conversation.toJson());
    }
    return changed;
  });
}

/// Largest photo accepted by the `photo` importer.
const int maxPhotoBytes = 25 * 1024 * 1024;

/// Re-importing a watch history reports `transcript: none`; keep a transcript
/// (or unavailable) marker that enrichment already stored.
Map<String, String> _mergeImportMetadata(
  Map<String, String>? previous,
  Map<String, String> incoming,
) {
  final merged = {...?previous, ...incoming};
  final earlier = previous?['transcript'];
  if (incoming['transcript'] == 'none' &&
      (earlier == 'youtube-captions' || earlier == 'unavailable')) {
    merged['transcript'] = earlier!;
  }
  return merged;
}

extension VaultTranscriptEnrichment on LifenizerAppState {
  /// Fetches YouTube captions for the watched video [conversationId] and
  /// merges the timed segments into that conversation (no second
  /// conversation). A 404 marks it `transcript: unavailable` so bulk runs do
  /// not retry it.
  Future<TranscriptResult> enrichWatchedVideo(String conversationId) async {
    try {
      if (!_crypto.isUnlocked) {
        return const TranscriptResult(
          TranscriptOutcome.failed,
          message: 'Unlock the vault to fetch transcripts.',
        );
      }
      final api = _requireApi();
      final index = conversations.indexWhere((c) => c.id == conversationId);
      if (index < 0) {
        return const TranscriptResult(
          TranscriptOutcome.unsupported,
          message: 'Conversation not found.',
        );
      }
      final conversation = conversations[index];
      final videoId =
          conversation.metadata['videoId'] ??
          (conversation.sourceThreadId?.startsWith('youtube:') == true
              ? conversation.sourceThreadId!.substring(8)
              : null);
      if (conversation.source != 'youtube-watch-history' || videoId == null) {
        return const TranscriptResult(
          TranscriptOutcome.unsupported,
          message: 'Transcripts are only available for YouTube videos.',
        );
      }
      if (conversation.metadata['transcript'] == 'youtube-captions') {
        return const TranscriptResult(TranscriptOutcome.alreadyEnriched);
      }
      final NormalizedImportResult fetched;
      try {
        fetched = await api.importSource(
          'youtube-transcript',
          ImportSourceRequest(
            title: conversation.title,
            metadata: {'videoId': videoId},
          ),
          timeout: const Duration(minutes: 1),
        );
      } on ApiException catch (exception) {
        if (exception.statusCode == 404) {
          await _updateWatchedVideo(conversationId, null, {
            'transcript': 'unavailable',
          });
          return TranscriptResult(
            TranscriptOutcome.unavailable,
            message: 'No public captions for this video.',
          );
        }
        if (exception.statusCode == 429) {
          return TranscriptResult(
            exception.errorCode == 'provider_blocked'
                ? TranscriptOutcome.blocked
                : TranscriptOutcome.rateLimited,
            retryAfter: exception.retryAfter,
            message: 'YouTube caption fetching is rate limited.',
          );
        }
        return TranscriptResult(
          TranscriptOutcome.failed,
          message: exception.toString(),
        );
      }
      final transcript = fetched.conversations.firstOrNull;
      if (transcript == null || transcript.segments.isEmpty) {
        await _updateWatchedVideo(conversationId, null, {
          'transcript': 'unavailable',
        });
        return const TranscriptResult(TranscriptOutcome.unavailable);
      }
      await _updateWatchedVideo(
        conversationId,
        (current) {
          final kept = current.segments
              .where(
                (segment) =>
                    segment.sourceMessageId?.startsWith('transcript:') != true,
              )
              .toList();
          final stamp = current.endedAt;
          for (var i = 0; i < transcript.segments.length; i++) {
            final segment = transcript.segments[i];
            final messageId = 'transcript:$videoId:$i';
            kept.add(
              ConversationSegment(
                id: _uuid.v5(
                  Namespace.url.value,
                  'lifenizer:message:$conversationId:$messageId',
                ),
                sourceMessageId: messageId,
                text: segment.text,
                offsetMs: segment.offsetMs,
                endMs: segment.endMs,
                createdAt: stamp,
              ),
            );
          }
          return kept;
        },
        {
          'transcript': 'youtube-captions',
          'transcriptSource': 'youtube-captions',
          if (transcript.metadata['language'] != null)
            'language': transcript.metadata['language']!,
          if (transcript.metadata['kind'] != null)
            'kind': transcript.metadata['kind']!,
        },
      );
      return const TranscriptResult(TranscriptOutcome.merged);
    } catch (exception) {
      return TranscriptResult(
        TranscriptOutcome.failed,
        message: exception.toString(),
      );
    }
  }

  /// Replaces segments (via [segments]) and metadata of one conversation and
  /// marks it changed so the chunked vault and incremental index update.
  Future<void> _updateWatchedVideo(
    String conversationId,
    List<ConversationSegment> Function(Conversation current)? segments,
    Map<String, String> metadata,
  ) => batchVaultChanges(() async {
    final index = conversations.indexWhere((c) => c.id == conversationId);
    if (index < 0) return;
    final current = await loadConversation(conversationId);
    final nextSegments = segments == null
        ? current.segments
        : segments(current);
    final updated = Conversation(
      id: current.id,
      sourceThreadId: current.sourceThreadId,
      sourceUrl: current.sourceUrl,
      metadata: {...current.metadata, ...metadata},
      importFingerprint: current.importFingerprint,
      title: current.title,
      source: current.source,
      location: current.location,
      participantIds: current.participantIds,
      artifactNames: current.artifactNames,
      tags: current.tags,
      isFavorite: current.isFavorite,
      startedAt: current.startedAt,
      endedAt: current.endedAt,
      segments: nextSegments,
    );
    conversations[index] = updated;
    _markConversationChanged(updated.id);
    await _pushEntity('conversation', updated.id, updated.toJson());
  }).then((_) => _prepareSearchIndex()).then((_) => _notifyChanged());

  /// Ids of the most recently watched YouTube videos that still lack a
  /// transcript decision (neither captions nor marked unavailable).
  List<String> recentVideosNeedingTranscript({int limit = 25}) {
    DateTime watched(Conversation c) =>
        DateTime.tryParse(c.metadata['lastWatchedAt'] ?? '') ?? c.endedAt;
    final candidates =
        conversations
            .where(
              (c) =>
                  c.source == 'youtube-watch-history' &&
                  (c.metadata['transcript'] ?? 'none') == 'none',
            )
            .toList()
          ..sort((a, b) => watched(b).compareTo(watched(a)));
    return [for (final c in candidates.take(limit)) c.id];
  }

  /// Sequentially fetches transcripts for the newest watched videos.
  Future<TranscriptBatchProgress> enrichRecentWatchedVideos({
    int limit = 25,
    required TranscriptBatchCancel cancel,
    void Function(TranscriptBatchProgress progress)? onProgress,
    Future<void> Function(Duration pause)? wait,
  }) => runTranscriptBatch(
    conversationIds: recentVideosNeedingTranscript(limit: limit),
    enrich: enrichWatchedVideo,
    wait: wait ?? (pause) => cancellableDelay(pause, cancel),
    cancel: cancel,
    onProgress: onProgress,
  );
}
