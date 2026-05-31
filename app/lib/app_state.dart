import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'crypto_service.dart';
import 'models.dart';

class LifenizerAppState extends ChangeNotifier {
  final Uuid _uuid = const Uuid();
  final VaultCrypto _crypto = VaultCrypto();

  String apiBaseUrl = 'http://127.0.0.1:5075';
  String deviceId = const Uuid().v4();
  AuthSession? session;
  LifenizerApiClient? _api;
  int syncCursor = 0;
  bool busy = false;
  String? status;
  String? error;

  final List<Participant> participants = [];
  final List<Conversation> conversations = [];
  final List<RelationEdge> relations = [];
  final List<SavedSearch> savedSearches = [];
  final List<ImportCapability> importCapabilities = [];

  bool get isAuthenticated => session != null && _crypto.isUnlocked;

  Future<void> login({
    required String baseUrl,
    required String email,
    required String passphrase,
  }) async {
    await _run(() async {
      apiBaseUrl = baseUrl.trim().isEmpty ? apiBaseUrl : baseUrl.trim();
      final anonymous = LifenizerApiClient(baseUrl: apiBaseUrl);
      final auth = await anonymous.devLogin(
        email: email.trim(),
        displayName: email.split('@').first,
      );
      await _crypto.unlock(
        email: email.trim().toLowerCase(),
        passphrase: passphrase,
        vaultSalt: auth.vaultSalt,
      );
      session = auth;
      _api = anonymous.authenticated(auth.authToken);
      syncCursor = 0;
      participants.clear();
      conversations.clear();
      relations.clear();
      savedSearches.clear();
      importCapabilities
        ..clear()
        ..addAll(await anonymous.importCapabilities());
      await pullSync();
      status = 'Vault unlocked';
    });
  }

  Future<void> pullSync() async {
    final api = _requireApi();
    final pulled = await api.pull(syncCursor);
    for (final envelope in pulled.envelopes) {
      final json = await _crypto.decryptJson(
        cipherText: envelope.cipherText,
        nonce: envelope.nonce,
      );
      _applyEntity(envelope.entityType, json);
    }
    syncCursor = pulled.cursor;
    notifyListeners();
  }

  List<Conversation> search(
    String query, {
    String? source,
    String? participantId,
    String? tag,
    bool favoritesOnly = false,
  }) {
    final normalized = query.trim().toLowerCase();
    final normalizedSource = _cleanFilter(source);
    final normalizedParticipantId = _cleanFilter(participantId);
    final normalizedTag = _cleanFilter(tag)?.toLowerCase();
    final results = conversations.where((conversation) {
      if (normalizedSource != null && conversation.source != normalizedSource) {
        return false;
      }
      if (normalizedParticipantId != null &&
          !conversation.participantIds.contains(normalizedParticipantId)) {
        return false;
      }
      if (normalizedTag != null &&
          !conversation.tags.any(
            (item) => item.toLowerCase() == normalizedTag,
          )) {
        return false;
      }
      if (favoritesOnly && !conversation.isFavorite) {
        return false;
      }
      if (normalized.isEmpty) {
        return true;
      }
      final participantText = conversation.participantIds
          .map(participantName)
          .join(' ')
          .toLowerCase();
      final relationText = relations
          .where(
            (relation) => relation.evidenceConversationId == conversation.id,
          )
          .map(
            (relation) =>
                '${relation.subject} ${relation.relation} ${relation.object}',
          )
          .join(' ')
          .toLowerCase();
      final haystack =
          '${conversation.searchableText} $participantText $relationText';
      if (haystack.contains(normalized)) {
        return true;
      }
      return _fuzzyMatch(normalized, haystack);
    }).toList();
    return results..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  /// Page-friendly view of [search]. Returns the slice of results for the
  /// requested [page] (1-based) using [pageSize] entries per page, along with
  /// the total number of matches so the UI can render pagers/counters.
  ConversationSearchPage searchPaged(
    String query, {
    String? source,
    String? participantId,
    String? tag,
    bool favoritesOnly = false,
    int page = 1,
    int pageSize = 10,
  }) {
    final results = search(
      query,
      source: source,
      participantId: participantId,
      tag: tag,
      favoritesOnly: favoritesOnly,
    );
    if (pageSize <= 0) {
      return ConversationSearchPage(
        items: results,
        total: results.length,
        page: 1,
        pageSize: results.length,
      );
    }
    final clampedPage = page < 1 ? 1 : page;
    final start = (clampedPage - 1) * pageSize;
    if (start >= results.length) {
      return ConversationSearchPage(
        items: const [],
        total: results.length,
        page: clampedPage,
        pageSize: pageSize,
      );
    }
    final end = (start + pageSize) > results.length
        ? results.length
        : start + pageSize;
    return ConversationSearchPage(
      items: results.sublist(start, end),
      total: results.length,
      page: clampedPage,
      pageSize: pageSize,
    );
  }

  // Fuzzy-match every whitespace token of [query] against [haystack]. A token
  // matches if it is a substring of any haystack token OR within Levenshtein
  // edit distance 1 (2 for tokens with >=6 chars). Mirrors the spirit of the
  // legacy LucenceSearch fuzzy fallback while staying client-side / E2EE.
  bool _fuzzyMatch(String query, String haystack) {
    final queryTokens = query
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    if (queryTokens.isEmpty) {
      return true;
    }
    final haystackTokens = haystack
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    if (haystackTokens.isEmpty) {
      return false;
    }
    for (final token in queryTokens) {
      if (token.length < 3) {
        if (!haystackTokens.any((candidate) => candidate.contains(token))) {
          return false;
        }
        continue;
      }
      final maxDistance = token.length >= 6 ? 2 : 1;
      final matched = haystackTokens.any((candidate) {
        if (candidate.contains(token)) {
          return true;
        }
        if ((candidate.length - token.length).abs() > maxDistance) {
          return false;
        }
        return _editDistance(token, candidate, maxDistance) <= maxDistance;
      });
      if (!matched) {
        return false;
      }
    }
    return true;
  }

  int _editDistance(String left, String right, int limit) {
    final leftLength = left.length;
    final rightLength = right.length;
    if ((leftLength - rightLength).abs() > limit) {
      return limit + 1;
    }
    var previous = List<int>.generate(rightLength + 1, (index) => index);
    var current = List<int>.filled(rightLength + 1, 0);
    for (var i = 1; i <= leftLength; i++) {
      current[0] = i;
      var rowMin = current[0];
      for (var j = 1; j <= rightLength; j++) {
        final cost = left.codeUnitAt(i - 1) == right.codeUnitAt(j - 1) ? 0 : 1;
        final deletion = previous[j] + 1;
        final insertion = current[j - 1] + 1;
        final substitution = previous[j - 1] + cost;
        var min = deletion < insertion ? deletion : insertion;
        if (substitution < min) {
          min = substitution;
        }
        current[j] = min;
        if (min < rowMin) {
          rowMin = min;
        }
      }
      if (rowMin > limit) {
        return limit + 1;
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[rightLength];
  }

  List<String> get availableSources {
    final sources = conversations
        .map((conversation) => conversation.source)
        .toSet()
        .toList();
    sources.sort();
    return sources;
  }

  List<String> get allTags {
    final tags = conversations
        .expand((conversation) => conversation.tags)
        .toSet()
        .toList();
    tags.sort();
    return tags;
  }

  VaultInsights get insights {
    final sourceCounts = <String, int>{};
    final participantCounts = <String, int>{};
    final timelineCounts = <DateTime, int>{};
    var totalSegments = 0;
    var totalArtifacts = 0;

    for (final conversation in conversations) {
      sourceCounts.update(
        conversation.source,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      totalSegments += conversation.segments.length;
      totalArtifacts += conversation.artifactNames.length;
      final day = DateTime.utc(
        conversation.startedAt.toUtc().year,
        conversation.startedAt.toUtc().month,
        conversation.startedAt.toUtc().day,
      );
      timelineCounts.update(day, (count) => count + 1, ifAbsent: () => 1);
      for (final participantId in conversation.participantIds.toSet()) {
        participantCounts.update(
          participantId,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }

    final sourceFacets =
        sourceCounts.entries
            .map((entry) => SourceFacet(source: entry.key, count: entry.value))
            .toList()
          ..sort((left, right) => right.count.compareTo(left.count));
    final participantFacets =
        participantCounts.entries
            .map(
              (entry) => ParticipantFacet(
                participant: participants.firstWhere(
                  (participant) => participant.id == entry.key,
                  orElse: () =>
                      Participant(id: entry.key, displayName: entry.key),
                ),
                count: entry.value,
              ),
            )
            .toList()
          ..sort((left, right) => right.count.compareTo(left.count));
    final timeline =
        timelineCounts.entries
            .map((entry) => TimelineBucket(day: entry.key, count: entry.value))
            .toList()
          ..sort((left, right) => right.day.compareTo(left.day));

    return VaultInsights(
      totalConversations: conversations.length,
      totalSegments: totalSegments,
      totalArtifacts: totalArtifacts,
      sourceFacets: sourceFacets,
      participantFacets: participantFacets,
      timeline: timeline,
      tags: allTags,
    );
  }

  String participantName(String id) {
    return participants
        .firstWhere(
          (participant) => participant.id == id,
          orElse: () => Participant(id: id, displayName: id),
        )
        .displayName;
  }

  Future<List<String>> ensureParticipants(String input) async {
    return ensureParticipantNames(
      input
          .split(',')
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty),
    );
  }

  Future<List<String>> ensureParticipantNames(Iterable<String> input) async {
    final names = input
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
    final ids = <String>[];
    for (final name in names) {
      final existing = participants.where(
        (participant) =>
            participant.displayName.toLowerCase() == name.toLowerCase(),
      );
      if (existing.isNotEmpty) {
        ids.add(existing.first.id);
        continue;
      }
      final participant = Participant(id: _uuid.v4(), displayName: name);
      participants.add(participant);
      ids.add(participant.id);
      await _pushEntity('participant', participant.id, participant.toJson());
    }
    notifyListeners();
    return ids;
  }

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
      await _ingestNormalizedImport(normalized);
      status = '${normalized.message} Encrypted and synced.';
    });
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
        notifyListeners();
    }
  }

  Future<void> addManualText({
    required String title,
    required String participantNames,
    required String text,
    String source = 'manual-text',
  }) async {
    if (text.trim().isEmpty) return;
    await _run(() async {
      final participantIds = await ensureParticipants(participantNames);
      final conversation = Conversation(
        id: _uuid.v4(),
        title: title.trim().isEmpty ? 'Imported conversation' : title.trim(),
        source: source,
        participantIds: participantIds,
        tags: _suggestTags(source: source, title: title, text: text),
        segments: [ConversationSegment(id: _uuid.v4(), text: text.trim())],
      );
      conversations.add(conversation);
      await _pushEntity('conversation', conversation.id, conversation.toJson());
      status = 'Conversation encrypted and synced';
    });
  }

  Future<void> addFileArtifact({
    required String participantNames,
    required PlatformFile file,
  }) async {
    await _run(() async {
      final participantIds = await ensureParticipants(participantNames);
      final conversation = Conversation(
        id: _uuid.v4(),
        title: file.name,
        source: file.extension == 'pdf' ? 'scanned-pdf' : 'audio',
        participantIds: participantIds,
        artifactNames: [file.name],
        tags: _suggestTags(
          source: file.extension == 'pdf' ? 'scanned-pdf' : 'audio',
          title: file.name,
          artifactNames: [file.name],
        ),
        segments: [
          ConversationSegment(
            id: _uuid.v4(),
            text: 'Imported artifact ${file.name} (${file.size} bytes)',
          ),
        ],
      );
      conversations.add(conversation);
      await _pushEntity('conversation', conversation.id, conversation.toJson());
      status = 'Artifact metadata encrypted and synced';
    });
  }

  Future<void> addRecordingConversation({
    required String title,
    required String participantNames,
    required List<String> segmentTexts,
  }) async {
    final cleaned = segmentTexts
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (cleaned.isEmpty) return;
    await _run(() async {
      final participantIds = await ensureParticipants(participantNames);
      final conversation = Conversation(
        id: _uuid.v4(),
        title: title.trim().isEmpty ? 'Live recording session' : title.trim(),
        source: 'live-recording',
        participantIds: participantIds,
        tags: _suggestTags(
          source: 'live-recording',
          title: title,
          text: cleaned.join('\n'),
        ),
        segments: [
          for (var i = 0; i < cleaned.length; i++)
            ConversationSegment(
              id: _uuid.v4(),
              text: cleaned[i],
              offsetMs: i * 15000,
            ),
        ],
      );
      conversations.add(conversation);
      await _pushEntity('conversation', conversation.id, conversation.toJson());
      status = 'Recording session encrypted and synced';
    });
  }

  Future<void> extractRelations(Conversation conversation) async {
    await _run(() async {
      final api = _requireApi();
      final extracted = await api.extractRelations(
        text: conversation.segments.map((segment) => segment.text).join('\n'),
        conversationId: conversation.id,
      );
      for (final relation in extracted) {
        if (relations.any((existing) => existing.id == relation.id)) continue;
        relations.add(relation);
        await _pushEntity('relation', relation.id, relation.toJson());
      }
      status = extracted.isEmpty
          ? 'No relations detected'
          : '${extracted.length} relation(s) encrypted and synced';
    });
  }

  Future<void> addSavedSearch({
    required String title,
    String query = '',
    String? source,
    String? participantId,
    String? tag,
  }) async {
    await _run(() async {
      final savedSearch = SavedSearch(
        id: _uuid.v4(),
        title: title.trim().isEmpty ? 'Saved search' : title.trim(),
        query: query.trim(),
        source: _cleanFilter(source),
        participantId: _cleanFilter(participantId),
        tag: _cleanFilter(tag),
      );
      savedSearches.removeWhere((item) => item.id == savedSearch.id);
      savedSearches.add(savedSearch);
      await _pushEntity('saved-search', savedSearch.id, savedSearch.toJson());
      status = 'Search saved and encrypted';
    });
  }

  Future<void> _pushEntity(
    String entityType,
    String entityId,
    Map<String, dynamic> json,
  ) async {
    final payload = await _crypto.encryptJson(json);
    final envelope = SyncEnvelope(
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
    );
    syncCursor = await _requireApi().push([envelope]);
  }

  Future<void> _ingestNormalizedImport(NormalizedImportResult result) async {
    for (final normalized in result.conversations) {
      final participantIds = await ensureParticipantNames(
        normalized.participantNames,
      );
      final nameToId = <String, String>{};
      for (final participant in participants) {
        nameToId[participant.displayName.toLowerCase()] = participant.id;
      }
      final conversation = Conversation(
        id: _uuid.v4(),
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
      await _pushEntity('conversation', conversation.id, conversation.toJson());
    }
  }

  void _applyEntity(String entityType, Map<String, dynamic> json) {
    switch (entityType) {
      case 'participant':
        final participant = Participant.fromJson(json);
        participants.removeWhere((item) => item.id == participant.id);
        participants.add(participant);
        break;
      case 'conversation':
        final conversation = Conversation.fromJson(json);
        conversations.removeWhere((item) => item.id == conversation.id);
        conversations.add(conversation);
        break;
      case 'relation':
        final relation = RelationEdge.fromJson(json);
        relations.removeWhere((item) => item.id == relation.id);
        relations.add(relation);
        break;
      case 'saved-search':
        final savedSearch = SavedSearch.fromJson(json);
        savedSearches.removeWhere((item) => item.id == savedSearch.id);
        savedSearches.add(savedSearch);
        break;
    }
  }

  List<String> _suggestTags({
    required String source,
    String? title,
    String? text,
    Iterable<String> artifactNames = const [],
  }) {
    final content = [
      source,
      title,
      text,
      ...artifactNames,
    ].whereType<String>().join(' ').toLowerCase();
    final tags = <String>{source};
    if (source.contains('whatsapp') ||
        source.contains('telegram') ||
        source.contains('signal') ||
        source.contains('discord') ||
        source == 'manual-text') {
      tags.add('chat');
    }
    if (source.contains('audio') || source.contains('recording')) {
      tags.add('recording');
    }
    if (source.contains('pdf') ||
        source.contains('paperless') ||
        content.contains('invoice')) {
      tags.add('documents');
    }
    if (source.contains('youtube') || content.contains('transcript')) {
      tags.add('transcript');
    }
    if (source.contains('browser') || content.contains('http')) {
      tags.add('web');
    }
    if (content.contains('relation') ||
        content.contains('brother') ||
        content.contains('sister')) {
      tags.add('people');
    }
    return tags
        .map(_normalizeTag)
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  String _normalizeTag(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  String? _cleanFilter(String? value) {
    final cleaned = value?.trim();
    return cleaned == null || cleaned.isEmpty ? null : cleaned;
  }

  Future<void> _run(Future<void> Function() action) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (exception) {
      error = exception.toString();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  LifenizerApiClient _requireApi() {
    final api = _api;
    if (api == null) throw StateError('Not logged in.');
    return api;
  }
}
