import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'browser_history_types.dart';
import 'document_credentials.dart';

const int defaultBrowserExtensionPort = 47615;
const int maxBrowserExtensionBody = 8 * 1024 * 1024;

/// Opt-in loopback HTTP receiver (desktop only) so the Lifenizer browser
/// extension can push YouTube/TikTok watch history straight into the vault.
///
/// The server binds to 127.0.0.1 only, requires a random bearer token, rejects
/// foreign Host and Origin headers (DNS rebinding, web pages) and never logs
/// the token or visit contents. Imports run through the same Takeout-shaped
/// batches as the browser-history watcher, one request at a time.
class BrowserExtensionReceiverService extends ChangeNotifier {
  BrowserExtensionReceiverService(
    this.state, {
    DocumentCredentialStore? store,
    ViewingBatchImporter? importer,
    Future<void> Function(int imported)? onImported,
    DateTime Function()? now,
    int? defaultPort,
    bool? supportedOverride,
  }) : _store = store ?? const DocumentCredentialStore(),
       _now = now ?? DateTime.now,
       _port = defaultPort ?? defaultBrowserExtensionPort,
       _onImported = onImported,
       _supported = supportedOverride ?? _desktop {
    _importer = importer ?? _importBatch;
  }

  static bool get _desktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  final LifenizerAppState state;
  final DocumentCredentialStore _store;
  final DateTime Function() _now;
  final bool _supported;
  final Future<void> Function(int imported)? _onImported;
  late final ViewingBatchImporter _importer;

  bool _enabled = false;
  int _port;
  String? _token;
  String? _identity;
  HttpServer? _server;
  Future<void> _serial = Future.value();
  Future<void> _lifecycle = Future.value();
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;
  String? error;
  DateTime? lastSync;
  int visitsAccepted = 0;
  int videosImported = 0;

  bool get supported => _supported;
  bool get enabled => _enabled;
  bool get listening => _server != null;

  /// The configured port, or the actual one once listening on an ephemeral port.
  int get port => _server?.port ?? _port;
  String? get token => _token;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started || _disposed || !_supported) return;
    _started = true;
    state.addListener(_stateChanged);
    _stateChanged();
  }

  void _stateChanged() {
    final identity = state.isAuthenticated
        ? jsonEncode([
            state.apiBaseUrl,
            state.rememberedEmail,
            state.session!.userId,
            state.session!.vaultId,
          ])
        : null;
    // Locking keeps the server up (answering 503) until another vault opens.
    if (identity == _identity || identity == null) {
      _identity = identity ?? _identity;
      return;
    }
    _generation++;
    _identity = identity;
    final generation = _generation;
    _lifecycle = _lifecycle.then((_) => _restore(identity, generation));
  }

  Future<void> _restore(String identity, int generation) async {
    try {
      final saved = await _store.read(identity, 'browser-extension');
      if (_disposed || generation != _generation) return;
      _enabled = saved?['enabled'] == true;
      _port = saved?['port'] as int? ?? _port;
      _token = saved?['token'] as String?;
      lastSync = DateTime.tryParse('${saved?['lastSync'] ?? ''}');
      visitsAccepted = saved?['visitsAccepted'] as int? ?? 0;
      videosImported = saved?['videosImported'] as int? ?? 0;
      error = null;
      if (_enabled && _token == null) _token = _newToken();
      await _apply();
    } catch (_) {
      if (!_disposed && generation == _generation) {
        error = 'Could not restore browser extension settings.';
      }
    }
    _notify();
  }

  static String _newToken() {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  Future<void> _save() async {
    if (_identity == null) return;
    try {
      await _store.write(_identity!, 'browser-extension', {
        'enabled': _enabled,
        'port': _port,
        'token': _token,
        'lastSync': lastSync?.toUtc().toIso8601String(),
        'visitsAccepted': visitsAccepted,
        'videosImported': videosImported,
      });
    } catch (_) {
      error ??= 'Could not save the browser extension settings.';
    }
  }

  /// Starts or stops the server so it matches [_enabled] and the port.
  Future<void> _apply() async {
    final wanted = _enabled && _token != null;
    if (_server != null && (!wanted || (_port != 0 && _server!.port != _port))) {
      await _stopServer();
    }
    if (wanted && _server == null) {
      try {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          _port,
        );
        _server = server;
        server.listen(
          (request) => unawaited(_handle(request, server.port)),
          onError: (_) {},
        );
      } on SocketException {
        _enabled = false;
        error =
            'Port $_port is already in use. Choose another port and enable '
            'the receiver again.';
      }
    }
  }

  Future<void> _stopServer() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> setEnabled(bool value) {
    start();
    if (_identity == null) {
      throw StateError('Unlock the vault before enabling the receiver.');
    }
    return _lifecycle = _lifecycle.then((_) async {
      _enabled = value;
      error = null;
      if (value) _token ??= _newToken();
      await _apply();
      await _save();
      _notify();
    });
  }

  Future<void> setPort(int value) {
    if (value < 0 || value > 65535) {
      throw const FormatException('Enter a port between 1 and 65535.');
    }
    return _lifecycle = _lifecycle.then((_) async {
      _port = value;
      error = null;
      await _apply();
      await _save();
      _notify();
    });
  }

  /// Replaces the token; the previous one stops working immediately.
  Future<void> regenerateToken() {
    start();
    if (_identity == null) {
      throw StateError('Unlock the vault before changing the token.');
    }
    return _lifecycle = _lifecycle.then((_) async {
      _token = _newToken();
      await _save();
      _notify();
    });
  }

  // ---- HTTP ---------------------------------------------------------------

  static bool _allowedOrigin(String origin) =>
      origin.startsWith('chrome-extension://') ||
      origin.startsWith('moz-extension://');

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < y.length; i++) {
      diff |= (i < x.length ? x[i] : 0) ^ y[i];
    }
    return diff == 0;
  }

  Future<void> _respond(
    HttpRequest request,
    int status,
    Object? body, {
    String? origin,
    bool close = false,
  }) async {
    final response = request.response;
    response.statusCode = status;
    if (origin != null) {
      response.headers
        ..set('Access-Control-Allow-Origin', origin)
        ..set('Vary', 'Origin');
    }
    if (close) response.headers.set('Connection', 'close');
    if (body != null) {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
    }
    await response.close();
  }

  Future<void> _handle(HttpRequest request, int boundPort) async {
    String? allowedOrigin;
    try {
      final hosts = request.headers['host'] ?? const [];
      final host = hosts.length == 1 ? hosts.single.toLowerCase() : '';
      if (host != '127.0.0.1:$boundPort' && host != 'localhost:$boundPort') {
        return await _respond(request, 403, {'error': 'forbidden-host'});
      }
      final origins = request.headers['origin'] ?? const [];
      if (origins.any((o) => !_allowedOrigin(o))) {
        return await _respond(request, 403, {'error': 'forbidden-origin'});
      }
      if (origins.length == 1) allowedOrigin = origins.single;

      if (request.method == 'OPTIONS') {
        if (allowedOrigin == null) {
          return await _respond(request, 403, {'error': 'forbidden-origin'});
        }
        request.response.headers
          ..set('Access-Control-Allow-Methods', 'GET, POST')
          ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type')
          ..set('Access-Control-Max-Age', '600');
        return await _respond(request, 204, null, origin: allowedOrigin);
      }

      final auth = request.headers.value('authorization') ?? '';
      final expected = _token;
      if (expected == null ||
          !auth.startsWith('Bearer ') ||
          !_constantTimeEquals(auth.substring(7), expected)) {
        return await _respond(
          request,
          401,
          {'error': 'unauthorized'},
          origin: allowedOrigin,
        );
      }

      final path = request.uri.path;
      if (path == '/v1/ping') {
        if (request.method != 'GET') {
          return await _respond(request, 405, {
            'error': 'method-not-allowed',
          }, origin: allowedOrigin);
        }
        return await _respond(request, 200, {
          'app': 'lifenizer',
          'unlocked': state.isAuthenticated,
        }, origin: allowedOrigin);
      }
      if (path == '/v1/watch-history') {
        if (request.method != 'POST') {
          return await _respond(request, 405, {
            'error': 'method-not-allowed',
          }, origin: allowedOrigin);
        }
        return await _watchHistory(request, allowedOrigin);
      }
      await _respond(request, 404, {'error': 'not-found'}, origin: allowedOrigin);
    } catch (_) {
      try {
        await _respond(request, 500, {'error': 'internal'}, origin: allowedOrigin);
      } catch (_) {}
    }
  }

  Future<void> _watchHistory(HttpRequest request, String? origin) async {
    if (!state.isAuthenticated) {
      return _respond(request, 503, {'error': 'locked'}, origin: origin);
    }
    final type = request.headers.contentType;
    if (type == null || type.mimeType != 'application/json') {
      return _respond(request, 415, {'error': 'json-only'}, origin: origin);
    }
    if (request.contentLength > maxBrowserExtensionBody) {
      return _respond(
        request,
        413,
        {'error': 'too-large'},
        origin: origin,
        close: true,
      );
    }
    final bytes = BytesBuilder(copy: false);
    var size = 0;
    try {
      await for (final chunk in request.timeout(const Duration(seconds: 30))) {
        size += chunk.length;
        if (size > maxBrowserExtensionBody) {
          return _respond(
            request,
            413,
            {'error': 'too-large'},
            origin: origin,
            close: true,
          );
        }
        bytes.add(chunk);
      }
    } on TimeoutException {
      return _respond(request, 400, {'error': 'timeout'}, origin: origin);
    }

    final List<_Pending> pending;
    try {
      pending = _parse(utf8.decode(bytes.takeBytes()));
    } on FormatException catch (e) {
      return _respond(request, 400, {
        'error': 'bad-request',
        'detail': e.message,
      }, origin: origin);
    }

    // Imports mutate the vault: process them strictly one at a time.
    final done = Completer<void>();
    final previous = _serial;
    _serial = done.future;
    try {
      await previous;
      if (!state.isAuthenticated) {
        return await _respond(request, 503, {'error': 'locked'}, origin: origin);
      }
      if (state.busy) {
        return await _respond(request, 503, {'error': 'busy'}, origin: origin);
      }
      final imported = await _import(pending);
      if (imported == null) {
        return await _respond(request, 503, {
          'error': 'import-failed',
        }, origin: origin);
      }
      visitsAccepted += pending.length;
      videosImported += imported;
      lastSync = _now();
      await _save();
      _notify();
      await _respond(request, 200, {
        'accepted': pending.length,
        'imported': imported,
      }, origin: origin);
      if (imported > 0 && _onImported != null) {
        try {
          await _onImported(imported);
        } catch (_) {}
      }
    } finally {
      done.complete();
    }
  }

  /// Validates the body and keeps only YouTube/TikTok video visits.
  static List<_Pending> _parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('Body is not valid JSON.');
    }
    if (decoded is! Map || decoded['visits'] is! List) {
      throw const FormatException('Expected an object with a visits array.');
    }
    if (decoded['version'] != null && decoded['version'] != 1) {
      throw const FormatException('Unsupported version.');
    }
    final result = <_Pending>[];
    for (final item in decoded['visits'] as List) {
      if (item is! Map || item['url'] is! String || item['time'] is! String) {
        throw const FormatException('Each visit needs a url and a time.');
      }
      final time = DateTime.tryParse(item['time'] as String);
      if (time == null) throw const FormatException('Invalid visit time.');
      final precision = item['timePrecision'] ?? 'exact';
      if (precision != 'exact' && precision != 'day') {
        throw const FormatException('Invalid timePrecision.');
      }
      final video = classifyVisit(
        BrowserVisit(
          url: item['url'] as String,
          title: item['title'] is String ? item['title'] as String : '',
          time: time,
        ),
      );
      if (video == null) continue;
      final channel = item['channel'];
      result.add(
        _Pending(
          VideoVisit(
            platform: video.platform,
            id: video.id,
            url: video.url,
            title: video.title,
            time: video.time,
            music: video.music,
            channel: video.platform == 'youtube' && channel is String
                ? channel.trim()
                : null,
          ),
          dayOnly: precision == 'day',
        ),
      );
    }
    return result;
  }

  static String _dayKey(DateTime time) {
    final local = time.toLocal();
    return '${local.year}-${local.month}-${local.day}';
  }

  /// Day-precision visits (local noon placeholders) are dropped when the same
  /// video already has a watch on that local day, in the vault or in this
  /// request. Exact visits are untouched; the same day visit re-sent later maps
  /// to the same second and merges server-side.
  List<VideoVisit> _dedupe(List<_Pending> pending) {
    final days = <String, Set<String>>{};
    for (final c in state.conversations) {
      final thread = c.sourceThreadId;
      if (thread == null || !c.source.endsWith('-watch-history')) continue;
      final set = days.putIfAbsent(thread, () => {});
      for (final s in c.segments) {
        set.add(_dayKey(s.createdAt));
      }
    }
    String key(VideoVisit v) => '${v.platform}:${v.id}';
    for (final p in pending.where((p) => !p.dayOnly)) {
      days.putIfAbsent(key(p.visit), () => {}).add(_dayKey(p.visit.time));
    }
    final out = <VideoVisit>[];
    final seenDay = <String>{};
    for (final p in pending) {
      if (p.dayOnly) {
        final day = _dayKey(p.visit.time);
        if (days[key(p.visit)]?.contains(day) ?? false) {
          // An already stored day-precision visit (same noon second) is
          // idempotent through the merge, so it needs no resend either.
          continue;
        }
        if (!seenDay.add('${key(p.visit)}@$day')) continue;
      }
      out.add(p.visit);
    }
    return out;
  }

  Future<int?> _import(List<_Pending> pending) async {
    var imported = 0;
    for (final batch in buildViewingBatches(_dedupe(pending))) {
      final added = await _importer(batch);
      if (added == null) return null;
      imported += added;
    }
    return imported;
  }

  Future<int?> _importBatch(ViewingImportBatch batch) async {
    state.lastImportSummary = null;
    await state.importSource(
      source: batch.source,
      title: 'Browser viewing history',
      text: batch.json,
      originalFileName: 'browser-extension.json',
      mimeType: 'application/json',
    );
    final summary = state.lastImportSummary;
    if (summary == null || state.error != null) return null;
    return summary.added;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    if (_started) state.removeListener(_stateChanged);
    unawaited(_stopServer());
    super.dispose();
  }
}

class _Pending {
  const _Pending(this.visit, {required this.dayOnly});
  final VideoVisit visit;
  final bool dayOnly;
}
