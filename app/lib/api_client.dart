import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class LifenizerApiClient {
  LifenizerApiClient({required this.baseUrl, this.authToken});

  final String baseUrl;
  final String? authToken;

  LifenizerApiClient authenticated(String token) {
    return LifenizerApiClient(baseUrl: baseUrl, authToken: token);
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
    final response = await http.get(_uri('/api/imports/capabilities'));
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List;
    return data
        .map(
          (item) =>
              ImportCapability.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  Future<NormalizedImportResult> importSource(
    String source,
    ImportSourceRequest request,
  ) async {
    final response = await _post('/api/imports/$source', request.toJson());
    return NormalizedImportResult.fromJson(response);
  }

  Future<int> push(List<SyncEnvelope> envelopes) async {
    final response = await _post('/api/sync/push', {
      'envelopes': envelopes.map((envelope) => envelope.toJson()).toList(),
    });
    return response['cursor'] as int;
  }

  Future<PullResult> pull(int since) async {
    final response = await http.get(
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

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = true,
  }) async {
    final response = await http.post(
      _uri(path),
      headers: _headers(authenticated: authenticated),
      body: jsonEncode(body),
    );
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
