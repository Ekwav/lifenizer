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
import 'services/imap_import_service.dart';
import 'services/pairing_store.dart';
import 'services/local_vault_store.dart';
import 'services/shared_import_source.dart';
import 'services/discord_archive.dart';
import 'services/export_file_reader.dart';
import 'services/discord_bot_import_service.dart';
import 'services/document_import_service.dart';
import 'services/document_credentials.dart';

import 'services/conversation_search_index.dart';
import 'services/temporal_intent.dart';
import 'services/search_scorer.dart';
import 'services/search_service.dart';

part 'services/vault_sync.dart';
part 'services/vault_imports.dart';
part 'services/vault_email.dart';

class LifenizerAppState extends ChangeNotifier {
  LifenizerAppState({
    LocalVaultStore? localStore,
    this.apiFactory,
    PairingCredentialStore? pairingStore,
    ImapCredentialStore? imapStore,
    DocumentCredentialStore? documentStore,
    DiscordBotCredentialStore? discordStore,
  }) : _localStore = localStore {
    pairing = DevicePairingService(this, store: pairingStore);
    pairing.addListener(_notifyChanged);
    emailImport = EmailImportService(this, store: imapStore);
    emailImport.addListener(_notifyChanged);
    documentImport = DocumentImportService(this, store: documentStore);
    documentImport.addListener(_notifyChanged);
    discordImport = DiscordBotImportService(
      ingest: importDiscordBotBatch,
      store: discordStore,
    );
    discordImport.addListener(_notifyChanged);
    addListener(_updateDiscordIdentity);
  }

  late final DevicePairingService pairing;
  late final EmailImportService emailImport;
  late final DocumentImportService documentImport;
  late final DiscordBotImportService discordImport;

  void _updateDiscordIdentity() => discordImport.setIdentity(
    isAuthenticated && session != null
        ? jsonEncode([apiBaseUrl, rememberedEmail, session!.userId])
        : null,
  );

  @override
  void dispose() {
    removeListener(_updateDiscordIdentity);
    discordImport.dispose();
    documentImport.dispose();
    emailImport.dispose();
    pairing.dispose();
    super.dispose();
  }

  final LifenizerApiClient Function(String)? apiFactory;
  LocalVaultStore? _localStore;
  String rememberedEmail = '';
  String? _localVaultKey;
  final List<SyncEnvelope> _pendingSync = [];
  int _vaultBatchDepth = 0;
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
  int _searchIndexRevision = 0;
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
      participantId: participantId == null
          ? null
          : resolveParticipantId(participantId),
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
    final ranked = searchService
        .rankConversations(
          criteria,
          scorer,
          effectiveTokens,
          semanticQuery,
          maxResults: maxResults,
        )
        .cast<Conversation>();
    final current = busy
        ? {
            for (final conversation in conversations)
              conversation.id: conversation,
          }
        : null;
    final results = current == null
        ? ranked
        : ranked
              .where((conversation) => current.containsKey(conversation.id))
              .map((conversation) => current[conversation.id]!)
              .toList();

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
      participantId: participantId == null
          ? null
          : resolveParticipantId(participantId),
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
      for (final participantId
          in conversation.participantIds.map(resolveParticipantId).toSet()) {
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

  Map<String, Participant>? _participantLookup;
  final Map<String, String> _resolvedParticipantIds = {};
  final Set<String> _participantCycles = {};
  final Map<String, Set<String>> _identityPeople = {};
  final Map<String, Set<String>> _namePeople = {};
  bool _hasParticipantRedirects = false;

  void _invalidateParticipantLookup() {
    _participantLookup = null;
    _resolvedParticipantIds.clear();
    _participantCycles.clear();
    _identityPeople.clear();
    _namePeople.clear();
  }

  Map<String, Participant> get _people {
    if (_participantLookup == null ||
        _participantLookup!.length != participants.length) {
      _invalidateParticipantLookup();
      _participantLookup = {
        for (final person in participants) person.id: person,
      };
      _hasParticipantRedirects = participants.any(
        (person) => person.mergedInto != null,
      );
      for (final person in participants) {
        final id = resolveParticipantId(person.id);
        for (final identifier in person.identifiers) {
          _identityPeople
              .putIfAbsent(
                Participant.normalizeIdentifier(identifier),
                () => <String>{},
              )
              .add(id);
        }
        for (final name in [person.displayName, ...person.aliases]) {
          _namePeople
              .putIfAbsent(_personNameKey(name), () => <String>{})
              .add(id);
        }
      }
    }
    return _participantLookup!;
  }

  List<Participant> get activeParticipants {
    final people = _people;
    return people.values
        .where(
          (person) =>
              person.mergedInto == null ||
              _participantCycles.contains(person.id),
        )
        .toList();
  }

  String resolveParticipantId(String id) {
    final people = _people;
    if (!_hasParticipantRedirects) return id;
    final path = <String>[];
    var current = id;
    while (true) {
      final cached = _resolvedParticipantIds[current];
      if (cached != null) {
        current = cached;
        break;
      }
      final cycleStart = path.indexOf(current);
      if (cycleStart >= 0) {
        final cycle = path.skip(cycleStart).toList()..sort();
        current = cycle.first;
        _participantCycles.add(current);
        break;
      }
      path.add(current);
      final target = people[current]?.mergedInto;
      if (target == null) break;
      current = target;
    }
    for (final source in path) {
      _resolvedParticipantIds[source] = current;
    }
    return current;
  }

  Participant? participantById(String id) => _people[resolveParticipantId(id)];

  String participantName(String id) => participantById(id)?.displayName ?? id;
  static String _personNameKey(String name) =>
      name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  Future<List<String>> ensureParticipants(String input) =>
      ensureParticipantNames(input.split(','));

  Future<List<String>> ensureParticipantNames(Iterable<String> input) =>
      batchVaultChanges(() async {
        final ids = <String>{};
        for (final name
            in input
                .map((name) => name.trim())
                .where((name) => name.isNotEmpty)
                .toSet()) {
          ids.add((await ensureParticipantIdentity(name)).id);
        }
        return ids.toList();
      });

  Future<Participant> ensureExternalParticipant({
    required String provider,
    required String externalId,
    String? displayName,
    Iterable<String> aliases = const [],
    bool persist = true,
  }) => ensureParticipantIdentity(
    displayName ?? '$provider:$externalId',
    identifiers: ['$provider:$externalId'],
    aliases: aliases,
    persist: persist,
  );

  Future<Participant> ensureParticipantIdentity(
    String displayName, {
    Iterable<String> identifiers = const [],
    Iterable<String> aliases = const [],
    bool persist = true,
  }) async {
    final name = displayName.trim();
    final identities = identifiers
        .map(Participant.normalizeIdentifier)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (RegExp(r'^[^\s@]+@[^\s@]+$').hasMatch(name) ||
        RegExp(r'^(?:discord|email):', caseSensitive: false).hasMatch(name)) {
      final identifier = Participant.normalizeIdentifier(name);
      if (identifier.isNotEmpty) identities.add(identifier);
    }
    if (name.isEmpty && identities.isEmpty) {
      throw ArgumentError('A name or identity is required.');
    }
    final people = _people;
    final exact = <String>{
      for (final identity in identities) ...?_identityPeople[identity],
    };
    Participant? existing;
    if (exact.isNotEmpty) {
      final ordered = exact.toList()..sort();
      for (final id in ordered.skip(1)) {
        await _mergeParticipantRecords(id, ordered.first, persist: persist);
      }
      existing = participantById(ordered.first);
    } else {
      final byName = (_namePeople[_personNameKey(name)] ?? const <String>{})
          .map((id) => people[id])
          .whereType<Participant>()
          .toList();
      // A known provider identity must never attach to a different known ID just
      // because the display names match. Ambiguous name-only imports stay separate.
      if (byName.length == 1 &&
          (identities.isEmpty || byName.single.identifiers.isEmpty)) {
        existing = byName.single;
      } else if (identities.isEmpty) {
        final unknown = byName
            .where((person) => person.identifiers.isEmpty)
            .toList();
        if (unknown.length == 1) existing = unknown.single;
      }
    }
    final id =
        existing?.id ??
        (identities.isEmpty
            ? _uuid.v4()
            : _uuid.v5(
                Namespace.url.value,
                'lifenizer:person:${(identities.toList()..sort()).first}',
              ));
    final names = <String>{
      ...?existing?.aliases,
      ...aliases
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty),
    };
    if (existing != null && name.isNotEmpty && name != existing.displayName) {
      names.add(name);
    }
    final person = Participant(
      id: id,
      displayName:
          existing?.displayName ?? (name.isEmpty ? identities.first : name),
      identifiers: {...?existing?.identifiers, ...identities}.toList()..sort(),
      aliases: names.toList()..sort(),
    );
    if (existing == null ||
        jsonEncode(existing.toJson()) != jsonEncode(person.toJson())) {
      participants.removeWhere((item) => item.id == id);
      participants.add(person);
      _invalidateParticipantLookup();
      _markSearchIndexDirty();
      if (persist) await _pushEntity('participant', id, person.toJson());
      if (_vaultBatchDepth == 0) notifyListeners();
    }
    return person;
  }

  Future<void> addParticipantIdentity(String personId, String identifier) =>
      _run(
        () => batchVaultChanges(() async {
          final person = participantById(personId);
          if (person == null) throw ArgumentError('Choose an existing person.');
          final canonical = Participant.normalizeIdentifier(identifier);
          if (canonical.isEmpty ||
              !RegExp(r'^[a-z][a-z0-9_-]*:[^\s]+$').hasMatch(canonical) ||
              canonical.startsWith('email:') &&
                  !RegExp(r'^email:[^\s@]+@[^\s@]+$').hasMatch(canonical)) {
            throw ArgumentError('Enter a valid email or provider:id.');
          }
          final matched = await ensureParticipantIdentity(
            person.displayName,
            identifiers: [...person.identifiers, canonical],
            aliases: person.aliases,
          );
          if (matched.id != person.id) {
            await _mergeParticipantRecords(person.id, matched.id);
          }
          status = 'Identity linked; future imports use this person';
        }),
      );

  Future<void> mergeParticipants(String sourceId, String targetId) => _run(
    () => batchVaultChanges(() async {
      await _mergeParticipantRecords(sourceId, targetId);
      status = 'People merged; future imports use the same person';
    }),
  );

  Future<void> _mergeParticipantRecords(
    String sourceId,
    String targetId, {
    bool persist = true,
    bool rewriteReferences = true,
  }) async {
    sourceId = resolveParticipantId(sourceId);
    targetId = resolveParticipantId(targetId);
    if (sourceId == targetId) return;
    final source = participantById(sourceId);
    final target = participantById(targetId);
    if (source == null || target == null) {
      throw ArgumentError('Choose two existing people.');
    }
    final combined = Participant(
      id: target.id,
      displayName: target.displayName,
      identifiers: {...target.identifiers, ...source.identifiers}.toList()
        ..sort(),
      aliases: {
        ...target.aliases,
        ...source.aliases,
        source.displayName,
      }.where((name) => name != target.displayName).toList()..sort(),
    );
    final redirect = Participant(
      id: source.id,
      displayName: source.displayName,
      identifiers: source.identifiers,
      aliases: source.aliases,
      mergedInto: target.id,
    );
    participants.removeWhere(
      (person) => person.id == source.id || person.id == target.id,
    );
    participants.addAll([combined, redirect]);
    _invalidateParticipantLookup();
    final changed = rewriteReferences
        ? _rewriteParticipantReferences()
        : const <Conversation>[];
    _markSearchIndexDirty();
    if (persist) {
      await _pushEntity('participant', combined.id, combined.toJson());
      await _pushEntity('participant', redirect.id, redirect.toJson());
      for (final conversation in changed) {
        await _pushEntity(
          'conversation',
          conversation.id,
          conversation.toJson(),
        );
      }
    }
    if (_vaultBatchDepth == 0) notifyListeners();
  }

  Future<void> _coalesceParticipantIdentities() async {
    _people;
    final duplicates = _identityPeople.entries
        .where((entry) => entry.key.contains(':') && entry.value.length > 1)
        .map((entry) => entry.value.toList())
        .toList();
    if (duplicates.isEmpty) return;
    var changed = false;
    // The caller persists these envelopes with the pulled cursor. Syncing here
    // would await our own in-flight pull; references are rewritten once per page.
    _vaultBatchDepth++;
    try {
      for (final group in duplicates) {
        final ids = group.map(resolveParticipantId).toSet().toList()..sort();
        for (final source in ids.skip(1)) {
          await _mergeParticipantRecords(
            source,
            ids.first,
            rewriteReferences: false,
          );
          changed = true;
        }
      }
      if (changed) {
        for (final conversation in _rewriteParticipantReferences()) {
          await _pushEntity(
            'conversation',
            conversation.id,
            conversation.toJson(),
          );
        }
      }
    } finally {
      _vaultBatchDepth--;
    }
  }

  final Map<String, Conversation> _importedConversationRepairs = {};

  Conversation _mergeImportedConversation(
    Conversation previous,
    Conversation incoming,
  ) {
    String messageKey(ConversationSegment segment) =>
        segment.sourceMessageId == null
        ? 'local:${segment.id}'
        : 'source:${segment.sourceMessageId}';
    final incomingMessageKeys = incoming.segments.map(messageKey).toSet();
    final messages = {
      for (final segment in previous.segments) messageKey(segment): segment,
    };
    for (final segment in incoming.segments) {
      final old = messages[messageKey(segment)];
      messages[messageKey(segment)] = old == null
          ? segment
          : ConversationSegment.fromJson({
              ...segment.toJson(),
              'id': old.id,
              'participantId': segment.participantId ?? old.participantId,
              'attachmentUrls': {
                ...old.attachmentUrls,
                ...segment.attachmentUrls,
              }.toList()..sort(),
            });
    }
    final segments = messages.values.toList()
      ..sort((a, b) {
        final date = a.createdAt.compareTo(b.createdAt);
        if (date != 0) return date;
        final offset = a.offsetMs.compareTo(b.offsetMs);
        return offset != 0 ? offset : messageKey(a).compareTo(messageKey(b));
      });
    final starts = [
      previous.startedAt,
      incoming.startedAt,
      if (segments.isNotEmpty) segments.first.createdAt,
    ]..sort();
    final ends = [
      previous.endedAt,
      incoming.endedAt,
      if (segments.isNotEmpty) segments.last.createdAt,
    ]..sort();
    return _canonicalConversation(
      Conversation.fromJson({
        ...incoming.toJson(),
        'id': previous.id,
        'sourceUrl': incoming.sourceUrl ?? previous.sourceUrl,
        'metadata': {...previous.metadata, ...incoming.metadata},
        'participantIds': {
          ...previous.participantIds,
          ...incoming.participantIds,
        }.toList()..sort(),
        'segments': segments.map((segment) => segment.toJson()).toList(),
        'artifactNames': {
          ...previous.artifactNames,
          ...incoming.artifactNames,
        }.toList()..sort(),
        'tags': {...previous.tags, ...incoming.tags}.toList()..sort(),
        'isFavorite':
            previous.segments.every(
              (segment) => incomingMessageKeys.contains(messageKey(segment)),
            )
            ? incoming.isFavorite
            : previous.isFavorite || incoming.isFavorite,
        'startedAt': starts.first.toUtc().toIso8601String(),
        'endedAt': ends.last.toUtc().toIso8601String(),
      }),
    );
  }

  bool _sameImportedConversation(Conversation left, Conversation right) {
    Map<String, dynamic> comparable(Conversation conversation) {
      final json = conversation.toJson();
      json['participantIds'] =
          conversation.participantIds.map(resolveParticipantId).toSet().toList()
            ..sort();
      json['tags'] = conversation.tags.toSet().toList()..sort();
      json['artifactNames'] = conversation.artifactNames.toSet().toList()
        ..sort();
      final segments =
          conversation.segments.map((segment) {
            final value = segment.toJson();
            // The local ID stays stable for UI references; the provider message ID
            // determines equality so old random local IDs cannot cause repair loops.
            if (segment.sourceMessageId != null) value.remove('id');
            value['attachmentUrls'] = segment.attachmentUrls.toSet().toList()
              ..sort();
            if (segment.participantId != null) {
              value['participantId'] = resolveParticipantId(
                segment.participantId!,
              );
            }
            return value;
          }).toList()..sort(
            (a, b) => '${a['sourceMessageId'] ?? a['id']}'.compareTo(
              '${b['sourceMessageId'] ?? b['id']}',
            ),
          );
      json['segments'] = segments;
      return json;
    }

    return jsonEncode(comparable(left)) == jsonEncode(comparable(right));
  }

  Future<void> _queueImportedConversationRepairs() async {
    if (_importedConversationRepairs.isEmpty) return;
    final incoming = Map<String, Conversation>.from(
      _importedConversationRepairs,
    );
    _importedConversationRepairs.clear();
    final currentById = {
      for (final conversation in conversations) conversation.id: conversation,
    };
    final pendingById = {
      for (final envelope in _pendingSync.where(
        (e) => e.entityType == 'conversation',
      ))
        envelope.entityId: envelope,
    };
    _vaultBatchDepth++;
    try {
      for (final entry in incoming.entries) {
        final current = currentById[entry.key];
        if (current == null ||
            _sameImportedConversation(current, entry.value)) {
          continue;
        }
        final pending = pendingById[entry.key];
        if (pending != null) {
          final decoded = await _crypto.decryptJson(
            cipherText: pending.cipherText,
            nonce: pending.nonce,
          );
          if (_sameImportedConversation(
            current,
            Conversation.fromJson(decoded),
          )) {
            continue;
          }
        }
        await _pushEntity('conversation', current.id, current.toJson());
      }
    } finally {
      _vaultBatchDepth--;
    }
  }

  Conversation _canonicalConversation(Conversation conversation) {
    _people;
    if (!_hasParticipantRedirects) return conversation;
    final ids = conversation.participantIds
        .map(resolveParticipantId)
        .toSet()
        .toList();
    final segments = conversation.segments.map((segment) {
      final id = segment.participantId;
      if (id == null || resolveParticipantId(id) == id) return segment;
      return ConversationSegment.fromJson({
        ...segment.toJson(),
        'participantId': resolveParticipantId(id),
      });
    }).toList();
    if (listEquals(ids, conversation.participantIds) &&
        listEquals(segments, conversation.segments)) {
      return conversation;
    }
    return Conversation.fromJson({
      ...conversation.toJson(),
      'participantIds': ids,
      'segments': segments.map((segment) => segment.toJson()).toList(),
    });
  }

  List<Conversation> _rewriteParticipantReferences() {
    _people;
    if (!_hasParticipantRedirects) return const [];
    final changed = <Conversation>[];
    for (var i = 0; i < conversations.length; i++) {
      final canonical = _canonicalConversation(conversations[i]);
      if (!identical(canonical, conversations[i])) {
        conversations[i] = canonical;
        changed.add(canonical);
      }
    }
    return changed;
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
      if (!isAudio &&
          !isZip &&
          !isScannedFile &&
          decodedText == null &&
          bytes != null) {
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
        final incoming = Participant.fromJson(json);
        final previous = _people[incoming.id];
        final participant = Participant(
          id: incoming.id,
          displayName: previous?.displayName ?? incoming.displayName,
          identifiers: {
            ...?previous?.identifiers,
            ...incoming.identifiers,
          }.toList()..sort(),
          aliases: {
            ...?previous?.aliases,
            ...incoming.aliases,
            if (previous != null &&
                previous.displayName != incoming.displayName)
              incoming.displayName,
          }.toList()..sort(),
          mergedInto: previous?.mergedInto == null
              ? incoming.mergedInto
              : incoming.mergedInto == null
              ? previous!.mergedInto
              : ([previous!.mergedInto!, incoming.mergedInto!]..sort()).first,
        );
        participants.removeWhere((item) => item.id == participant.id);
        participants.add(participant);
        _invalidateParticipantLookup();
        if (participant.mergedInto != null) {
          final target = participantById(participant.id);
          if (target != null && target.id != participant.id) {
            final combined = Participant(
              id: target.id,
              displayName: target.displayName,
              identifiers: {
                ...target.identifiers,
                ...participant.identifiers,
              }.toList()..sort(),
              aliases: {
                ...target.aliases,
                ...participant.aliases,
                participant.displayName,
              }.where((name) => name != target.displayName).toList()..sort(),
            );
            participants.removeWhere((item) => item.id == target.id);
            participants.add(combined);
            _invalidateParticipantLookup();
          }
        }
        if (participant.mergedInto != null) _rewriteParticipantReferences();
        _markSearchIndexDirty();
        break;
      case 'conversation':
        final incoming = _canonicalConversation(Conversation.fromJson(json));
        final previous = conversations
            .where((item) => item.id == incoming.id)
            .firstOrNull;
        final importedThread =
            previous != null &&
            incoming.sourceThreadId != null &&
            previous.sourceThreadId == incoming.sourceThreadId &&
            previous.source == incoming.source;
        final conversation = importedThread
            ? _mergeImportedConversation(previous, incoming)
            : incoming;
        if (importedThread &&
            !_sameImportedConversation(conversation, incoming)) {
          _importedConversationRepairs[conversation.id] = incoming;
        } else {
          _importedConversationRepairs.remove(conversation.id);
        }
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
    _searchIndexRevision++;
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

  bool get _needsSearchIndex =>
      _searchIndexDirty ||
      _searchIndex == null ||
      _indexedConversationCount != conversations.length ||
      _indexedRelationCount != relations.length ||
      _indexedParticipantCount != participants.length;

  (List<Conversation>, Map<String, String>, Map<String, String>)
  _searchIndexInputs() {
    final participantSearchText = <String, String>{
      for (final participant in participants)
        participant.id:
            participantById(participant.id)?.searchableText ??
            participant.searchableText,
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

    return (
      conversations.toList(),
      participantSearchText,
      relationTextByConversation.map(
        (key, value) => MapEntry(key, value.toString().toLowerCase()),
      ),
    );
  }

  void _installSearchIndex(ConversationSearchIndex index) {
    _searchIndex = index;
    _searchIndexDirty = false;
    _indexedConversationCount = conversations.length;
    _indexedRelationCount = relations.length;
    _indexedParticipantCount = participants.length;
  }

  void _ensureSearchIndex() {
    // Progress rebuilds keep the previous results while an import changes the
    // vault. The final index is prepared off the UI isolate before busy clears.
    if (busy || _syncInFlight != null || !_needsSearchIndex) return;
    _installSearchIndex(_buildConversationSearchIndex(_searchIndexInputs()));
  }

  Future<void> _prepareSearchIndex() async {
    if (!_needsSearchIndex || !_crypto.isUnlocked) return;
    final revision = _searchIndexRevision;
    final index = await compute(
      _buildConversationSearchIndex,
      _searchIndexInputs(),
      debugLabel: 'conversation-search-index',
    );
    if (revision == _searchIndexRevision && _crypto.isUnlocked) {
      _installSearchIndex(index);
    }
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
      try {
        await _prepareSearchIndex();
      } catch (exception) {
        error ??= 'Could not prepare search: $exception';
      }
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

ConversationSearchIndex _buildConversationSearchIndex(
  (List<Conversation>, Map<String, String>, Map<String, String>) inputs,
) => ConversationSearchIndex.build(
  conversations: inputs.$1,
  participantById: inputs.$2,
  relationTextByConversation: inputs.$3,
);
