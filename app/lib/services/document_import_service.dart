import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'document_credentials.dart';
import 'document_folder_watch_service.dart';

class DocumentImportService extends ChangeNotifier {
  DocumentImportService(this.state, {DocumentCredentialStore? store})
    : _store = store ?? const DocumentCredentialStore(),
      folders = DocumentFolderWatchService(state, store: store) {
    folders.addListener(_notify);
  }
  final LifenizerAppState state;
  final DocumentCredentialStore _store;
  final DocumentFolderWatchService folders;
  Map<String, dynamic>? _account;
  String? _identity;
  Timer? _timer;
  Future<void>? _running;
  Future<void>? _connection;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;
  String? status;
  String? error;
  bool get connected => _account != null;
  bool get working => _running != null || _connection != null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    folders.start();
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
    if (_identity == identity) return;
    _generation++;
    _timer?.cancel();
    _account = null;
    status = null;
    error = null;
    _identity = identity;
    _notify();
    if (identity != null && !kIsWeb) unawaited(_restore(identity, _generation));
  }

  bool _current(String identity, int generation) =>
      !_disposed &&
      _identity == identity &&
      _generation == generation &&
      state.isAuthenticated;
  Future<void> _restore(String identity, int generation) async {
    try {
      final account = await _store.read(identity, 'paperless');
      if (!_current(identity, generation) || account == null) return;
      _account = account;
      _schedule();
      _notify();
      await fetch();
    } catch (_) {
      if (_current(identity, generation)) {
        error = 'Could not restore Paperless from the OS credential store.';
        _notify();
      }
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(fetch()),
    );
  }

  Future<void> connect({required String token, bool remember = true}) {
    if (working || state.busy || !state.isAuthenticated) return Future.value();
    _connection = _connect(token, remember).whenComplete(() {
      _connection = null;
      _notify();
    });
    _notify();
    return _connection!;
  }

  Future<void> _connect(String token, bool remember) async {
    start();
    if (state.busy || _identity == null) return;
    if (token.trim().isEmpty) {
      error = 'Enter your Paperless API token.';
      _notify();
      return;
    }
    final api = Uri.parse(state.apiBaseUrl);
    if (api.scheme != 'https' &&
        !['localhost', '127.0.0.1', '::1'].contains(api.host)) {
      error = 'Paperless credentials require an HTTPS server connection.';
      _notify();
      return;
    }
    final identity = _identity!;
    final generation = ++_generation;
    final old = _account;
    final account = <String, dynamic>{
      'token': token.trim(), 'remember': remember && !kIsWeb,
      // A replacement token can belong to a different Paperless instance/account.
      'page': '1',
    };
    try {
      error = null;
      final settings = await state.paperlessSettings();
      if (!_current(identity, generation)) return;
      if (settings['configured'] != true || settings['baseUrl'] is! String) {
        error = 'The server has no configured Paperless address.';
        return;
      }
      account['baseUrl'] = settings['baseUrl'];
      if (account['remember'] == true) {
        await _store.write(identity, 'paperless', account);
      } else {
        await _store.remove(identity, 'paperless');
      }
      if (!_current(identity, generation)) return;
      _account = account;
      _schedule();
      await fetch();
    } catch (_) {
      if (_current(identity, generation)) {
        _account = old;
        error =
            'Could not save the Paperless connection in the OS credential store.';
      }
    }
    _notify();
  }

  Future<void> fetch() {
    if (_running != null) return _running!;
    if (_account == null || _identity == null || state.busy) {
      return Future.value();
    }
    _running = _fetch().whenComplete(() {
      _running = null;
      _notify();
    });
    _notify();
    return _running!;
  }

  Future<void> _fetch() async {
    final identity = _identity!;
    final generation = _generation;
    final account = Map<String, dynamic>.from(_account!);
    var documents = 0;
    try {
      error = null;
      final settings = await state.paperlessSettings();
      if (!_current(identity, generation)) return;
      if (settings['configured'] != true ||
          settings['baseUrl'] != account['baseUrl']) {
        error =
            'The configured Paperless server changed. Reconnect before sending the token.';
        return;
      }
      account['cycleStartedAt'] ??= DateTime.now().toUtc().toIso8601String();
      for (var batch = 0; batch < 20; batch++) {
        if (!_current(identity, generation) || state.busy) return;
        status = 'Importing Paperless page ${account['page']}…';
        _notify();
        final result = await state.importPaperlessPage({
          'token': account['token'] as String,
          'page': account['page'] as String? ?? '1',
          'limit': '10',
          if (account['modifiedAfter'] != null)
            'modifiedAfter': account['modifiedAfter'] as String,
        });
        if (!_current(identity, generation)) return;
        if (result == null) {
          error =
              state.error ??
              'Paperless import paused. The page will be retried.';
          return;
        }
        final diagnostics = result.diagnostics;
        final hasMore = diagnostics['hasMore'] == 'true';
        final nextPage = diagnostics['nextPage'];
        if (hasMore &&
            (int.tryParse(nextPage ?? '') ?? 0) <=
                (int.tryParse(account['page'] as String? ?? '1') ?? 1)) {
          throw const FormatException(
            'Paperless returned an invalid page cursor.',
          );
        }
        final candidate = diagnostics['nextModifiedAfter'];
        if (candidate != null && candidate.isNotEmpty) {
          final date = DateTime.parse(candidate);
          final previous = DateTime.tryParse(
            account['pendingModifiedAfter'] as String? ?? '',
          );
          if (previous == null || date.isAfter(previous)) {
            account['pendingModifiedAfter'] = candidate;
          }
        }
        documents += result.conversations.length;
        account['page'] = hasMore ? nextPage : '1';
        if (!hasMore) {
          if (account['pendingModifiedAfter'] != null) {
            // Replay changes made during pagination as well as tied timestamps.
            final maximum = DateTime.parse(
              account['pendingModifiedAfter'] as String,
            );
            final started = DateTime.parse(account['cycleStartedAt'] as String);
            account['modifiedAfter'] =
                (maximum.isBefore(started) ? maximum : started)
                    .subtract(const Duration(minutes: 1))
                    .toUtc()
                    .toIso8601String();
          }
          account.remove('pendingModifiedAfter');
          account.remove('cycleStartedAt');
        }
        // The state hook completes encrypted persistence before advancing cursors.
        if (account['remember'] == true) {
          await _store.write(identity, 'paperless', account);
        }
        if (!_current(identity, generation)) return;
        _account = Map<String, dynamic>.from(account);
        if (!hasMore) {
          status =
              '$documents Paperless documents checked · saved encrypted. Checking every 5 minutes while unlocked.';
          return;
        }
      }
      status =
          '$documents Paperless documents checked · continuing at the next check.';
    } catch (_) {
      if (_current(identity, generation)) {
        error =
            'Paperless import failed. Check its server configuration and API token; the current page will be retried.';
      }
    }
  }

  Future<void> removeAccount() async {
    final identity = _identity;
    _generation++;
    _timer?.cancel();
    _account = null;
    error = null;
    status =
        'Paperless checking stopped. Indexed documents remain in your vault.';
    _notify();
    try {
      await _connection;
      await _running;
      if (identity != null) await _store.remove(identity, 'paperless');
    } catch (_) {
      error = 'Could not remove the saved Paperless connection. Retry removal.';
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _account = null;
    if (_started) state.removeListener(_stateChanged);
    folders.removeListener(_notify);
    folders.dispose();
    super.dispose();
  }
}
