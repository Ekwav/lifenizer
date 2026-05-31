import 'dart:convert';

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

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      authToken: json['authToken'] as String,
      userId: json['userId'] as String,
      vaultId: json['vaultId'] as String,
      vaultSalt: json['vaultSalt'] as String,
    );
  }
}

class Participant {
  Participant({
    required this.id,
    required this.displayName,
    this.identifiers = const [],
  });

  final String id;
  final String displayName;
  final List<String> identifiers;

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'identifiers': identifiers,
  };

  factory Participant.fromJson(Map<String, dynamic> json) => Participant(
    id: json['id'] as String,
    displayName: json['displayName'] as String,
    identifiers: List<String>.from(json['identifiers'] as List? ?? const []),
  );
}

class ConversationSegment {
  ConversationSegment({
    required this.id,
    required this.text,
    this.participantId,
    this.offsetMs = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final String id;
  final String text;
  final String? participantId;
  final int offsetMs;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'participantId': participantId,
    'offsetMs': offsetMs,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ConversationSegment.fromJson(Map<String, dynamic> json) {
    final createdAtText = json['createdAt'] as String?;
    return ConversationSegment(
      id: json['id'] as String,
      text: json['text'] as String,
      participantId: json['participantId'] as String?,
      offsetMs: json['offsetMs'] as int? ?? 0,
      createdAt: createdAtText == null ? null : DateTime.parse(createdAtText),
    );
  }
}

class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.source,
    required this.participantIds,
    required this.segments,
    this.artifactNames = const [],
    this.tags = const [],
    this.isFavorite = false,
    DateTime? startedAt,
    DateTime? endedAt,
  }) : startedAt = startedAt ?? DateTime.now().toUtc(),
       endedAt = endedAt ?? DateTime.now().toUtc();

  final String id;
  final String title;
  final String source;
  final List<String> participantIds;
  final List<ConversationSegment> segments;
  final List<String> artifactNames;
  final List<String> tags;
  final bool isFavorite;
  final DateTime startedAt;
  final DateTime endedAt;

  String get searchableText => [
    title,
    source,
    ...artifactNames,
    ...tags,
    ...segments.map((segment) => segment.text),
  ].join(' ').toLowerCase();

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'source': source,
    'participantIds': participantIds,
    'segments': segments.map((segment) => segment.toJson()).toList(),
    'artifactNames': artifactNames,
    'tags': tags,
    'isFavorite': isFavorite,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
  };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    title: json['title'] as String,
    source: json['source'] as String,
    participantIds: List<String>.from(
      json['participantIds'] as List? ?? const [],
    ),
    segments: (json['segments'] as List? ?? const [])
        .map(
          (segment) => ConversationSegment.fromJson(
            Map<String, dynamic>.from(segment as Map),
          ),
        )
        .toList(),
    artifactNames: List<String>.from(
      json['artifactNames'] as List? ?? const [],
    ),
    tags: List<String>.from(json['tags'] as List? ?? const []),
    isFavorite: json['isFavorite'] as bool? ?? false,
    startedAt: DateTime.parse(json['startedAt'] as String),
    endedAt: DateTime.parse(json['endedAt'] as String),
  );
}

class SavedSearch {
  SavedSearch({
    required this.id,
    required this.title,
    this.query = '',
    this.source,
    this.participantId,
    this.tag,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final String id;
  final String title;
  final String query;
  final String? source;
  final String? participantId;
  final String? tag;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'query': query,
    'source': source,
    'participantId': participantId,
    'tag': tag,
    'createdAt': createdAt.toIso8601String(),
  };

  factory SavedSearch.fromJson(Map<String, dynamic> json) => SavedSearch(
    id: json['id'] as String,
    title: json['title'] as String,
    query: json['query'] as String? ?? '',
    source: json['source'] as String?,
    participantId: json['participantId'] as String?,
    tag: json['tag'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

class TimelineBucket {
  TimelineBucket({required this.day, required this.count});

  final DateTime day;
  final int count;
}

class SourceFacet {
  SourceFacet({required this.source, required this.count});

  final String source;
  final int count;
}

class ParticipantFacet {
  ParticipantFacet({required this.participant, required this.count});

  final Participant participant;
  final int count;
}

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

/// A single page of search results.
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

  int get totalPages => pageSize <= 0
      ? 1
      : ((total + pageSize - 1) ~/ pageSize).clamp(1, 1 << 30);
  bool get hasPrevious => page > 1;
  bool get hasNext => page < totalPages;
}

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
    clientCreatedAt: DateTime.parse(json['clientCreatedAt'] as String),
    serverSequence: json['serverSequence'] as int? ?? 0,
  );
}

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

  factory ImportCapability.fromJson(Map<String, dynamic> json) {
    return ImportCapability(
      source: json['source'] as String,
      displayName: json['displayName'] as String,
      availableNow: json['availableNow'] as bool,
      requiresCredentials: json['requiresCredentials'] as bool,
      status: json['status'] as String,
      acceptedFormats: List<String>.from(
        json['acceptedFormats'] as List? ?? const [],
      ),
    );
  }
}

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

class NormalizedImportResult {
  NormalizedImportResult({
    required this.source,
    required this.plaintextCompute,
    required this.message,
    required this.conversations,
    required this.participants,
  });

  final String source;
  final bool plaintextCompute;
  final String message;
  final List<NormalizedConversation> conversations;
  final List<NormalizedParticipant> participants;

  factory NormalizedImportResult.fromJson(Map<String, dynamic> json) {
    return NormalizedImportResult(
      source: json['source'] as String,
      plaintextCompute: json['plaintextCompute'] as bool? ?? true,
      message: json['message'] as String? ?? '',
      conversations: (json['conversations'] as List? ?? const [])
          .map(
            (item) => NormalizedConversation.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      participants: (json['participants'] as List? ?? const [])
          .map(
            (item) => NormalizedParticipant.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
    );
  }
}

class NormalizedParticipant {
  NormalizedParticipant({
    required this.displayName,
    this.identifiers = const [],
  });

  final String displayName;
  final List<String> identifiers;

  factory NormalizedParticipant.fromJson(Map<String, dynamic> json) {
    return NormalizedParticipant(
      displayName: json['displayName'] as String,
      identifiers: List<String>.from(json['identifiers'] as List? ?? const []),
    );
  }
}

class NormalizedConversation {
  NormalizedConversation({
    required this.title,
    required this.source,
    required this.participantNames,
    required this.segments,
    this.artifactNames = const [],
  });

  final String title;
  final String source;
  final List<String> participantNames;
  final List<NormalizedSegment> segments;
  final List<String> artifactNames;

  factory NormalizedConversation.fromJson(Map<String, dynamic> json) {
    return NormalizedConversation(
      title: json['title'] as String,
      source: json['source'] as String,
      participantNames: List<String>.from(
        json['participantNames'] as List? ?? const [],
      ),
      segments: (json['segments'] as List? ?? const [])
          .map(
            (item) => NormalizedSegment.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      artifactNames: List<String>.from(
        json['artifactNames'] as List? ?? const [],
      ),
    );
  }
}

class NormalizedSegment {
  NormalizedSegment({
    required this.text,
    this.participantName,
    this.offsetMs = 0,
    this.createdAt,
  });

  final String text;
  final String? participantName;
  final int offsetMs;
  final DateTime? createdAt;

  factory NormalizedSegment.fromJson(Map<String, dynamic> json) {
    return NormalizedSegment(
      text: json['text'] as String,
      participantName: json['participantName'] as String?,
      offsetMs: json['offsetMs'] as int? ?? 0,
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.parse(json['createdAt'] as String),
    );
  }
}

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

  factory ImageItem.fromJson(Map<String, dynamic> json) {
    return ImageItem(
      id: json['id'] as String,
      fileName: json['fileName'] as String,
      contentType: json['contentType'] as String,
      sizeBytes: json['sizeBytes'] as int,
      uploadedAt: DateTime.parse(json['uploadedAt'] as String),
      conversationId: json['conversationId'] as String?,
    );
  }
}

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

  bool get isNearLimit => usedPercent >= 80;
  bool get isOverLimit => usedBytes >= limitBytes;

  String get usedFormatted => _formatBytes(usedBytes);
  String get limitFormatted => _formatBytes(limitBytes);

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
  }

  factory QuotaStatus.fromJson(Map<String, dynamic> json) {
    return QuotaStatus(
      plan: json['plan'] as String? ?? 'Free',
      usedBytes: (json['usedBytes'] as num).toInt(),
      limitBytes: (json['limitBytes'] as num).toInt(),
      usedPercent: (json['usedPercent'] as num).toDouble(),
      expiresAt: json['expiresAt'] == null
          ? null
          : DateTime.parse(json['expiresAt'] as String),
    );
  }
}

Map<String, dynamic> decodeJsonMap(String value) {
  return Map<String, dynamic>.from(jsonDecode(value) as Map);
}
