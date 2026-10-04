part of '../app_state.dart';

extension VaultImports on LifenizerAppState {
  Future<void> importSource({
    required String source,
    String? title,
    String? participantNames,
    String? text,
    String? originalFileName,
    String? mimeType,
    Map<String, String> metadata = const {},
    String? payloadBase64,
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
      );
      final added = await _ingestNormalizedImport(
        normalized,
        fingerprint: fingerprint,
      );
      final skipped = normalized.conversations.length - added;
      status = added == 0 && skipped > 0
          ? 'Already imported · $skipped conversation(s) skipped ($source)'
          : 'Imported $added conversation(s) from $source · saved encrypted'
                '${skipped > 0 ? ' · $skipped duplicate(s) skipped' : ''}';
    });
  }

  /// Imports an audio recording for server-side transcription.
  ///
  /// Takes raw [bytes] and a [fileName] directly (rather than a
  /// `PlatformFile`) so this can be driven by the file picker in the UI or
  /// called directly from tests with a stubbed HTTP client. The backend
  /// transcribes on CPU and can take minutes, so the request uses a long
  /// timeout (see [LifenizerApiClient.importSource]); the resulting
  /// conversation is ingested through the same normalized-import path as
  /// every other import source, so it is tagged, encrypted, and synced
  /// identically.
  Future<void> importAudioBytes({
    required List<int> bytes,
    required String fileName,
    String? mimeType,
    String? title,
    String? participantNames,
    String? language,
    DateTime? recordedAt,
  }) async {
    if (bytes.isEmpty) return;
    status = 'Transcribing audio… this can take a few minutes.';
    error = null;
    _notifyChanged();
    await _run(() async {
      final api = _requireApi();
      final metadata = <String, String>{
        if (language != null && language.trim().isNotEmpty)
          'language': language.trim(),
        if (recordedAt != null)
          'recordedAt': recordedAt.toUtc().toIso8601String(),
      };
      final normalized = await api.importSource(
        'audio',
        ImportSourceRequest(
          title: title?.trim().isEmpty == true ? null : title?.trim(),
          originalFileName: fileName,
          mimeType: mimeType ?? _guessAudioMimeType(fileName),
          metadata: metadata,
          participantNames: participantNames == null
              ? const []
              : participantNames
                    .split(',')
                    .map((name) => name.trim())
                    .where((name) => name.isNotEmpty)
                    .toList(),
          payloadBase64: base64Encode(bytes),
        ),
        timeout: const Duration(minutes: 10),
      );
      await _ingestNormalizedImport(normalized);
      status = '${normalized.message} Encrypted and synced.';
    });
  }

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
  }) => batchVaultChanges(() async {
    var changed = 0;
    final receipts = conversations
        .map((c) => c.importFingerprint)
        .whereType<String>()
        .toSet();
    final threads = <String, int>{
      for (var i = 0; i < conversations.length; i++)
        if (conversations[i].sourceThreadId != null)
          '${conversations[i].source}\u0000${conversations[i].sourceThreadId}':
              i,
    };
    final identities = <String, String>{};
    final names = <String, Set<String>>{};
    for (final person in result.participants) {
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
      if (receipt != null && receipts.contains(receipt)) continue;
      final threadKey = normalized.sourceThreadId == null
          ? null
          : '${normalized.source}\u0000${normalized.sourceThreadId}';
      final previousIndex = threadKey == null ? null : threads[threadKey];
      final previous = previousIndex == null
          ? null
          : conversations[previousIndex];
      final conversationId =
          previous?.id ??
          (threadKey == null
              ? _uuid.v4()
              : _uuid.v5(Namespace.url.value, 'lifenizer:thread:$threadKey'));
      final participantIds = <String>{
        ...?previous?.participantIds.map(resolveParticipantId),
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
        metadata: {...?previous?.metadata, ...normalized.metadata},
        importFingerprint: previous?.importFingerprint ?? receipt,
        title: normalized.title.trim().isEmpty
            ? 'Imported ${result.source}'
            : normalized.title.trim(),
        source: normalized.source,
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
      if (receipt != null) receipts.add(receipt);
      changed++;
      await _pushEntity('conversation', conversation.id, conversation.toJson());
    }
    if (changed > 0) _markSearchIndexDirty();
    return changed;
  });
}
