import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class LifenizerApiClient {
  LifenizerApiClient({
    required this.baseUrl,
    this.authToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String? authToken;
  final http.Client _client;

  LifenizerApiClient authenticated(String token) {
    return LifenizerApiClient(
      baseUrl: baseUrl,
      authToken: token,
      client: _client,
    );
  }

  Future<AuthSession> devLogin({
    required String email,
    required String displayName,
  }) async {
    final response = await _post('/api/auth/dev-login', {
      'email': email,
      'displayName': displayName,
    }, authenticated: false);
    return AuthSession.fromJson(response);
  }

  Future<List<ImportCapability>> importCapabilities() async {
    final response = await _client.get(_uri('/api/imports/capabilities'));
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List;
    return data
        .map(
          (item) =>
              ImportCapability.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  /// Runs an import for [source] with the given [request].
  ///
  /// [timeout] overrides the default (unbounded) wait for this call. It is
  /// used for slow server-side work such as audio transcription (see
  /// [LifenizerAppState.importAudioBytes]) — other imports stay exempt from
  /// any timeout, matching today's behavior.
  Future<NormalizedImportResult> importSource(
    String source,
    ImportSourceRequest request, {
    Duration? timeout,
  }) async {
    final response = await _post(
      '/api/imports/$source',
      request.toJson(),
      timeout: timeout,
    );
    return NormalizedImportResult.fromJson(response);
  }

  Future<int> push(List<SyncEnvelope> envelopes) async {
    final response = await _post('/api/sync/push', {
      'envelopes': envelopes.map((envelope) => envelope.toJson()).toList(),
    });
    return response['cursor'] as int;
  }

  Future<PullResult> pull(int since) async {
    final response = await _client.get(
      _uri('/api/sync/pull', {'since': '$since'}),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final envelopes = (data['envelopes'] as List? ?? const [])
        .map(
          (item) =>
              SyncEnvelope.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
    return PullResult(cursor: data['cursor'] as int, envelopes: envelopes);
  }

  Future<List<RelationEdge>> extractRelations({
    required String text,
    required String conversationId,
  }) async {
    final response = await _post('/api/analysis/relations/extract', {
      'text': text,
      'evidenceSegmentId': conversationId,
    });
    final relations = (response['relations'] as List? ?? const []).map((item) {
      final json = Map<String, dynamic>.from(item as Map);
      return RelationEdge(
        id: '${json['subject']}|${json['relation']}|${json['object']}|$conversationId',
        subject: json['subject'] as String,
        relation: json['relation'] as String,
        object: json['object'] as String,
        evidence: json['evidence'] as String,
        confidence: (json['confidence'] as num).toDouble(),
        evidenceConversationId: conversationId,
      );
    }).toList();
    return relations;
  }

  // ---------------------------------------------------------------------------
  // Images
  // ---------------------------------------------------------------------------

  Future<ImageItem> uploadImage(
    Uint8List bytes,
    String fileName,
    String contentType, {
    String? conversationId,
  }) async {
    final uri = _uri('/api/images');
    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll(_headers())
      ..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: fileName),
      );
    if (conversationId != null) {
      req.fields['conversationId'] = conversationId;
    }
    final streamed = await _client.send(req);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode == 402) throw QuotaExceededException(resp.body);
    _ensureSuccess(resp);
    return ImageItem.fromJson(
      Map<String, dynamic>.from(jsonDecode(resp.body) as Map),
    );
  }

  Future<List<ImageItem>> listImages({String? conversationId}) async {
    final query = conversationId != null
        ? {'conversationId': conversationId}
        : null;
    final response = await _client.get(
      _uri('/api/images', query),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List;
    return data
        .map((e) => ImageItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> deleteImage(String id) async {
    final response = await _client.delete(
      _uri('/api/images/$id'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  String imageUrl(String id) => _uri('/api/images/$id').toString();

  // ---------------------------------------------------------------------------
  // Quota / Premium
  // ---------------------------------------------------------------------------

  Future<QuotaStatus> getQuotaStatus() async {
    final response = await _client.get(
      _uri('/api/premium/status'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    return QuotaStatus.fromJson(
      Map<String, dynamic>.from(jsonDecode(response.body) as Map),
    );
  }

  Future<String> createCheckoutUrl(String plan) async {
    final response = await _post('/api/premium/checkout/$plan', {});
    return response['checkoutUrl'] as String;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = true,
    Duration? timeout,
  }) async {
    final request = _client.post(
      _uri(path),
      headers: _headers(authenticated: authenticated),
      body: jsonEncode(body),
    );
    final response = timeout == null
        ? await request
        : await request.timeout(timeout);
    _ensureSuccess(response);
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$normalized$path').replace(queryParameters: query);
  }

  Map<String, String> _headers({bool authenticated = true}) {
    final headers = <String, String>{'content-type': 'application/json'};
    if (authenticated && authToken != null) {
      headers['authorization'] = 'Bearer $authToken';
    }
    return headers;
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }
  }
}

class PullResult {
  PullResult({required this.cursor, required this.envelopes});

  final int cursor;
  final List<SyncEnvelope> envelopes;
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'API $statusCode: $body';
}

class QuotaExceededException implements Exception {
  QuotaExceededException(this.body);

  final String body;

  @override
  String toString() => 'Quota exceeded: $body';
}
