import 'dart:convert';

// ============================================================================
// SERIALIZATION EXTENSIONS
// ============================================================================

/// DateTime serialization extension for converting DateTime to JSON-compatible strings.
extension DateTimeSerializationX on DateTime {
  /// Convert DateTime to UTC ISO8601 string for JSON serialization.
  String toJsonString() => toUtc().toIso8601String();
}

/// DateTime formatting extension for compact, locale-neutral display.
///
/// Deliberately avoids the `intl` package: the app only needs a fixed,
/// unambiguous `yyyy-MM-dd[ HH:mm]` layout rather than locale-aware
/// formatting.
extension DateTimeFormatX on DateTime {
  /// Formats as `yyyy-MM-dd HH:mm` in local time, e.g. `2026-03-14 18:05`.
  String toCompactLocalString() {
    final local = toLocal();
    return '${_dateOnly(local)} ${_two(local.hour)}:${_two(local.minute)}';
  }

  /// Formats as `yyyy-MM-dd` in local time (date only), e.g. `2026-03-14`.
  String toCompactLocalDateString() => _dateOnly(toLocal());

  static String _dateOnly(DateTime local) =>
      '${local.year.toString().padLeft(4, '0')}-${_two(local.month)}-${_two(local.day)}';

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// DateTime deserialization extension for parsing DateTime from JSON maps.
extension DateTimeDeserializationX on Map<String, dynamic> {
  /// Parse optional DateTime from a map key. Returns null if key is missing or null.
  DateTime? parseDateTime(String key) {
    final value = this[key];
    return value == null ? null : DateTime.parse(value as String);
  }

  /// Parse required DateTime from a map key. Throws if key is missing or null.
  DateTime parseDateTimeRequired(String key) {
    return DateTime.parse(this[key] as String);
  }
}

/// List deserialization extension for parsing lists from JSON maps.
extension ListDeserializationX on Map<String, dynamic> {
  /// Parse a list of strings from a map key. Returns empty list if key is missing.
  List<String> parseStringList(String key) {
    return List<String>.from(this[key] as List? ?? const []);
  }

  /// Parse a list of objects using a custom parser function.
  /// Returns empty list if key is missing or empty.
  List<T> parseObjectList<T>(
    String key,
    T Function(Map<String, dynamic>) parser,
  ) {
    return (this[key] as List? ?? const [])
        .map((item) => parser(Map<String, dynamic>.from(item as Map)))
        .toList();
  }
}

// ============================================================================
// AUTHENTICATION MODELS
// ============================================================================

/// Represents an authenticated user session with encryption vault access.
class AuthSession {
  AuthSession({
    required this.authToken,
    required this.userId,
    required this.vaultId,
    required this.vaultSalt,
  });

  final String authToken;
  final String userId;
  final String vaultId;
  final String vaultSalt;

  /// Serialize to JSON for caching/persistence.
  Map<String, dynamic> toJson() => {
    'authToken': authToken,
    'userId': userId,
    'vaultId': vaultId,
    'vaultSalt': vaultSalt,
  };

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      authToken: json['authToken'] as String,
      userId: json['userId'] as String,
      vaultId: json['vaultId'] as String,
      vaultSalt: json['vaultSalt'] as String,
    );
  }
}

// ============================================================================
// CONVERSATION PARTICIPANT & SEGMENT MODELS
// ============================================================================

/// Represents a participant in conversations (person or entity).
class Participant {
  Participant({
    required this.id,
    required this.displayName,
    this.identifiers = const [],
    this.aliases = const [],
    this.mergedInto,
  });

  final String id;
  final String displayName;
  final List<String> identifiers;
  final List<String> aliases;

  /// A persistent redirect; stale imports and sync events cannot recreate this person.
  final String? mergedInto;
  String get searchableText =>
      [displayName, ...aliases, ...identifiers].join(' ');

  static String normalizeIdentifier(String identifier) {
    final value = identifier.trim();
    final colon = value.indexOf(':');
    final provider = colon < 0
        ? (value.contains('@') ? 'email' : '')
        : value.substring(0, colon).toLowerCase();
    var identity = colon < 0 ? value : value.substring(colon + 1).trim();
    if (identity.isEmpty) return '';
    if (provider == 'email') identity = identity.toLowerCase();
    if (provider == 'discord' && RegExp(r'^\d+$').hasMatch(identity)) {
      identity = identity.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    }
    return provider.isEmpty ? identity : '$provider:$identity';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'identifiers': identifiers,
    if (aliases.isNotEmpty) 'aliases': aliases,
    if (mergedInto != null) 'mergedInto': mergedInto,
  };
  factory Participant.fromJson(Map<String, dynamic> json) => Participant(
    id: json['id'] as String,
    displayName: json['displayName'] as String,
    identifiers: json
        .parseStringList('identifiers')
        .map(normalizeIdentifier)
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(),
    aliases: json.parseStringList('aliases'),
    mergedInto: json['mergedInto'] as String?,
  );
}

/// Represents a single segment/message in a conversation with metadata.
class ConversationSegment {
  ConversationSegment({
    this.attachmentUrls = const [],
    this.sourceMessageId,
    required this.id,
    required this.text,
    this.participantId,
    this.offsetMs = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final List<String> attachmentUrls;
  final String? sourceMessageId;
  final String id;
  final String text;
  final String? participantId;
  final int offsetMs;
  final DateTime createdAt;

  /// Serialize to JSON.
  Map<String, dynamic> toJson() => {
    if (attachmentUrls.isNotEmpty) 'attachmentUrls': attachmentUrls,
    if (sourceMessageId != null) 'sourceMessageId': sourceMessageId,
    'id': id,
    'text': text,
    'participantId': participantId,
    'offsetMs': offsetMs,
    'createdAt': createdAt.toJsonString(),
  };

  factory ConversationSegment.fromJson(Map<String, dynamic> json) {
    return ConversationSegment(
      sourceMessageId: json['sourceMessageId'] as String?,
      attachmentUrls: json.parseStringList('attachmentUrls'),
      id: json['id'] as String,
      text: json['text'] as String,
      participantId: json['participantId'] as String?,
      offsetMs: json['offsetMs'] as int? ?? 0,
      createdAt: json.parseDateTime('createdAt'),
    );
  }
}

/// Represents a conversation/thread with metadata and segments.
class Conversation {
  Conversation({
    this.sourceUrl,
    this.metadata = const {},
    this.sourceThreadId,
    required this.id,
    required this.title,
    required this.source,
    required this.participantIds,
    required this.segments,
    this.artifactNames = const [],
    this.tags = const [],
    this.isFavorite = false,
    this.importFingerprint,
    DateTime? startedAt,
    DateTime? endedAt,
  }) : startedAt = startedAt ?? DateTime.now().toUtc(),
       endedAt = endedAt ?? DateTime.now().toUtc();

  final String? sourceUrl;
  final Map<String, String> metadata;

  final String? sourceThreadId;
  final String id;
  final String title;
  final String source;
  final List<String> participantIds;
  final List<ConversationSegment> segments;
  final List<String> artifactNames;
  final List<String> tags;
  final bool isFavorite;

  /// Content receipt stored only inside the encrypted conversation envelope.
  final String? importFingerprint;
  final DateTime startedAt;
  final DateTime endedAt;

  /// Combined searchable text from title, source, artifacts, tags, and all segment texts.
  String get searchableText => [
    title,
    source,
    ...artifactNames,
    ...tags,
    ...segments.map((segment) => segment.text),
  ].join(' ').toLowerCase();

  /// Serialize to JSON.
  Map<String, dynamic> toJson() => {
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
    if (metadata.isNotEmpty) 'metadata': metadata,
    if (sourceThreadId != null) 'sourceThreadId': sourceThreadId,
    'id': id,
    'title': title,
    'source': source,
    'participantIds': participantIds,
    'segments': segments.map((segment) => segment.toJson()).toList(),
    'artifactNames': artifactNames,
    'tags': tags,
    'isFavorite': isFavorite,
    if (importFingerprint != null) 'importFingerprint': importFingerprint,
    'startedAt': startedAt.toJsonString(),
    'endedAt': endedAt.toJsonString(),
  };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    sourceUrl: json['sourceUrl'] as String?,
    metadata: (json['metadata'] as Map? ?? const {}).map(
      (key, value) => MapEntry('$key', '$value'),
    ),
    sourceThreadId: json['sourceThreadId'] as String?,
    id: json['id'] as String,
    title: json['title'] as String,
    source: json['source'] as String,
    participantIds: json.parseStringList('participantIds'),
    segments: json.parseObjectList<ConversationSegment>(
      'segments',
      ConversationSegment.fromJson,
    ),
    artifactNames: json.parseStringList('artifactNames'),
    tags: json.parseStringList('tags'),
    isFavorite: json['isFavorite'] as bool? ?? false,
    importFingerprint: json['importFingerprint'] as String?,
    startedAt: json.parseDateTimeRequired('startedAt'),
    endedAt: json.parseDateTimeRequired('endedAt'),
  );
}

// ============================================================================
// SEARCH & INSIGHTS MODELS
// ============================================================================

/// Represents a saved search query with optional filters.
class SavedSearch {
  SavedSearch({
    required this.id,
    required this.title,
    this.query = '',
    this.source,
    this.participantId,
    this.tag,
    this.from,
    this.to,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final String id;
  final String title;
  final String query;
  final String? source;
  final String? participantId;
  final String? tag;

  /// Inclusive start of the saved date-range filter, if any.
  final DateTime? from;

  /// Inclusive end of the saved date-range filter, if any.
  final DateTime? to;
  final DateTime createdAt;

  /// Serialize to JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'query': query,
    'source': source,
    'participantId': participantId,
    'tag': tag,
    if (from != null) 'from': from!.toJsonString(),
    if (to != null) 'to': to!.toJsonString(),
    'createdAt': createdAt.toJsonString(),
  };

  factory SavedSearch.fromJson(Map<String, dynamic> json) => SavedSearch(
    id: json['id'] as String,
    title: json['title'] as String,
    query: json['query'] as String? ?? '',
    source: json['source'] as String?,
    participantId: json['participantId'] as String?,
    tag: json['tag'] as String?,
    // Absent in searches saved before the date-range filter existed;
    // parseDateTime returns null for a missing key, keeping old JSON
    // backward compatible.
    from: json.parseDateTime('from'),
    to: json.parseDateTime('to'),
    createdAt: json.parseDateTimeRequired('createdAt'),
  );
}

/// Represents a single day bucket in conversation timeline.
class TimelineBucket {
  TimelineBucket({required this.day, required this.count});

  final DateTime day;
  final int count;
}

/// Represents a count facet grouped by source.
class SourceFacet {
  SourceFacet({required this.source, required this.count});

  final String source;
  final int count;
}

/// Represents a count facet grouped by participant.
class ParticipantFacet {
  ParticipantFacet({required this.participant, required this.count});

  final Participant participant;
  final int count;
}

/// Represents aggregated insights about vault contents.
class VaultInsights {
  VaultInsights({
    required this.totalConversations,
    required this.totalSegments,
    required this.totalArtifacts,
    required this.sourceFacets,
    required this.participantFacets,
    required this.timeline,
    required this.tags,
  });

  final int totalConversations;
  final int totalSegments;
  final int totalArtifacts;
  final List<SourceFacet> sourceFacets;
  final List<ParticipantFacet> participantFacets;
  final List<TimelineBucket> timeline;
  final List<String> tags;
}

/// Represents a paginated page of search results.
class ConversationSearchPage {
  ConversationSearchPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  final List<Conversation> items;
  final int total;
  final int page;
  final int pageSize;

  /// Total number of pages available.
  int get totalPages => pageSize <= 0
      ? 1
      : ((total + pageSize - 1) ~/ pageSize).clamp(1, 1 << 30);

  /// Whether a previous page is available.
  bool get hasPrevious => page > 1;

  /// Whether a next page is available.
  bool get hasNext => page < totalPages;
}

// ============================================================================
// RELATIONSHIP MODELS
// ============================================================================

/// Represents a relation/edge between two entities extracted from conversations.
class RelationEdge {
  RelationEdge({
    required this.id,
    required this.subject,
    required this.relation,
    required this.object,
    required this.evidence,
    required this.confidence,
    this.evidenceConversationId,
  });

  final String id;
  final String subject;
  final String relation;
  final String object;
  final String evidence;
  final double confidence;
  final String? evidenceConversationId;

  /// Serialize to JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'subject': subject,
    'relation': relation,
    'object': object,
    'evidence': evidence,
    'confidence': confidence,
    'evidenceConversationId': evidenceConversationId,
  };

  factory RelationEdge.fromJson(Map<String, dynamic> json) => RelationEdge(
    id: json['id'] as String,
    subject: json['subject'] as String,
    relation: json['relation'] as String,
    object: json['object'] as String,
    evidence: json['evidence'] as String,
    confidence: (json['confidence'] as num).toDouble(),
    evidenceConversationId: json['evidenceConversationId'] as String?,
  );
}

// ============================================================================
// SYNC & DATA TRANSFER MODELS
// ============================================================================

/// Represents a single sync operation envelope with encrypted payload.
class SyncEnvelope {
  SyncEnvelope({
    required this.id,
    required this.deviceId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.revision,
    required this.cipherText,
    required this.nonce,
    required this.keyId,
    required this.clientCreatedAt,
    this.serverSequence = 0,
  });

  final String id;
  final String deviceId;
  final String entityType;
  final String entityId;
  final String operation;
  final int revision;
  final String cipherText;
  final String nonce;
  final String keyId;
  final DateTime clientCreatedAt;
  final int serverSequence;

  /// Serialize to JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'deviceId': deviceId,
    'entityType': entityType,
    'entityId': entityId,
    'operation': operation,
    'revision': revision,
    'cipherText': cipherText,
    'nonce': nonce,
    'keyId': keyId,
    'clientCreatedAt': clientCreatedAt.toUtc().toIso8601String(),
    'serverSequence': serverSequence,
  };

  factory SyncEnvelope.fromJson(Map<String, dynamic> json) => SyncEnvelope(
    id: json['id'] as String,
    deviceId: json['deviceId'] as String,
    entityType: json['entityType'] as String,
    entityId: json['entityId'] as String,
    operation: json['operation'] as String,
    revision: json['revision'] as int,
    cipherText: json['cipherText'] as String,
    nonce: json['nonce'] as String,
    keyId: json['keyId'] as String,
    clientCreatedAt: json.parseDateTimeRequired('clientCreatedAt'),
    serverSequence: json['serverSequence'] as int? ?? 0,
  );
}

// ============================================================================
// IMPORT MODELS
// ============================================================================

/// Describes an available import source capability and its configuration.
class ImportCapability {
  ImportCapability({
    required this.source,
    required this.displayName,
    required this.availableNow,
    required this.requiresCredentials,
    required this.status,
    required this.acceptedFormats,
  });

  final String source;
  final String displayName;
  final bool availableNow;
  final bool requiresCredentials;
  final String status;
  final List<String> acceptedFormats;

  /// Serialize to JSON for caching/persistence.
  Map<String, dynamic> toJson() => {
    'source': source,
    'displayName': displayName,
    'availableNow': availableNow,
    'requiresCredentials': requiresCredentials,
    'status': status,
    'acceptedFormats': acceptedFormats,
  };

  factory ImportCapability.fromJson(Map<String, dynamic> json) {
    return ImportCapability(
      source: json['source'] as String,
      displayName: json['displayName'] as String,
      availableNow: json['availableNow'] as bool,
      requiresCredentials: json['requiresCredentials'] as bool,
      status: json['status'] as String,
      acceptedFormats: json.parseStringList('acceptedFormats'),
    );
  }
}

/// Represents a request to import data from a source (file upload or direct text).
class ImportSourceRequest {
  ImportSourceRequest({
    this.title,
    this.text,
    this.originalFileName,
    this.mimeType,
    this.metadata = const {},
    this.participantNames = const [],
    this.payloadBase64,
  });

  final String? title;
  final String? text;
  final String? originalFileName;
  final String? mimeType;
  final Map<String, String> metadata;
  final List<String> participantNames;
  final String? payloadBase64;

  /// Serialize to JSON.
  Map<String, dynamic> toJson() => {
    if (title != null) 'title': title,
    if (text != null) 'text': text,
    if (originalFileName != null) 'originalFileName': originalFileName,
    if (mimeType != null) 'mimeType': mimeType,
    if (metadata.isNotEmpty) 'metadata': metadata,
    if (participantNames.isNotEmpty) 'participantNames': participantNames,
    if (payloadBase64 != null) 'payloadBase64': payloadBase64,
  };
}

/// Represents the normalized result of an import operation from the backend.
class NormalizedImportResult {
  NormalizedImportResult({
    required this.source,
    required this.plaintextCompute,
    required this.message,
    required this.conversations,
    required this.participants,
    this.diagnostics = const {},
  });

  final String source;
  final bool plaintextCompute;
  final String message;
  final List<NormalizedConversation> conversations;
  final List<NormalizedParticipant> participants;
  final Map<String, String> diagnostics;

  /// Serialize to JSON for caching/persistence.
  Map<String, dynamic> toJson() => {
    'source': source,
    'plaintextCompute': plaintextCompute,
    'message': message,
    'conversations': conversations.map((c) => c.toJson()).toList(),
    'participants': participants.map((p) => p.toJson()).toList(),
    'diagnostics': diagnostics,
  };

  factory NormalizedImportResult.fromJson(Map<String, dynamic> json) {
    return NormalizedImportResult(
      source: json['source'] as String,
      plaintextCompute: json['plaintextCompute'] as bool? ?? true,
      message: json['message'] as String? ?? '',
      diagnostics: (json['diagnostics'] as Map? ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      conversations: json.parseObjectList<NormalizedConversation>(
        'conversations',
        NormalizedConversation.fromJson,
      ),
      participants: json.parseObjectList<NormalizedParticipant>(
        'participants',
        NormalizedParticipant.fromJson,
      ),
    );
  }
}

/// Represents a participant extracted during import normalization.
class NormalizedParticipant {
  NormalizedParticipant({
    required this.displayName,
    this.identifiers = const [],
    this.aliases = const [],
  });

  final String displayName;
  final List<String> identifiers;
  final List<String> aliases;

  /// Serialize to JSON for caching/persistence.
  Map<String, dynamic> toJson() => {
    'displayName': displayName,
    'identifiers': identifiers,
    if (aliases.isNotEmpty) 'aliases': aliases,
  };

  factory NormalizedParticipant.fromJson(Map<String, dynamic> json) {
    return NormalizedParticipant(
      displayName: json['displayName'] as String,
      identifiers: json.parseStringList('identifiers'),
      aliases: json.parseStringList('aliases'),
    );
  }
}

/// Represents a conversation extracted during import normalization.
class NormalizedConversation {
  NormalizedConversation({
    this.sourceUrl,
    this.metadata = const {},
    this.participantIdentifiers = const [],
    this.sourceThreadId,
    required this.title,
    required this.source,
    required this.participantNames,
    required this.segments,
    this.artifactNames = const [],
  });

  final String? sourceUrl;
  final Map<String, String> metadata;

  final List<String> participantIdentifiers;
  final String? sourceThreadId;
  final String title;
  final String source;
  final List<String> participantNames;
  final List<NormalizedSegment> segments;
  final List<String> artifactNames;

  /// Serialize to JSON for caching/persistence.
  Map<String, dynamic> toJson() => {
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
    if (metadata.isNotEmpty) 'metadata': metadata,
    if (participantIdentifiers.isNotEmpty)
      'participantIdentifiers': participantIdentifiers,
    if (sourceThreadId != null) 'sourceThreadId': sourceThreadId,
    'title': title,
    'source': source,
    'participantNames': participantNames,
    'segments': segments.map((s) => s.toJson()).toList(),
    'artifactNames': artifactNames,
  };

  factory NormalizedConversation.fromJson(Map<String, dynamic> json) {
    return NormalizedConversation(
      sourceUrl: json['sourceUrl'] as String?,
      metadata: (json['metadata'] as Map? ?? const {}).map(
        (key, value) => MapEntry('$key', '$value'),
      ),
      sourceThreadId: json['sourceThreadId'] as String?,
      participantIdentifiers: json.parseStringList('participantIdentifiers'),
      title: json['title'] as String,
      source: json['source'] as String,
      participantNames: json.parseStringList('participantNames'),
      segments: json.parseObjectList<NormalizedSegment>(
        'segments',
        NormalizedSegment.fromJson,
      ),
      artifactNames: json.parseStringList('artifactNames'),
    );
  }
}

/// Represents a segment/message extracted during import normalization.
class NormalizedSegment {
  NormalizedSegment({
    this.attachmentUrls = const [],
    this.participantIdentifier,
    this.sourceMessageId,
    required this.text,
    this.participantName,
    this.offsetMs = 0,
    this.createdAt,
  });

  final List<String> attachmentUrls;
  final String? participantIdentifier;
  final String? sourceMessageId;
  final String text;
  final String? participantName;
  final int offsetMs;
  final DateTime? createdAt;

  /// Serialize to JSON for caching/persistence.
  Map<String, dynamic> toJson() => {
    if (attachmentUrls.isNotEmpty) 'attachmentUrls': attachmentUrls,
    if (participantIdentifier != null)
      'participantIdentifier': participantIdentifier,
    if (sourceMessageId != null) 'sourceMessageId': sourceMessageId,
    'text': text,
    'participantName': participantName,
    'offsetMs': offsetMs,
    if (createdAt != null) 'createdAt': createdAt!.toJsonString(),
  };

  factory NormalizedSegment.fromJson(Map<String, dynamic> json) {
    return NormalizedSegment(
      sourceMessageId: json['sourceMessageId'] as String?,
      participantIdentifier: json['participantIdentifier'] as String?,
      attachmentUrls: json.parseStringList('attachmentUrls'),
      text: json['text'] as String,
      participantName: json['participantName'] as String?,
      offsetMs: json['offsetMs'] as int? ?? 0,
      createdAt: json.parseDateTime('createdAt'),
    );
  }
}

// ============================================================================
// IMAGE & MEDIA MODELS
// ============================================================================

/// Represents an image/media item metadata with storage reference.
class ImageItem {
  ImageItem({
    required this.id,
    required this.fileName,
    required this.contentType,
    required this.sizeBytes,
    required this.uploadedAt,
    this.conversationId,
  });

  final String id;
  final String fileName;
  final String contentType;
  final int sizeBytes;
  final DateTime uploadedAt;
  final String? conversationId;

  /// Serialize to JSON for caching/persistence.
  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    'contentType': contentType,
    'sizeBytes': sizeBytes,
    'uploadedAt': uploadedAt.toJsonString(),
    'conversationId': conversationId,
  };

  factory ImageItem.fromJson(Map<String, dynamic> json) {
    return ImageItem(
      id: json['id'] as String,
      fileName: json['fileName'] as String,
      contentType: json['contentType'] as String,
      sizeBytes: json['sizeBytes'] as int,
      uploadedAt: json.parseDateTimeRequired('uploadedAt'),
      conversationId: json['conversationId'] as String?,
    );
  }
}

// ============================================================================
// QUOTA & USAGE MODELS
// ============================================================================

/// Represents current storage quota status and usage information.
class QuotaStatus {
  QuotaStatus({
    required this.plan,
    required this.usedBytes,
    required this.limitBytes,
    required this.usedPercent,
    this.expiresAt,
  });

  final String plan;
  final int usedBytes;
  final int limitBytes;
  final double usedPercent;
  final DateTime? expiresAt;

  /// Whether usage is at or near the 80% threshold.
  bool get isNearLimit => usedPercent >= 80;

  /// Whether usage exceeds the storage limit.
  bool get isOverLimit => usedBytes >= limitBytes;

  /// Human-readable formatted used storage amount.
  String get usedFormatted => _formatBytes(usedBytes);

  /// Human-readable formatted storage limit amount.
  String get limitFormatted => _formatBytes(limitBytes);

  /// Format bytes to human-readable string (KB, MB, GB).
  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
  }

  /// Serialize to JSON for caching/persistence.
  Map<String, dynamic> toJson() => {
    'plan': plan,
    'usedBytes': usedBytes,
    'limitBytes': limitBytes,
    'usedPercent': usedPercent,
    if (expiresAt != null) 'expiresAt': expiresAt!.toJsonString(),
  };

  factory QuotaStatus.fromJson(Map<String, dynamic> json) {
    return QuotaStatus(
      plan: json['plan'] as String? ?? 'Free',
      usedBytes: (json['usedBytes'] as num).toInt(),
      limitBytes: (json['limitBytes'] as num).toInt(),
      usedPercent: (json['usedPercent'] as num).toDouble(),
      expiresAt: json.parseDateTime('expiresAt'),
    );
  }
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

/// Decode a JSON string to a typed map.
Map<String, dynamic> decodeJsonMap(String value) {
  return Map<String, dynamic>.from(jsonDecode(value) as Map);
}
