import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'models.dart';
import 'services/request_cancellation.dart';
import 'services/vault_worker_io.dart'
    if (dart.library.js_interop) 'services/vault_worker_web.dart';

class LifenizerApiClient {
  LifenizerApiClient({
    required this.baseUrl,
    this.authToken,
    this.refreshAuth,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  String? authToken;
  final Future<String?> Function()? refreshAuth;
  final http.Client _client;

  LifenizerApiClient authenticated(
    String token, {
    Future<String?> Function()? refreshAuth,
  }) {
    return LifenizerApiClient(
      baseUrl: baseUrl,
      authToken: token,
      refreshAuth: refreshAuth,
      client: _client,
    );
  }

  Future<Map<String, dynamic>> requestPairing(Map<String, dynamic> body) =>
      _post('/api/pairing/request', body, authenticated: false);
  Future<Map<String, dynamic>> pollPairing(String id, String token) => _post(
    '/api/pairing/$id/poll',
    {'requestToken': token},
    authenticated: false,
  );
  Future<Map<String, dynamic>> refreshPairing(String? id, String token) =>
      _post('/api/pairing/refresh', {
        'deviceId': id,
        'refreshToken': token,
      }, authenticated: false);
  Future<List<Map<String, dynamic>>> pendingPairings() async {
    final response = await _get('/api/pairing/pending');
    _ensureSuccess(response);
    return (jsonDecode(response.body) as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
  }

  Future<void> approvePairing(String id, Map<String, dynamic> transfer) async {
    await _post('/api/pairing/$id/approve', transfer);
  }

  Future<void> denyPairing(String id) async {
    await _post('/api/pairing/$id/deny', {});
  }

  Future<AuthSession> accountLogin({
    required String email,
    required String password,
    bool register = false,
    String? registrationToken,
  }) async => AuthSession.fromJson(
    await _post(register ? '/api/auth/register' : '/api/auth/login', {
      'email': email,
      'password': password,
      if (register && registrationToken?.trim().isNotEmpty == true)
        'registrationToken': registrationToken!.trim(),
    }, authenticated: false),
  );

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

  Future<Map<String, dynamic>> tabTrainingNotice() async {
    final response = await _get('/api/training/tab/notice');
    _ensureSuccess(response);
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> grantTabTrainingConsent(
    Map<String, dynamic> body,
  ) => _post('/api/training/tab/consents', body);

  Future<Map<String, dynamic>> submitTabCorrection(Map<String, dynamic> body) =>
      _post(
        '/api/training/tab/corrections',
        body,
        timeout: const Duration(minutes: 2),
      );

  Future<void> withdrawTabTrainingConsent(
    String id,
    String contributionKey,
  ) async {
    await _post(
      '/api/training/tab/consents/${Uri.encodeComponent(id)}/withdraw',
      {'contributionKey': contributionKey},
    );
  }

  /// Runs an import for [source] with the given [request].
  ///
  /// [timeout] overrides the default 30-second wait for this call. Audio
  /// transcription uses [importAudio] instead, which can be cancelled.
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

  /// Uploads [audio] as multipart form data for transcription: a JSON
  /// `metadata` part and an `audio` part typed as [ImportSourceRequest.mimeType].
  ///
  /// Both [cancellation] and [timeout] abort the HTTP request, which closes
  /// the connection so the server stops transcribing. Cancelling throws
  /// [RequestCancelledException]; the timeout throws [TimeoutException].
  Future<NormalizedImportResult> importAudio(
    ImportSourceRequest request, {
    required List<int> audio,
    required Duration timeout,
    RequestCancellation? cancellation,
  }) async {
    final response = await _sendAbortable(
      (abortTrigger) => _audioUploadRequest(request, audio, abortTrigger),
      timeout: timeout,
      cancellation: cancellation,
    );
    _ensureSuccess(response);
    return NormalizedImportResult.fromJson(_decodeObject(response));
  }

  http.MultipartRequest _audioUploadRequest(
    ImportSourceRequest request,
    List<int> audio,
    Future<void> abortTrigger,
  ) {
    final metadata = request.toJson()..remove('payloadBase64');
    return http.AbortableMultipartRequest(
        'POST',
        _uri('/api/imports/audio/upload'),
        abortTrigger: abortTrigger,
      )
      ..headers.addAll(_authHeaders())
      ..files.add(
        http.MultipartFile.fromString(
          'metadata',
          jsonEncode(metadata),
          contentType: MediaType('application', 'json'),
        ),
      )
      ..files.add(
        http.MultipartFile.fromBytes(
          'audio',
          audio,
          filename: request.originalFileName ?? 'recording',
          contentType: MediaType.parse(request.mimeType ?? 'audio/wav'),
        ),
      );
  }

  Future<Map<String, dynamic>> imapSettings() async {
    final response = await _get('/api/imports/email/settings');
    _ensureSuccess(response);
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> paperlessSettings() async {
    final response = await _get('/api/imports/paperless/settings');
    _ensureSuccess(response);
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<int> push(List<SyncEnvelope> envelopes) async {
    final response = await _post('/api/sync/push', {
      'envelopes': envelopes.map((envelope) => envelope.toJson()).toList(),
    });
    return response['cursor'] as int;
  }

  Future<PullResult> pull(
    int since, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final response = onProgress == null
        ? await _get('/api/sync/pull', {'since': '$since'})
        : await _retry(() async {
            final request = http.Request(
              'GET',
              _uri('/api/sync/pull', {'since': '$since'}),
            )..headers.addAll(_headers());
            final streamed = await _client
                .send(request)
                .timeout(const Duration(seconds: 30));
            final bytes = BytesBuilder(copy: false);
            final total = streamed.contentLength;
            final successful =
                streamed.statusCode >= 200 && streamed.statusCode < 300;
            if (successful) onProgress(0, total);
            // A stream timeout cancels the subscription when await-for exits.
            // Keep receiving a large vault while bytes continue to arrive.
            await for (final chunk in streamed.stream.timeout(
              const Duration(seconds: 30),
            )) {
              bytes.add(chunk);
              if (successful) onProgress(bytes.length, total);
            }
            return http.Response.bytes(
              bytes.takeBytes(),
              streamed.statusCode,
              headers: streamed.headers,
            );
          });
    _ensureSuccess(response);
    final bytes = response.bodyBytes;
    return bytes.length > 64 * 1024
        ? await _decodePullInWorker(bytes)
        : _decodePull(bytes);
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
    final resp = await _retry(() async {
      final uri = _uri('/api/images');
      final req = http.MultipartRequest('POST', uri)
        ..headers.addAll(_headers())
        ..files.add(
          http.MultipartFile.fromBytes(
            'file',
            bytes,
            filename: fileName,
            contentType: MediaType.parse(contentType),
          ),
        );
      if (conversationId != null) {
        req.fields['conversationId'] = conversationId;
      }
      return http.Response.fromStream(await _client.send(req));
    });
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
    final response = await _get('/api/images', query);
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List;
    return data
        .map((e) => ImageItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> deleteImage(String id) async {
    final response = await _retry(
      () => _client.delete(_uri('/api/images/$id'), headers: _headers()),
    );
    _ensureSuccess(response);
  }

  Future<Uint8List> downloadImage(String id) async {
    final response = await _get('/api/images/$id');
    _ensureSuccess(response);
    return response.bodyBytes;
  }

  // ---------------------------------------------------------------------------
  // Quota / Premium
  // ---------------------------------------------------------------------------

  Future<QuotaStatus> getQuotaStatus() async {
    final response = await _get('/api/premium/status');
    _ensureSuccess(response);
    return QuotaStatus.fromJson(
      Map<String, dynamic>.from(jsonDecode(response.body) as Map),
    );
  }

  Future<String> createCheckoutUrl(String plan) async {
    final response = await _post('/api/premium/checkout/$plan', {});
    return response['checkoutUrl'] as String;
  }

  Future<QuotaStatus> activateFreePremium() async =>
      QuotaStatus.fromJson(await _post('/api/premium/activate', {}));

  Future<QuotaStatus> cancelFreePremium() async =>
      QuotaStatus.fromJson(await _post('/api/premium/cancel-free', {}));

  Future<void> submitCancellationFeedback(String feedback) async {
    await _post('/api/premium/cancellation-feedback', {'feedback': feedback});
  }

  Future<Map<String, dynamic>> getRecording(String id) async {
    final response = await _retry(
      () => _client
          .get(
            _uri('/api/recordings/${Uri.encodeComponent(id)}'),
            headers: _headers(),
          )
          .timeout(const Duration(minutes: 5)),
    );
    _ensureSuccess(response);
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> putRecording(String id, Map<String, dynamic> encrypted) async {
    final response = await _retry(
      () => _client
          .put(
            _uri('/api/recordings/${Uri.encodeComponent(id)}'),
            headers: _headers(),
            body: jsonEncode(encrypted),
          )
          .timeout(const Duration(minutes: 5)),
    );
    _ensureSuccess(response);
  }

  Future<void> deleteRecording(String id) async {
    final response = await _retry(
      () => _client
          .delete(
            _uri('/api/recordings/${Uri.encodeComponent(id)}'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30)),
    );
    if (response.statusCode != 404) _ensureSuccess(response);
  }

  Future<void> answerRecordingRequest(
    String requestId,
    Map<String, dynamic> encrypted, {
    http.Client? client,
  }) async {
    final response = await (client ?? _client)
        .post(
          _uri('/api/recordings/requests/${Uri.encodeComponent(requestId)}'),
          headers: _headers(),
          body: jsonEncode(encrypted),
        )
        .timeout(const Duration(minutes: 5));
    _ensureSuccess(response);
  }

  /// The caller owns this dedicated client's lifetime to cancel on vault lock.
  Stream<Map<String, dynamic>> recordingRequests(http.Client client) async* {
    Future<http.StreamedResponse> connect() => client.send(
      http.Request('GET', _uri('/api/recordings/requests'))
        ..headers.addAll(_headers())
        ..headers['accept'] = 'text/event-stream',
    );
    var response = await connect();
    if (response.statusCode == 401 && refreshAuth != null) {
      await response.stream.drain<void>();
      final token = await refreshAuth!();
      if (token != null) {
        authToken = token;
        response = await connect();
      }
    }
    if (response.statusCode != 200) {
      _ensureSuccess(await http.Response.fromStream(response));
      return;
    }
    var event = '';
    var dataLength = 0;
    final data = <String>[];
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.length > 8192) {
        throw const FormatException('Recording request too large.');
      }
      if (line.isEmpty) {
        if (event == 'request' && data.isNotEmpty) {
          yield Map<String, dynamic>.from(jsonDecode(data.join('\n')) as Map);
        }
        event = '';
        dataLength = 0;
        data.clear();
      } else if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLength += line.length;
        if (dataLength > 8192) {
          throw const FormatException('Recording request too large.');
        }
        data.add(line.substring(5).trimLeft());
      }
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = true,
    Duration? timeout,
  }) async {
    final response = await _retry(
      () => _client
          .post(
            _uri(path),
            headers: _headers(authenticated: authenticated),
            body: jsonEncode(body),
          )
          .timeout(timeout ?? const Duration(seconds: 30)),
      authenticated: authenticated,
    );
    _ensureSuccess(response);
    return _decodeObject(response);
  }

  Map<String, dynamic> _decodeObject(http.Response response) =>
      response.body.isEmpty
      ? <String, dynamic>{}
      : Map<String, dynamic>.from(jsonDecode(response.body) as Map);

  /// Sends a fresh request from [build] per attempt (401 retries included).
  /// Any failure after the abort fired is reported as the abort's reason.
  Future<http.Response> _sendAbortable(
    http.BaseRequest Function(Future<void> abortTrigger) build, {
    required Duration timeout,
    RequestCancellation? cancellation,
  }) async {
    final abort = _AbortSignal(timeout, cancellation);
    try {
      return await _retry(() => _sendOnce(build, abort));
    } catch (_) {
      if (!abort.fired) rethrow;
      throw abort.reason();
    } finally {
      abort.dispose();
    }
  }

  Future<http.Response> _sendOnce(
    http.BaseRequest Function(Future<void> abortTrigger) build,
    _AbortSignal abort,
  ) {
    // Do not open a connection for a request that is already aborted.
    if (abort.fired) return Future.error(abort.reason());
    final request = build(abort.trigger);
    final response = _client.send(request).then(http.Response.fromStream);
    // Also fail on abort if a platform client ignores `abortTrigger`.
    final aborted = abort.trigger.then<http.Response>(
      (_) => throw http.RequestAbortedException(request.url),
    );
    return Future.any([response, aborted]);
  }

  Future<http.Response> _get(String path, [Map<String, String>? query]) =>
      _retry(
        () => _client
            .get(_uri(path, query), headers: _headers())
            .timeout(const Duration(seconds: 30)),
      );

  Future<http.Response> _retry(
    Future<http.Response> Function() request, {
    bool authenticated = true,
  }) async {
    var response = await request();
    if (authenticated && response.statusCode == 401 && refreshAuth != null) {
      final token = await refreshAuth!();
      if (token != null) {
        authToken = token;
        response = await request();
      }
    }
    return response;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$normalized$path').replace(queryParameters: query);
  }

  Map<String, String> _headers({bool authenticated = true}) => {
    'content-type': 'application/json',
    if (authenticated) ..._authHeaders(),
  };

  Map<String, String> _authHeaders() => {
    if (authToken != null) 'authorization': 'Bearer $authToken',
  };

  void _ensureSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final retry = int.tryParse(response.headers['retry-after'] ?? '');
      throw ApiException(
        response.statusCode,
        response.body,
        retryAfter: retry == null || retry < 0
            ? null
            : Duration(seconds: retry),
      );
    }
  }
}

/// Aborts a request on user cancellation or when [timeout] elapses.
class _AbortSignal {
  _AbortSignal(this.timeout, this._cancellation) {
    _timer = Timer(timeout, _expire);
    _cancellation?.whenCancelled.then((_) => _fire());
  }

  final Duration timeout;
  final RequestCancellation? _cancellation;
  final Completer<void> _fired = Completer<void>();
  late final Timer _timer;
  bool _timedOut = false;

  Future<void> get trigger => _fired.future;

  // Also true right after cancel(), before [trigger] has completed.
  bool get fired => _fired.isCompleted || (_cancellation?.isCancelled ?? false);

  Exception reason() => _timedOut
      ? TimeoutException('The server did not answer in time.', timeout)
      : const RequestCancelledException();

  void dispose() => _timer.cancel();

  void _expire() {
    if (fired) return;
    _timedOut = true;
    _fire();
  }

  void _fire() {
    if (!_fired.isCompleted) _fired.complete();
  }
}

class PullResult {
  PullResult({required this.cursor, required this.envelopes});

  final int cursor;
  final List<SyncEnvelope> envelopes;
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.body, {this.retryAfter});

  final int statusCode;
  final String body;

  /// Parsed `Retry-After` header (seconds form), when the server sent one.
  final Duration? retryAfter;

  /// Machine-readable `error` code of a JSON error body, e.g.
  /// `transcript_unavailable` or `provider_blocked`.
  String? get errorCode {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded['error']?.toString() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'API $statusCode: $body';
}

class QuotaExceededException implements Exception {
  QuotaExceededException(this.body);

  final String body;

  @override
  String toString() => 'Quota exceeded: $body';
}

PullResult _decodePull(Uint8List bytes) {
  final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final envelopes = (data['envelopes'] as List? ?? const [])
      .map(
        (item) => SyncEnvelope.fromJson(Map<String, dynamic>.from(item as Map)),
      )
      .toList();
  return PullResult(cursor: data['cursor'] as int, envelopes: envelopes);
}

Future<PullResult> _decodePullInWorker(Uint8List bytes) =>
    runVaultWork(() async => _decodePull(bytes));
