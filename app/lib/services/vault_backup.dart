part of '../app_state.dart';

extension VaultBackup on LifenizerAppState {
  void _checkBackupAvailable() {
    if (!isAuthenticated) throw StateError('Unlock this vault first.');
    if (busy) throw StateError('Wait for the current operation.');
    if (recording.recording || recording.working) {
      throw StateError('Stop the microphone recording before making a backup.');
    }
  }

  /// Exports data, never account credentials, pairing secrets or sync tokens.
  Future<BackupSummary> makeBackup({
    required BackupTarget target,
    required String password,
    bool includeMedia = true,
    void Function(int bytes, int parts)? onProgress,
    bool Function()? cancelled,
  }) async {
    _checkBackupAvailable();
    busy = true;
    _notifyChanged();
    void check() {
      if (cancelled?.call() == true) throw StateError('Backup cancelled.');
      if (!isAuthenticated || _disposed) throw StateError('Vault is closed.');
    }

    try {
      await waitForBackgroundSync();
      check();
      await _persistLocal();
      return await writeBackup(
        _backupRecords(includeMedia: includeMedia).map((record) {
          check();
          return record;
        }),
        password: password,
        target: target,
        onProgress: (bytes, parts) {
          check();
          onProgress?.call(bytes, parts);
        },
      );
    } finally {
      busy = false;
      _notifyChanged();
    }
  }

  Stream<Map<String, dynamic>> _backupRecords({
    required bool includeMedia,
  }) async* {
    yield {
      'type': 'library',
      'value': {
        'version': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'includesMedia': includeMedia,
      },
    };
    for (final person in participants.toList()) {
      yield {'type': 'participant', 'value': person.toJson()};
    }
    final ids = conversations.map((c) => c.id).toList();
    for (final id in ids) {
      final conversation = await loadConversation(id);
      yield {'type': 'conversation', 'value': conversation.toJson()};
    }
    for (final relation in relations.toList()) {
      yield {'type': 'relation', 'value': relation.toJson()};
    }
    for (final search in savedSearches.toList()) {
      yield {'type': 'saved-search', 'value': search.toJson()};
    }
    if (!includeMedia) return;
    for (final id in ids.where(_knownRecording)) {
      RecordingAudio audio;
      try {
        audio = await loadRecordingAudio(id);
      } catch (_) {
        throw StateError(
          'Recording $id is unavailable. Keep its source device online or '
          'choose a library-only backup.',
        );
      }
      yield* _backupMediaRecords({
        'kind': 'audio',
        'id': id,
        'fileName': audio.fileName,
        'contentType': audio.contentType,
      }, audio.bytes);
    }
    // A pending recording becomes a saved recording when restored, so it never
    // replaces a newer microphone draft on the destination device.
    final draft = audioDraft;
    if (draft != null) {
      final bytes = await loadAudioDraftPayload();
      if (bytes == null || bytes.isEmpty) {
        throw StateError('The pending recording could not be read.');
      }
      final id = _uuid.v5(
        Namespace.url.value,
        'lifenizer:recording:${session!.vaultId}:${draft['recordedAt']}:${draft['payloadNonce']}',
      );
      final names = (draft['participantNames'] as List? ?? const []).toSet();
      final selectedIds = (draft['participantIds'] as List? ?? const [])
          .cast<String>()
          .map(resolveParticipantId)
          .toSet();
      final selectedNames = selectedIds
          .expand((id) {
            final person = participantById(id);
            return person == null
                ? <String>[]
                : [person.displayName, ...person.aliases];
          })
          .map((name) => name.toLowerCase())
          .toSet();
      final people = {...selectedIds};
      for (final name in names) {
        if (selectedNames.contains(name.toString().toLowerCase())) continue;
        final matches = activeParticipants
            .where((person) => person.displayName == name)
            .toList();
        if (matches.length == 1) people.add(matches.single.id);
      }
      final at = DateTime.parse(draft['recordedAt'] as String);
      final format = RecordingFormat.detect(bytes) ?? RecordingFormat.wav;
      yield {
        'type': 'conversation',
        'value': Conversation(
          id: id,
          title: draft['title'] as String? ?? 'Voice recording',
          source: 'audio',
          location: draft['location'] is Map
              ? RecordingLocation.fromJson(
                  Map<String, dynamic>.from(draft['location'] as Map),
                )
              : null,
          participantIds: people.toList(),
          segments: [],
          artifactNames: [format.fileName],
          startedAt: at,
          endedAt: at,
        ).toJson(),
      };
      yield* _backupMediaRecords({
        'kind': 'audio',
        'id': id,
        'fileName': format.fileName,
        'contentType': format.contentType,
      }, bytes);
    }
    // The gallery may currently show only one conversation; fetch the complete
    // list. A failed media request fails the backup rather than omitting files.
    for (final item in await _requireApi().listImages()) {
      final image = await decryptedImage(item);
      yield* _backupMediaRecords({
        'kind': 'image',
        'id': item.id,
        'conversationId': item.conversationId,
        'fileName': image.fileName,
        'contentType': image.contentType,
      }, image.bytes);
    }
  }

  /// Validate all selected parts before mutating the vault. Restore is additive:
  /// current entities win on ID collisions, and completed additions are saved
  /// if a later disk/network failure interrupts the operation.
  Future<int> restoreBackup({
    required List<BackupPart> parts,
    required String password,
    void Function(String message)? onProgress,
  }) async {
    _checkBackupAvailable();
    busy = true;
    _notifyChanged();
    var added = 0;
    try {
      await waitForBackgroundSync();
      onProgress?.call('Checking all backup files…');
      final validation = _BackupValidation();
      await for (final record in readBackup(parts, password: password)) {
        validation.add(record);
      }
      validation.finish();
      final known = <String, Set<String>>{
        'participant': participants.map((p) => p.id).toSet(),
        'conversation': conversations.map((c) => c.id).toSet(),
        'relation': relations.map((r) => r.id).toSet(),
        'saved-search': savedSearches.map((s) => s.id).toSet(),
      };
      // Fetch before changing local data, so unavailable image storage fails
      // early. Stable restore filenames make retrying image uploads idempotent.
      final existingImages = validation.hasImages
          ? await _requireApi().listImages()
          : <ImageItem>[];
      final imageIds = existingImages.map((i) => i.id).toSet();
      final imageNames = existingImages.map((i) => i.fileName).toSet();
      onProgress?.call('Restoring missing items…');
      await batchVaultChanges(() async {
        Map<String, dynamic>? media;
        BytesBuilder? bytes;
        await for (final record in readBackup(parts, password: password)) {
          final type = record['type'] as String;
          if (known.containsKey(type)) {
            final value = Map<String, dynamic>.from(record['value'] as Map);
            final id = value['id'] as String;
            if (!known[type]!.add(id)) continue;
            if (type == 'conversation' && value['source'] == 'audio') {
              value['metadata'] = {
                ...?value['metadata'] as Map?,
                'recordingSync': 'false',
              };
            }
            await _applyEntity(type, value);
            await _pushEntity(type, id, value);
            added++;
          } else if (type == 'media') {
            media = Map<String, dynamic>.from(record['value'] as Map);
            bytes = BytesBuilder(copy: false);
          } else if (type == 'bytes') {
            bytes!.add(base64Decode(record['value'] as String));
          } else if (type == 'media-end') {
            final value = media!;
            final payload = bytes!.takeBytes();
            final id = value['id'] as String;
            if (value['kind'] == 'audio') {
              if (_knownRecording(id) &&
                  await _localRecordingAudio(
                        id,
                        _requireApi(),
                        recordingIdentity!,
                      ) ==
                      null) {
                await _cacheCorrectionAudio(
                  id,
                  payload,
                  contentType: value['contentType'] as String,
                  fileName: value['fileName'] as String,
                );
              }
            } else {
              final name = 'backup-$id.bin';
              if (!imageIds.contains(id) && !imageNames.contains(name)) {
                final encrypted = await ImageService.encryptImage(
                  CapturedImage(
                    bytes: payload,
                    fileName: value['fileName'] as String,
                    contentType: value['contentType'] as String,
                  ),
                  _crypto,
                );
                final image = await _requireApi().uploadImage(
                  encrypted,
                  name,
                  'application/octet-stream',
                  conversationId: value['conversationId'] as String?,
                );
                images.add(image);
                imageNames.add(name);
              }
            }
            media = null;
            bytes = null;
          }
        }
      });
      await _persistLocal();
      await _prepareSearchIndex();
      return added;
    } catch (e) {
      if (added > 0) {
        throw StateError(
          'Restore stopped after $added additions: $e. Retry with the same '
          'files to continue; existing items are preserved.',
        );
      }
      rethrow;
    } finally {
      busy = false;
      _notifyChanged();
    }
  }
}

Stream<Map<String, dynamic>> _backupMediaRecords(
  Map<String, dynamic> metadata,
  List<int> bytes,
) async* {
  yield {
    'type': 'media',
    'value': {...metadata, 'length': bytes.length},
  };
  const chunkSize = 256 * 1024;
  for (var start = 0; start < bytes.length; start += chunkSize) {
    yield {
      'type': 'bytes',
      'value': base64Encode(
        bytes.sublist(start, math.min(start + chunkSize, bytes.length)),
      ),
    };
  }
  yield {'type': 'media-end'};
}

class _BackupValidation {
  bool library = false;
  bool hasImages = false;
  int? mediaLength;
  int received = 0;
  final ids = <String>{};
  final recordings = <String>{};

  void add(Map<String, dynamic> record) {
    final type = record['type'];
    if (!library && type != 'library') {
      throw const FormatException('Missing backup library header.');
    }
    if (mediaLength != null) {
      if (type == 'bytes') {
        final data = base64Decode(record['value'] as String);
        received += data.length;
        if (data.isEmpty ||
            data.length > 256 * 1024 ||
            received > mediaLength!) {
          throw const FormatException('Invalid backup media length.');
        }
        return;
      }
      if (type != 'media-end' || received != mediaLength) {
        throw const FormatException('Incomplete backup media.');
      }
      mediaLength = null;
      return;
    }
    final value = Map<String, dynamic>.from(record['value'] as Map);
    if (type == 'library') {
      if (library || value['version'] != 1) {
        throw const FormatException('Unsupported backup library version.');
      }
      library = true;
      return;
    }
    final id = value['id'] as String;
    if (id.isEmpty || !ids.add('$type:${value['kind'] ?? ''}:$id')) {
      throw const FormatException('Duplicate or empty backup item ID.');
    }
    switch (type) {
      case 'participant':
        Participant.fromJson(value);
      case 'conversation':
        final conversation = Conversation.fromJson(value);
        if (conversation.source == 'audio') recordings.add(id);
      case 'relation':
        RelationEdge.fromJson(value);
      case 'saved-search':
        SavedSearch.fromJson(value);
      case 'media':
        final kind = value['kind'];
        if ((kind != 'audio' && kind != 'image') ||
            (kind == 'audio' && !recordings.contains(id)) ||
            value['fileName'] is! String ||
            value['contentType'] is! String ||
            value['length'] is! int ||
            (value['length'] as int) <= 0) {
          throw const FormatException('Invalid backup media.');
        }
        if (value['conversationId'] != null &&
            value['conversationId'] is! String) {
          throw const FormatException('Invalid image conversation ID.');
        }
        hasImages |= kind == 'image';
        mediaLength = value['length'] as int;
        received = 0;
      default:
        throw const FormatException('Unsupported backup record.');
    }
  }

  void finish() {
    if (!library || mediaLength != null) {
      throw const FormatException('Incomplete backup library.');
    }
  }
}
