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

  Future<int> _ingestNormalizedImport(
    NormalizedImportResult result, {
    String? fingerprint,
  }) async {
    var added = 0;
    final existing = conversations
        .map((c) => c.importFingerprint)
        .whereType<String>()
        .toSet();
    for (var index = 0; index < result.conversations.length; index++) {
      final normalized = result.conversations[index];
      final receipt = fingerprint == null ? null : '$fingerprint:$index';
      if (receipt != null && existing.contains(receipt)) {
        continue;
      }
      final participantIds = await ensureParticipantNames(
        normalized.participantNames,
      );
      final nameToId = <String, String>{};
      for (final participant in participants) {
        nameToId[participant.displayName.toLowerCase()] = participant.id;
      }
      // Prefer the real historical timestamps carried by the imported
      // segments (e.g. actual WhatsApp/email message dates) over defaulting
      // to "now". Without this, every import would look like it happened at
      // import time, which would make searching/filtering by time useless
      // for anything that wasn't just imported. Conversation.startedAt/
      // endedAt fall back to DateTime.now() automatically when null is
      // passed, so sources without per-segment timestamps (e.g. audio
      // without detected dates) keep today's default behavior.
      final segmentTimestamps =
          normalized.segments
              .map((segment) => segment.createdAt)
              .whereType<DateTime>()
              .toList()
            ..sort();
      final derivedStartedAt = segmentTimestamps.isEmpty
          ? null
          : segmentTimestamps.first;
      final derivedEndedAt = segmentTimestamps.isEmpty
          ? null
          : segmentTimestamps.last;
      final conversation = Conversation(
        id: _uuid.v4(),
        importFingerprint: receipt,
        title: normalized.title.trim().isEmpty
            ? 'Imported ${result.source}'
            : normalized.title.trim(),
        source: normalized.source,
        participantIds: participantIds,
        artifactNames: normalized.artifactNames,
        tags: _suggestTags(
          source: normalized.source,
          title: normalized.title,
          text: normalized.segments.map((segment) => segment.text).join('\n'),
          artifactNames: normalized.artifactNames,
        ),
        startedAt: derivedStartedAt,
        endedAt: derivedEndedAt,
        segments: normalized.segments.isEmpty
            ? [
                ConversationSegment(
                  id: _uuid.v4(),
                  text: 'Imported ${result.source} item without text.',
                ),
              ]
            : [
                for (final segment in normalized.segments)
                  ConversationSegment(
                    id: _uuid.v4(),
                    text: segment.text,
                    participantId: segment.participantName == null
                        ? null
                        : nameToId[segment.participantName!.toLowerCase()],
                    offsetMs: segment.offsetMs,
                    createdAt: segment.createdAt,
                  ),
              ],
      );
      conversations.add(conversation);
      added++;
      await _pushEntity('conversation', conversation.id, conversation.toJson());
    }
    if (added > 0) {
      _markSearchIndexDirty();
    }
    return added;
  }
}
