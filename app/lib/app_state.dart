import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'crypto_service.dart';
import 'package:image_picker/image_picker.dart';

import 'image_service.dart';
import 'models.dart';
import 'services/search_criteria.dart';
import 'services/search_scorer.dart';
import 'services/search_service.dart';

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

  _ConversationSearchIndex? _searchIndex;
  bool _searchIndexDirty = true;
  int _indexedConversationCount = -1;
  int _indexedRelationCount = -1;
  int _indexedParticipantCount = -1;

  String? _lastSearchQuery;
  DateTime? _lastSearchAt;
  List<String> _lastSearchTopConversationIds = const [];
  final Map<String, int> _sessionQueryFrequency = <String, int>{};

  QuotaStatus? quotaStatus;
  final List<ImageItem> images = [];

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
      _markSearchIndexDirty();
      _lastSearchQuery = null;
      _lastSearchAt = null;
      _lastSearchTopConversationIds = const [];
      _sessionQueryFrequency.clear();
      savedSearches.clear();
      importCapabilities
        ..clear()
        ..addAll(await anonymous.importCapabilities());
      await pullSync();
      status = 'Vault unlocked';
      refreshQuota().ignore();
    });
  }

  /// Test-only hook: unlocks the local vault crypto and installs an
  /// already-authenticated API [client] directly, without [login]'s network
  /// round trips (dev-login, capability fetch, initial sync pull).
  ///
  /// This lets tests exercise real app-state methods (e.g.
  /// [importAudioBytes]) against a stubbed `http.Client` — see
  /// `package:http/testing.dart`'s `MockClient` — instead of a live
  /// backend. Not used by production code paths.
  Future<void> debugAuthenticateForTesting(
    LifenizerApiClient client, {
    String email = 'test@example.test',
    String passphrase = 'test-passphrase',
    String vaultSalt = 'test-salt',
  }) async {
    await _crypto.unlock(
      email: email,
      passphrase: passphrase,
      vaultSalt: vaultSalt,
    );
    _api = client;
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

  // ---------------------------------------------------------------------------
  // Quota & images
  // ---------------------------------------------------------------------------

  Future<void> refreshQuota() async {
    final api = _requireApi();
    try {
      quotaStatus = await api.getQuotaStatus();
      notifyListeners();
    } catch (_) {
      // Non-fatal: quota info will be unavailable but app continues.
    }
  }

  Future<void> refreshImages({String? conversationId}) async {
    final api = _requireApi();
    final fetched = await api.listImages(conversationId: conversationId);
    if (conversationId == null) {
      images
        ..clear()
        ..addAll(fetched);
    } else {
      images.removeWhere((img) => img.conversationId == conversationId);
      images.addAll(fetched);
    }
    notifyListeners();
  }

  /// Picks an image from [source], compresses it, checks local quota, uploads
  /// it, and refreshes quota.  Throws [QuotaExceededException] if the local
  /// quota check fails before the upload is attempted.
  Future<ImageItem?> captureAndUploadImage({
    required ImageSource source,
    String? conversationId,
  }) async {
    final captured = source == ImageSource.camera
        ? await ImageService.captureFromCamera()
        : await ImageService.pickFromGallery();
    if (captured == null) return null;

    // Local quota pre-check.
    final quota = quotaStatus;
    if (quota != null &&
        quota.usedBytes + captured.bytes.length > quota.limitBytes) {
      throw QuotaExceededException(
        'Storage quota exceeded. Please upgrade your plan.',
      );
    }

    final api = _requireApi();
    final item = await api.uploadImage(
      captured.bytes,
      captured.fileName,
      captured.contentType,
      conversationId: conversationId,
    );
    images.add(item);
    notifyListeners();
    // Refresh quota after upload.
    refreshQuota().ignore();
    return item;
  }

  Future<void> deleteImage(String id) async {
    final api = _requireApi();
    await api.deleteImage(id);
    images.removeWhere((img) => img.id == id);
    notifyListeners();
    refreshQuota().ignore();
  }

  String imageUrl(String id) => _requireApi().imageUrl(id);

  Map<String, String> get authHeaders {
    final token = session?.authToken;
    if (token == null) return const {};
    return {'authorization': 'Bearer $token'};
  }

  Future<String> checkoutUrl(String plan) =>
      _requireApi().createCheckoutUrl(plan);

  /// Searches conversations based on query and optional filters.
  ///
  /// Supports temporal intent parsing (e.g., "today", "last week"), semantic
  /// token filtering, vector similarity scoring, and search continuity
  /// (carry-over tokens from the previous search if related).
  ///
  /// Parameters:
  /// - [query]: Search query string (normalized internally)
  /// - [source]: Optional source filter (e.g., "slack", "email")
  /// - [participantId]: Optional participant ID filter
  /// - [tag]: Optional tag filter
  /// - [favoritesOnly]: If true, only return favorited conversations
  /// - [useVector]: If true, include TF-IDF vector similarity in scoring
  /// - [from]/[to]: Optional inclusive date-range filter (calendar dates in
  ///   the caller's local timezone). A conversation matches when its time
  ///   span overlaps the range.
  ///
  /// Returns: Sorted list of matching conversations (highest relevance first)
  List<Conversation> search(
    String query, {
    String? source,
    String? participantId,
    String? tag,
    bool favoritesOnly = false,
    bool useVector = true,
    DateTime? from,
    DateTime? to,
    int? maxResults,
  }) {
    _ensureSearchIndex();
    final index = _searchIndex;
    if (index == null) {
      return const [];
    }

    // Build search criteria and scorer
    final criteria = SearchCriteria(
      query: query,
      source: source,
      participantId: participantId,
      tag: tag,
      favoritesOnly: favoritesOnly,
      useVector: useVector,
      from: from,
      to: to,
    );

    final now = DateTime.now().toUtc();
    final temporalIntent = _TemporalIntent.tryParse(criteria.normalized, now);

    // Prepare query tokens
    final queryTokens = _semanticTokens(
      _ConversationSearchIndex.tokenize(criteria.normalized),
    );
    final semanticQuery = queryTokens.join(' ');

    // Determine which previous tokens to carry over
    final previousQuery = _lastSearchQuery;
    final previousTokens = previousQuery == null
        ? const <String>[]
        : _semanticTokens(_ConversationSearchIndex.tokenize(previousQuery));

    final scorer = SearchScorer(
      temporalIntent: temporalIntent,
      normalizedQuery: criteria.normalized,
      now: now,
      previousQuery: previousQuery,
      lastSearchAt: _lastSearchAt,
      lastSearchTopIds: _lastSearchTopConversationIds,
      sessionQueryFrequency: _sessionQueryFrequency,
    );

    final effectiveTokens = <String>[
      ...queryTokens,
      if (scorer.shouldCarryPreviousQuery(previousTokens, queryTokens))
        ...previousTokens,
    ];

    // Execute search using service
    final searchService = SearchService(index);
    final results = searchService
        .rankConversations(
          criteria,
          scorer,
          effectiveTokens,
          semanticQuery,
          maxResults: maxResults,
        )
        .cast<Conversation>();

    _updateSearchContext(criteria.normalized, results, now);
    return results;
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
    bool useVector = true,
    DateTime? from,
    DateTime? to,
    int page = 1,
    int pageSize = 10,
  }) {
    final results = search(
      query,
      source: source,
      participantId: participantId,
      tag: tag,
      favoritesOnly: favoritesOnly,
      useVector: useVector,
      from: from,
      to: to,
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
    var addedParticipant = false;
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
      addedParticipant = true;
      ids.add(participant.id);
      await _pushEntity('participant', participant.id, participant.toJson());
    }
    if (addedParticipant) {
      _markSearchIndexDirty();
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
    notifyListeners();
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

  Future<void> importSharedPayload({
    String? fileName,
    String? mimeType,
    String? text,
    List<int>? bytes,
    Map<String, String> metadata = const {},
  }) async {
    final normalizedName = (fileName ?? '').trim();
    final normalizedMime = (mimeType ?? '').trim().toLowerCase();
    final normalizedText = text?.trim();
    final lowerName = normalizedName.toLowerCase();

    String source = 'manual-text';
    if (lowerName.endsWith('.mbox')) {
      source = 'mbox';
    } else if (lowerName.endsWith('.patch') ||
        lowerName.endsWith('.diff') ||
        lowerName.contains('git')) {
      source = 'git';
    } else if (lowerName.contains('bookmark')) {
      source = 'bookmarks';
    } else if (lowerName.contains('google') && lowerName.contains('search')) {
      source = 'google-search-history';
    } else if (lowerName.contains('history')) {
      source = 'browser-history';
    } else if (lowerName.contains('backup') ||
        lowerName.endsWith('.lifenizerbackup')) {
      source = 'lifenizer-backup';
    } else if (normalizedMime.startsWith('audio/')) {
      source = 'audio';
    } else if (normalizedMime.startsWith('image/') ||
        normalizedMime == 'application/pdf') {
      source = 'scanned-pdf';
    } else if (normalizedMime == 'text/uri-list' ||
        normalizedText?.startsWith('http') == true) {
      source = 'browser-capture';
    }

    final payloadBase64 = bytes == null || bytes.isEmpty
        ? null
        : base64Encode(bytes);

    await importSource(
      source: source,
      title: normalizedName.isEmpty ? 'Shared import' : normalizedName,
      text: payloadBase64 == null ? normalizedText : null,
      originalFileName: normalizedName.isEmpty ? null : normalizedName,
      mimeType: normalizedMime.isEmpty ? null : normalizedMime,
      metadata: {...metadata, 'shared': 'true'},
      payloadBase64: payloadBase64,
    );
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
      _markSearchIndexDirty();
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
      _markSearchIndexDirty();
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
      _markSearchIndexDirty();
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
      var addedRelation = false;
      for (final relation in extracted) {
        if (relations.any((existing) => existing.id == relation.id)) continue;
        relations.add(relation);
        addedRelation = true;
        await _pushEntity('relation', relation.id, relation.toJson());
      }
      if (addedRelation) {
        _markSearchIndexDirty();
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
    DateTime? from,
    DateTime? to,
  }) async {
    await _run(() async {
      final savedSearch = SavedSearch(
        id: _uuid.v4(),
        title: title.trim().isEmpty ? 'Saved search' : title.trim(),
        query: query.trim(),
        source: _cleanFilter(source),
        participantId: _cleanFilter(participantId),
        tag: _cleanFilter(tag),
        from: from,
        to: to,
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
    var addedConversation = false;
    for (final normalized in result.conversations) {
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
      addedConversation = true;
      await _pushEntity('conversation', conversation.id, conversation.toJson());
    }
    if (addedConversation) {
      _markSearchIndexDirty();
    }
  }

  void _applyEntity(String entityType, Map<String, dynamic> json) {
    switch (entityType) {
      case 'participant':
        final participant = Participant.fromJson(json);
        participants.removeWhere((item) => item.id == participant.id);
        participants.add(participant);
        _markSearchIndexDirty();
        break;
      case 'conversation':
        final conversation = Conversation.fromJson(json);
        conversations.removeWhere((item) => item.id == conversation.id);
        conversations.add(conversation);
        _markSearchIndexDirty();
        break;
      case 'relation':
        final relation = RelationEdge.fromJson(json);
        relations.removeWhere((item) => item.id == relation.id);
        relations.add(relation);
        _markSearchIndexDirty();
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

  void _markSearchIndexDirty() {
    _searchIndexDirty = true;
  }

  List<String> _semanticTokens(List<String> tokens) {
    if (tokens.isEmpty) {
      return tokens;
    }

    const controlTerms = {
      'same',
      'time',
      'last',
      'year',
      'today',
      'yesterday',
      'week',
      'month',
      'morning',
      'afternoon',
      'evening',
      'night',
      'tonight',
      'search',
      'previous',
      'before',
      'again',
      'this',
      'as',
    };

    final filtered = tokens
        .where((token) => !controlTerms.contains(token))
        .toList(growable: false);
    return filtered.isEmpty ? tokens : filtered;
  }

  String? _cleanFilter(String? value) {
    final cleaned = value?.trim();
    return cleaned == null || cleaned.isEmpty ? null : cleaned;
  }

  void _updateSearchContext(
    String normalized,
    List<Conversation> results,
    DateTime now,
  ) {
    if (normalized.isEmpty) {
      return;
    }

    _lastSearchQuery = normalized;
    _lastSearchAt = now;
    _lastSearchTopConversationIds = results
        .take(5)
        .map((item) => item.id)
        .toList(growable: false);
    _sessionQueryFrequency.update(
      normalized,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  void _ensureSearchIndex() {
    final needsRebuild =
        _searchIndexDirty ||
        _searchIndex == null ||
        _indexedConversationCount != conversations.length ||
        _indexedRelationCount != relations.length ||
        _indexedParticipantCount != participants.length;
    if (!needsRebuild) {
      return;
    }

    final participantById = <String, String>{
      for (final participant in participants)
        participant.id: participant.displayName.toLowerCase(),
    };
    final relationTextByConversation = <String, StringBuffer>{};
    for (final relation in relations) {
      final conversationId = relation.evidenceConversationId;
      if (conversationId == null || conversationId.isEmpty) {
        continue;
      }
      final bucket = relationTextByConversation.putIfAbsent(
        conversationId,
        StringBuffer.new,
      );
      if (bucket.isNotEmpty) {
        bucket.write(' ');
      }
      bucket
        ..write(relation.subject)
        ..write(' ')
        ..write(relation.relation)
        ..write(' ')
        ..write(relation.object);
    }

    _searchIndex = _ConversationSearchIndex.build(
      conversations: conversations,
      participantById: participantById,
      relationTextByConversation: relationTextByConversation.map(
        (key, value) => MapEntry(key, value.toString().toLowerCase()),
      ),
    );
    _searchIndexDirty = false;
    _indexedConversationCount = conversations.length;
    _indexedRelationCount = relations.length;
    _indexedParticipantCount = participants.length;
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

class _IndexedConversation {
  _IndexedConversation({
    required this.conversation,
    required this.haystack,
    required this.title,
    required this.source,
    required this.tagSet,
    required this.termFrequency,
    required this.vectorNorm,
  });

  final Conversation conversation;
  final String haystack;
  final String title;
  final String source;
  final Set<String> tagSet;
  final Map<String, int> termFrequency;
  final double vectorNorm;
}

class _ConversationSearchIndex {
  _ConversationSearchIndex({
    required this.documents,
    required this.invertedIndex,
    required this.idf,
    required this.allConversationIds,
  });

  final Map<String, _IndexedConversation> documents;
  final Map<String, Set<String>> invertedIndex;
  final Map<String, double> idf;
  final Set<String> allConversationIds;

  static _ConversationSearchIndex build({
    required List<Conversation> conversations,
    required Map<String, String> participantById,
    required Map<String, String> relationTextByConversation,
  }) {
    final docs = <String, _IndexedConversation>{};
    final inverted = <String, Set<String>>{};

    for (final conversation in conversations) {
      final participantText = conversation.participantIds
          .map((id) => participantById[id] ?? id.toLowerCase())
          .join(' ');
      final relationText = relationTextByConversation[conversation.id] ?? '';
      final haystack =
          '${conversation.searchableText} $participantText $relationText'
              .trim();
      final tokens = tokenize(haystack);
      final termFrequency = <String, int>{};
      for (final token in tokens) {
        termFrequency.update(token, (count) => count + 1, ifAbsent: () => 1);
      }

      for (final token in termFrequency.keys) {
        inverted.putIfAbsent(token, () => <String>{}).add(conversation.id);
      }

      docs[conversation.id] = _IndexedConversation(
        conversation: conversation,
        haystack: haystack,
        title: conversation.title.toLowerCase(),
        source: conversation.source.toLowerCase(),
        tagSet: conversation.tags.map((tag) => tag.toLowerCase()).toSet(),
        termFrequency: termFrequency,
        vectorNorm: 0,
      );
    }

    final docCount = docs.length;
    final idf = <String, double>{};
    for (final entry in inverted.entries) {
      final df = entry.value.length;
      // Smoothed IDF to avoid division by zero and dampen very common terms.
      idf[entry.key] = math.log((1 + docCount) / (1 + df)) + 1.0;
    }

    final docsWithNorm = <String, _IndexedConversation>{};
    for (final entry in docs.entries) {
      final document = entry.value;
      var normSquared = 0.0;
      for (final tfEntry in document.termFrequency.entries) {
        final tokenIdf = idf[tfEntry.key] ?? 0.0;
        final weight = tfEntry.value * tokenIdf;
        normSquared += weight * weight;
      }
      docsWithNorm[entry.key] = _IndexedConversation(
        conversation: document.conversation,
        haystack: document.haystack,
        title: document.title,
        source: document.source,
        tagSet: document.tagSet,
        termFrequency: document.termFrequency,
        vectorNorm: math.sqrt(normSquared),
      );
    }

    return _ConversationSearchIndex(
      documents: docsWithNorm,
      invertedIndex: inverted,
      idf: idf,
      allConversationIds: docsWithNorm.keys.toSet(),
    );
  }

  Set<String> lookupCandidates(List<String> queryTokens) {
    if (queryTokens.isEmpty) {
      return allConversationIds;
    }

    final candidates = <String>{};
    for (final token in queryTokens) {
      final direct = invertedIndex[token];
      if (direct != null) {
        candidates.addAll(direct);
        continue;
      }

      // Fuzzy fallback in index-space, for typo tolerance AND partial-word
      // matches (e.g. typing "ali" should surface a participant named
      // "Alice" even though "ali" isn't itself an indexed token).
      //
      // The substring check is tried first, unconditionally, mirroring
      // SearchService._fuzzyMatch's per-document gate. Without it, a short
      // partial query like "ali" only ever finds "alice" when the rest of
      // the vault happens to contain no other token that's edit-distance-
      // close to "ali" (e.g. the common word "all") — as soon as a vault of
      // any realistic size contains such a token, the candidate set stops
      // being empty, the "fall back to every conversation" safety net below
      // no longer kicks in, and the actual match is silently dropped. Using
      // the same substring-first rule as the per-document gate here keeps
      // the two matching stages consistent.
      for (final entry in invertedIndex.entries) {
        final candidateToken = entry.key;
        if (candidateToken.contains(token)) {
          candidates.addAll(entry.value);
          continue;
        }
        if ((candidateToken.length - token.length).abs() > 2) {
          continue;
        }
        final limit = token.length >= 6 ? 2 : 1;
        if (_boundedDistance(token, candidateToken, limit) <= limit) {
          candidates.addAll(entry.value);
        }
      }
    }

    return candidates.isEmpty ? allConversationIds : candidates;
  }

  double lexicalScore(
    _IndexedConversation document,
    String normalizedQuery,
    List<String> queryTokens,
  ) {
    if (normalizedQuery.isEmpty) {
      return 0;
    }

    var score = 0.0;
    if (document.haystack.contains(normalizedQuery)) {
      score += 8.0;
    }

    for (final token in queryTokens) {
      final tf = document.termFrequency[token] ?? 0;
      if (tf > 0) {
        score += 2.0 + (tf * 1.2);
      }
      if (document.title.contains(token)) {
        score += 3.0;
      }
      if (document.source.contains(token)) {
        score += 1.0;
      }
      if (document.tagSet.contains(token)) {
        score += 1.5;
      }
    }

    return score;
  }

  double vectorScore(_IndexedConversation document, List<String> queryTokens) {
    if (queryTokens.isEmpty || document.vectorNorm <= 0) {
      return 0;
    }

    final queryTf = <String, int>{};
    for (final token in queryTokens) {
      queryTf.update(token, (count) => count + 1, ifAbsent: () => 1);
    }

    var queryNormSquared = 0.0;
    var dot = 0.0;
    for (final entry in queryTf.entries) {
      final tokenIdf = idf[entry.key] ?? 0.0;
      if (tokenIdf <= 0) {
        continue;
      }

      final queryWeight = entry.value * tokenIdf;
      queryNormSquared += queryWeight * queryWeight;

      final docTf = document.termFrequency[entry.key];
      if (docTf == null) {
        continue;
      }
      final docWeight = docTf * tokenIdf;
      dot += queryWeight * docWeight;
    }

    if (queryNormSquared <= 0 || dot <= 0) {
      return 0;
    }

    final queryNorm = math.sqrt(queryNormSquared);
    return dot / (queryNorm * document.vectorNorm);
  }

  static List<String> tokenize(String text) {
    return text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
  }

  static int _boundedDistance(String left, String right, int limit) {
    if ((left.length - right.length).abs() > limit) {
      return limit + 1;
    }

    var previous = List<int>.generate(right.length + 1, (index) => index);
    var current = List<int>.filled(right.length + 1, 0);
    for (var i = 1; i <= left.length; i++) {
      current[0] = i;
      var rowMin = current[0];
      for (var j = 1; j <= right.length; j++) {
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

    return previous[right.length];
  }
}

class _TemporalIntent {
  const _TemporalIntent({
    required this.targetStart,
    required this.targetEnd,
    this.hourStart,
    this.hourEnd,
    this.weight = 1.0,
  });

  final DateTime targetStart;
  final DateTime targetEnd;
  final int? hourStart;
  final int? hourEnd;
  final double weight;

  static _TemporalIntent? tryParse(String normalizedQuery, DateTime nowUtc) {
    if (normalizedQuery.isEmpty) {
      return null;
    }

    DateTime start;
    DateTime end;
    double weight = 1.0;

    final hasLastYear = normalizedQuery.contains('last year');
    final hasSameTimeLastYear =
        normalizedQuery.contains('same time last year') ||
        normalizedQuery.contains('this time last year') ||
        normalizedQuery.contains('on this day last year') ||
        normalizedQuery.contains('same date last year');

    if (hasSameTimeLastYear) {
      final anchor = _safeShiftYear(nowUtc, -1);
      start = DateTime.utc(
        anchor.year,
        anchor.month,
        anchor.day,
      ).subtract(const Duration(days: 1));
      end = DateTime.utc(
        anchor.year,
        anchor.month,
        anchor.day,
      ).add(const Duration(days: 1, hours: 23, minutes: 59, seconds: 59));
      weight = 2.6;
    } else if (hasLastYear) {
      final year = nowUtc.year - 1;
      start = DateTime.utc(year, 1, 1);
      end = DateTime.utc(year, 12, 31, 23, 59, 59);
      weight = 1.6;
    } else if (normalizedQuery.contains('yesterday')) {
      final yesterday = nowUtc.subtract(const Duration(days: 1));
      start = DateTime.utc(yesterday.year, yesterday.month, yesterday.day);
      end = DateTime.utc(
        yesterday.year,
        yesterday.month,
        yesterday.day,
        23,
        59,
        59,
      );
      weight = 1.9;
    } else if (normalizedQuery.contains('today')) {
      start = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
      end = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day, 23, 59, 59);
      weight = 1.6;
    } else if (normalizedQuery.contains('last week')) {
      start = nowUtc.subtract(const Duration(days: 7));
      end = nowUtc;
      weight = 1.4;
    } else if (normalizedQuery.contains('last month')) {
      start = nowUtc.subtract(const Duration(days: 30));
      end = nowUtc;
      weight = 1.3;
    } else {
      return null;
    }

    final hourRange = _parseHourRange(normalizedQuery);
    return _TemporalIntent(
      targetStart: start,
      targetEnd: end,
      hourStart: hourRange?.$1,
      hourEnd: hourRange?.$2,
      weight: weight,
    );
  }

  double alignmentScore(DateTime documentTime) {
    final doc = documentTime.toUtc();
    final rangeStart = targetStart.toUtc();
    final rangeEnd = targetEnd.toUtc();
    final inRange = !doc.isBefore(rangeStart) && !doc.isAfter(rangeEnd);
    if (!inRange) {
      final distanceDays = doc.isBefore(rangeStart)
          ? rangeStart.difference(doc).inHours / 24.0
          : doc.difference(rangeEnd).inHours / 24.0;
      return math.exp(-(distanceDays / 21.0)) * 0.8;
    }

    var score = 2.0 * weight;
    if (hourStart != null && hourEnd != null) {
      final hourMatch = _hourInRange(doc.hour, hourStart!, hourEnd!);
      score += hourMatch ? 1.4 : -0.6;
    }
    return score;
  }

  static (int, int)? _parseHourRange(String normalizedQuery) {
    if (normalizedQuery.contains('morning')) {
      return (5, 11);
    }
    if (normalizedQuery.contains('afternoon')) {
      return (12, 17);
    }
    if (normalizedQuery.contains('evening')) {
      return (18, 22);
    }
    if (normalizedQuery.contains('night') ||
        normalizedQuery.contains('tonight')) {
      return (22, 4);
    }
    return null;
  }

  static bool _hourInRange(int hour, int start, int end) {
    if (start <= end) {
      return hour >= start && hour <= end;
    }
    return hour >= start || hour <= end;
  }

  static DateTime _safeShiftYear(DateTime value, int years) {
    final targetYear = value.year + years;
    final lastDay = DateTime.utc(targetYear, value.month + 1, 0).day;
    final day = value.day > lastDay ? lastDay : value.day;
    return DateTime.utc(
      targetYear,
      value.month,
      day,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    );
  }
}
