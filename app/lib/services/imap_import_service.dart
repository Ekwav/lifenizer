import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../app_state.dart';

/// Account passwords and UID cursors stay in the native OS credential store.
class ImapCredentialStore {
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  String _key(String identity) =>
      'lifenizer.imap.v1.${base64UrlEncode(utf8.encode(identity))}';
  Future<Map<String, dynamic>?> read(String identity) async {
    if (kIsWeb) return null;
    final value = await _storage.read(key: _key(identity));
    return value == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  Future<void> write(String identity, Map<String, dynamic> value) async {
    if (kIsWeb) {
      throw UnsupportedError('Remembering email requires the native app.');
    }
    await _storage.write(key: _key(identity), value: jsonEncode(value));
  }

  Future<void> remove(String identity) async {
    if (!kIsWeb) await _storage.delete(key: _key(identity));
  }
}

class EmailImportService extends ChangeNotifier {
  EmailImportService(this.state, {ImapCredentialStore? store})
    : _store = store ?? ImapCredentialStore();

  void start() {
    if (_started || _disposed) return;
    _started = true;
    state.addListener(_stateChanged);
    _stateChanged();
  }

  final LifenizerAppState state;
  final ImapCredentialStore _store;
  Map<String, dynamic>? _account;
  String? _identity;
  Timer? _timer;
  Future<void>? _running;
  int _generation = 0;
  bool _disposed = false;
  bool _started = false;
  Future<void>? _connection;
  String? status;
  String? error;
  bool get connected => _account != null;
  bool get working => _running != null || _connection != null;
  String? get username => _account?['username'] as String?;
  String? get mailbox => _account?['mailbox'] as String?;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _stateChanged() {
    final identity = state.isAuthenticated
        ? jsonEncode([
            state.apiBaseUrl,
            state.rememberedEmail,
            state.session!.userId,
          ])
        : null;
    if (_identity == identity) return;
    _generation++;
    _timer?.cancel();
    _account = null;
    _identity = identity;
    _notify();
    if (identity != null && !kIsWeb) unawaited(_restore(identity, _generation));
  }

  Future<void> _restore(String identity, int generation) async {
    try {
      final account = await _store.read(identity);
      if (_disposed ||
          _generation != generation ||
          _identity != identity ||
          account == null) {
        return;
      }
      _account = account;
      _schedule();
      _notify();
      await fetch();
    } catch (_) {
      if (_disposed || _generation != generation || _identity != identity) {
        return;
      }
      error =
          'Could not read the saved email account from the OS credential store.';
      _notify();
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (state.isAuthenticated && !state.busy) unawaited(fetch());
    });
  }

  void _validateSettings(Map<String, dynamic> settings) {
    if (settings['configured'] != true) {
      throw StateError('The server has no configured IMAP host.');
    }
    final api = Uri.parse(state.apiBaseUrl);
    if (api.scheme != 'https' &&
        !['localhost', '127.0.0.1', '::1'].contains(api.host)) {
      throw StateError('Email credentials require an HTTPS API connection.');
    }
    if (settings['useTls'] != true &&
        !['localhost', '127.0.0.1', '::1'].contains(settings['host'])) {
      throw StateError('The configured IMAP server must use TLS.');
    }
  }

  Future<void> connect({
    required String username,
    required String password,
    String mailbox = 'INBOX',
    bool remember = true,
  }) {
    if (working || state.busy || !state.isAuthenticated) return Future.value();
    _connection = _connect(username, password, mailbox, remember).whenComplete(
      () {
        _connection = null;
        _notify();
      },
    );
    _notify();
    return _connection!;
  }

  Future<void> _connect(
    String username,
    String password,
    String mailbox,
    bool remember,
  ) async {
    start();
    _generation++;
    final generation = _generation;
    final old = _account;
    try {
      error = null;
      if (username.trim().isEmpty ||
          password.isEmpty ||
          mailbox.trim().isEmpty) {
        throw ArgumentError(
          'Enter an email username, app password and mailbox.',
        );
      }
      final identity = _identity!;
      final settings = await state.imapSettings();
      _validateSettings(settings);
      if (_generation != generation ||
          _identity != identity ||
          !state.isAuthenticated) {
        return;
      }
      final sameMailbox =
          old != null &&
          old['username'] == username.trim() &&
          old['host'] == settings['host'] &&
          old['port'] == settings['port'] &&
          old['mailbox'] == mailbox.trim();
      _account = {
        'username': username.trim(),
        'password': password,
        'mailbox': mailbox.trim(),
        'host': settings['host'],
        'port': settings['port'],
        'remember': remember && !kIsWeb,
        'afterUid': sameMailbox ? old['afterUid'] ?? '0' : '0',
        'uidValidity': sameMailbox ? old['uidValidity'] ?? '0' : '0',
      };
      // Preserve an existing saved account if storing the replacement fails.
      if (_account!['remember'] == true) {
        await _store.write(identity, _account!);
      } else {
        await _store.remove(identity);
      }
      if (_generation != generation ||
          _identity != identity ||
          !state.isAuthenticated) {
        return;
      }
      _schedule();
      await fetch();
    } catch (exception) {
      if (_generation == generation) {
        _account = old;
        error = exception.toString();
      }
    }
    _notify();
  }

  Future<void> fetch() {
    if (_running != null) return _running!;
    if (_account == null || !state.isAuthenticated || state.busy) {
      return Future.value();
    }
    final operation = _fetch();
    _running = operation.whenComplete(() {
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
    try {
      error = null;
      final settings = await state.imapSettings();
      _validateSettings(settings);
      if (settings['host'] != account['host'] ||
          settings['port'] != account['port']) {
        throw StateError(
          'The configured IMAP server changed. Reconnect before sending credentials.',
        );
      }
      var messages = 0;
      for (var page = 0; page < 20; page++) {
        if (_disposed ||
            _generation != generation ||
            _identity != identity ||
            !state.isAuthenticated) {
          return;
        }
        status = 'Importing email page ${page + 1}…';
        _notify();
        final result = await state.importEmailPage({
          'username': account['username'] as String,
          'password': account['password'] as String,
          'mailbox': account['mailbox'] as String,
          'limit': '25',
          'afterUid': account['afterUid'] as String? ?? '0',
          'uidValidity': account['uidValidity'] as String? ?? '0',
        });
        if (result == null) {
          error = state.error ?? 'Email import paused while the vault is busy.';
          return;
        }
        if (_disposed || _generation != generation || _identity != identity) {
          return;
        }
        final diagnostics = result.diagnostics;
        if (diagnostics['nextUid'] == null ||
            diagnostics['uidValidity'] == null) {
          throw StateError(
            'The email server response has no safe resume cursor.',
          );
        }
        account['afterUid'] = diagnostics['nextUid'];
        account['uidValidity'] = diagnostics['uidValidity'];
        // Local encrypted ingestion completed before the credential-store cursor advances.
        if (account['remember'] == true) await _store.write(identity, account);
        if (_disposed || _generation != generation || _identity != identity) {
          return;
        }
        _account = Map<String, dynamic>.from(account);
        messages += result.conversations.length;
        if (diagnostics['hasMore'] != 'true') {
          status =
              '$messages email message(s) checked · saved encrypted. Checking every 5 minutes while unlocked.';
          return;
        }
      }
      status =
          '$messages email message(s) checked · more remain. Continuing at the next check.';
    } catch (exception) {
      if (_generation == generation) error = exception.toString();
    }
  }

  Future<void> removeAccount() async {
    final identity = _identity;
    _generation++;
    _timer?.cancel();
    _account = null;
    status =
        'Email checking stopped. Imported conversations remain in your vault.';
    error = null;
    _notify();
    try {
      await _connection;
      await _running;
      if (identity != null) await _store.remove(identity);
    } catch (_) {
      error =
          'Could not remove the saved email account from the OS credential store. Retry removal.';
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
    super.dispose();
  }
}
