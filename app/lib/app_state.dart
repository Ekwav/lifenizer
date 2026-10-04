import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:cryptography/cryptography.dart';

import 'api_client.dart';
import 'crypto_service.dart';
import 'package:image_picker/image_picker.dart';

import 'image_service.dart';
import 'models.dart';
import 'services/search_criteria.dart';
import 'services/device_pairing.dart';
import 'services/pairing_store.dart';
import 'services/local_vault_store.dart';
import 'services/shared_import_source.dart';

import 'services/conversation_search_index.dart';
import 'services/temporal_intent.dart';
import 'services/search_scorer.dart';
import 'services/search_service.dart';

part 'services/vault_sync.dart';
part 'services/vault_imports.dart';

class LifenizerAppState extends ChangeNotifier {
  LifenizerAppState({
    LocalVaultStore? localStore,
    this.apiFactory,
    PairingCredentialStore? pairingStore,
  }) : _localStore = localStore {
    pairing = DevicePairingService(this, store: pairingStore);
    pairing.addListener(_notifyChanged);
  }

  late final DevicePairingService pairing;

  @override
  void dispose() {
    pairing.dispose();
    super.dispose();
  }

  final LifenizerApiClient Function(String)? apiFactory;
  LocalVaultStore? _localStore;
  String rememberedEmail = '';
  String? _localVaultKey;
  final List<SyncEnvelope> _pendingSync = [];
  Future<void>? _syncInFlight;
  Future<void> _storageTail = Future.value();
  String? syncError;
  Map<String, dynamic>? audioDraft;
  Future<void> Function()? stopRecording;
  DateTime? lastSyncedAt;
  bool _unlocking = false;
  int get pendingSyncCount => _pendingSync.length;

  final Uuid _uuid = const Uuid();
  final VaultCrypto _crypto = VaultCrypto();

  String apiBaseUrl = const String.fromEnvironment(
    'LIFENIZER_API_URL',
    defaultValue: 'http://127.0.0.1:5075',
  );
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

  ConversationSearchIndex? _searchIndex;
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

  bool get isAuthenticated =>
      session != null && _crypto.isUnlocked && !_unlocking;

  void _notifyChanged() => notifyListeners();

  void reportError(String message) {
    error = message;
    notifyListeners();
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

  // ---------------------------------------------------------------------------
  // Quota & images
  // ---------------------------------------------------------------------------

  Future<void> refreshQuota() async {
    final api = _requireApi();
    try {
      final fetched = await api.getQuotaStatus();
      if (!identical(api, _api) || !_crypto.isUnlocked) return;
      quotaStatus = fetched;
      notifyListeners();
    } catch (_) {
      // Non-fatal: quota info will be unavailable but app continues.
    }
  }

  Future<void> refreshImages({String? conversationId}) async {
    final api = _requireApi();
    final fetched = await api.listImages(conversationId: conversationId);
    if (!identical(api, _api) || !_crypto.isUnlocked) return;
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

    return uploadCapturedImage(captured, conversationId: conversationId);
  }

  Future<ImageItem> uploadCapturedImage(
    CapturedImage captured, {
    String? conversationId,
  }) async {
    final api = _requireApi();
    final encrypted = await ImageService.encryptImage(captured, _crypto);
    final quota = quotaStatus;
    if (quota != null &&
        quota.usedBytes + encrypted.length > quota.limitBytes) {
      throw QuotaExceededException(
        'Storage quota exceeded. Please upgrade your plan.',
      );
    }
    if (!identical(api, _api) || !_crypto.isUnlocked) {
      throw StateError('Vault is locked.');
    }
    final item = await api.uploadImage(
      encrypted,
      '${_uuid.v4()}.bin',
      'application/octet-stream',
      conversationId: conversationId,
    );
    if (!identical(api, _api) || !_crypto.isUnlocked) {
      throw StateError('Vault is locked.');
    }
    images.add(item);
    notifyListeners();
    refreshQuota().ignore();
    return item;
  }

  Future<CapturedImage> decryptedImage(ImageItem image) async {
    final api = _requireApi();
    if (!_crypto.isUnlocked) throw StateError('Vault is locked.');
    final bytes = await api.downloadImage(image.id);
    if (!identical(api, _api) || !_crypto.isUnlocked) {
      throw StateError('Vault is locked.');
    }
    // Older image/* uploads were stored raw. Display them in memory with a
    // gallery notice; new uploads always contain authenticated ciphertext.
    final decoded = image.contentType.startsWith('image/')
        ? CapturedImage(
            bytes: bytes,
            fileName: image.fileName,
            contentType: image.contentType,
          )
        : await ImageService.decryptImage(bytes, _crypto);
    if (!identical(api, _api) || !_crypto.isUnlocked) {
      throw StateError('Vault is locked.');
    }
    return decoded;
  }

  Future<void> deleteImage(String id) async {
    final api = _requireApi();
    await api.deleteImage(id);
    images.removeWhere((img) => img.id == id);
    notifyListeners();
    refreshQuota().ignore();
  }

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
    final temporalIntent = TemporalIntent.tryParse(criteria.normalized, now);

    // Prepare query tokens
    final queryTokens = ConversationSearchIndex.tokenize(
      TemporalIntent.lexicalQuery(criteria.normalized),
    );
    final semanticQuery = queryTokens.join(' ');

    // Determine which previous tokens to carry over
    final previousQuery = _lastSearchQuery;
    final previousTokens = previousQuery == null
        ? const <String>[]
        : ConversationSearchIndex.tokenize(
            TemporalIntent.lexicalQuery(previousQuery),
          );

    final scorer = SearchScorer(
      temporalIntent: temporalIntent,
      normalizedQuery: criteria.normalized,
      now: now,
      previousQuery: previousQuery,
      lastSearchAt: _lastSearchAt,
      lastSearchTopIds: _lastSearchTopConversationIds,
      sessionQueryFrequency: _sessionQueryFrequency,
    );

    final carryPrevious = scorer.shouldCarryPreviousQuery(
      previousTokens,
      queryTokens,
    );
    final effectiveTokens = <String>{
      ...queryTokens,
      if (carryPrevious) ...previousTokens,
    }.toList(growable: false);

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

    _updateSearchContext(
      carryPrevious ? effectiveTokens.join(' ') : criteria.normalized,
      results,
      now,
    );
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
    final extension = lowerName.split('.').last;

    final isScannedFile =
        normalizedMime.startsWith('image/') ||
        normalizedMime == 'application/pdf' ||
        const {
          'pdf',
          'png',
          'jpg',
          'jpeg',
          'webp',
          'gif',
          'heic',
          'avif',
          'bmp',
          'tif',
          'tiff',
        }.contains(extension);
    if (isScannedFile && normalizedText == null) {
      reportError(
        'This file needs OCR first. Import extracted text, or attach the image to a conversation.',
      );
      return;
    }
    final isAudio =
        normalizedMime.startsWith('audio/') ||
        VaultImports._audioMimeTypesByExtension.containsKey(extension);
    String source;
    String? decodedText = normalizedText;
    try {
      final isZip =
          lowerName.endsWith('.zip') ||
          normalizedMime.contains('zip') ||
          (bytes != null &&
              bytes.length >= 4 &&
              bytes[0] == 0x50 &&
              bytes[1] == 0x4b);
      if (!isAudio && !isZip && decodedText == null && bytes != null) {
        decodedText = utf8.decode(bytes);
      }
      source = isAudio
          ? 'audio'
          : isScannedFile
          ? 'scanned-pdf'
          : detectSharedImportSource(
              fileName: normalizedName,
              mimeType: isZip ? 'application/zip' : normalizedMime,
              text: decodedText,
            );
    } on FormatException catch (exception) {
      reportError(exception.message);
      return;
    }

    if (source == 'audio' && bytes != null && bytes.isNotEmpty) {
      return importAudioBytes(
        bytes: bytes,
        fileName: normalizedName.isEmpty
            ? 'shared-recording.wav'
            : normalizedName,
        mimeType: normalizedMime.isEmpty ? null : normalizedMime,
      );
    }
    if (source == 'manual-text' || source == 'browser-capture') {
      return addManualText(
        title: normalizedName.isEmpty ? 'Shared conversation' : normalizedName,
        participantNames: '',
        source: source,
        text: decodedText ?? '',
      );
    }
    final payloadBase64 = bytes == null || bytes.isEmpty
        ? null
        : base64Encode(bytes);

    await importSource(
      source: source,
      title: source == 'telegram'
          ? null
          : normalizedName.isEmpty
          ? 'Shared import'
          : normalizedName,
      text: payloadBase64 == null || isScannedFile ? decodedText : null,
      originalFileName: normalizedName.isEmpty ? null : normalizedName,
      mimeType: normalizedMime.isEmpty ? null : normalizedMime,
      metadata: {...metadata, 'shared': 'true'},
      payloadBase64: payloadBase64,
    );
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

    _searchIndex = ConversationSearchIndex.build(
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
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (exception) {
      error = exception.toString();
    } finally {
      busy = false;
      if (_pendingSync.isNotEmpty && syncError != null) {
        status =
            'Saved encrypted on this device · ${_pendingSync.length} change(s) waiting to sync';
      }
      notifyListeners();
    }
  }

  LifenizerApiClient _requireApi() {
    final api = _api;
    if (api == null) throw StateError('Not logged in.');
    return api;
  }
}
