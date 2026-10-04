import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'document_credentials.dart';

/// Nonrecursive document watches: no links, no automatic folder enrollment.
class DocumentFolderWatchService extends ChangeNotifier {
  DocumentFolderWatchService(
    this.state, {
    DocumentCredentialStore? store,
    Future<bool> Function(String)? importFile,
  }) : _importFile = importFile,
       _store = store ?? const DocumentCredentialStore();
  final LifenizerAppState state;
  final Future<bool> Function(String)? _importFile;
  final DocumentCredentialStore _store;
  final _folders = <String>[];
  final _stamps = <String, String>{};
  final _events = <StreamSubscription<FileSystemEvent>>[];
  String? _identity;
  Timer? _timer;
  Timer? _debounce;
  Future<void>? _running;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;
  bool _restoring = false;
  String? status;
  String? error;
  List<String> get folders => List.unmodifiable(_folders);
  bool get working => _running != null || _restoring;
  String? get downloadsPath {
    final home =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    return home == null ? null : '$home${Platform.pathSeparator}Downloads';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started || _disposed || Platform.isAndroid || Platform.isIOS) return;
    _started = true;
    state.addListener(_stateChanged);
    _stateChanged();
  }

  void _cancelEvents() {
    for (final event in _events) {
      unawaited(event.cancel());
    }
    _events.clear();
    _timer?.cancel();
    _debounce?.cancel();
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
    if (identity == _identity) return;
    _generation++;
    _cancelEvents();
    _folders.clear();
    _stamps.clear();
    _restoring = false;
    status = null;
    error = null;
    _identity = identity;
    _notify();
    if (identity != null) unawaited(_restore(identity, _generation));
  }

  Future<void> _restore(String identity, int generation) async {
    _restoring = true;
    try {
      final saved = await _store.read(identity, 'folders');
      if (!_current(identity, generation)) return;
      _folders.addAll((saved?['folders'] as List? ?? []).cast<String>());
      _stamps.addAll(Map<String, String>.from(saved?['stamps'] as Map? ?? {}));
      _listen();
    } catch (_) {
      if (_current(identity, generation)) {
        error =
            'Could not restore document folders from the OS credential store.';
      }
    } finally {
      if (_current(identity, generation)) _restoring = false;
      _notify();
    }
    if (_current(identity, generation)) await check();
  }

  bool _current(String identity, int generation) =>
      !_disposed &&
      _identity == identity &&
      _generation == generation &&
      state.isAuthenticated;
  Future<void> _save() => _store.write(_identity!, 'folders', {
    'folders': List<String>.from(_folders),
    'stamps': Map<String, String>.from(_stamps),
  });
  Future<void> addFolder(String path) async {
    start();
    if (_identity == null || working) {
      throw StateError('Unlock the desktop vault before choosing a folder.');
    }
    final identity = _identity!;
    final generation = _generation;
    final directory = Directory(path).absolute;
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException(
        'Choose an existing folder, rather than a symbolic link.',
      );
    }
    if (!_current(identity, generation) || _folders.contains(directory.path)) {
      return;
    }
    _folders.add(directory.path);
    try {
      await _save();
    } catch (_) {
      _folders.remove(directory.path);
      rethrow;
    }
    if (!_current(identity, generation)) return;
    _listen();
    _notify();
    await check();
  }

  Future<void> removeFolder(String path) async {
    if (_identity == null || working) return;
    final identity = _identity!;
    final generation = _generation;
    _folders.remove(path);
    _stamps.removeWhere((file, _) => File(file).parent.path == path);
    await _save();
    if (!_current(identity, generation)) return;
    _listen();
    _notify();
  }

  void _listen() {
    _cancelEvents();
    for (final path in _folders) {
      try {
        _events.add(
          Directory(path).watch().listen((_) {
            _debounce?.cancel();
            _debounce = Timer(
              const Duration(seconds: 5),
              () => unawaited(check()),
            );
          }, onError: (Object _) {}),
        );
      } on FileSystemException {
        /* Polling also handles renamed folders. */
      }
    }
    _timer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(check()),
    );
  }

  Future<void> check() {
    if (_running != null) return _running!;
    if (_identity == null || _folders.isEmpty || state.busy || _restoring) {
      return Future.value();
    }
    _running = _check().whenComplete(() {
      _running = null;
      _notify();
    });
    _notify();
    return _running!;
  }

  Future<void> _check() async {
    final identity = _identity!;
    final generation = _generation;
    var imported = 0;
    try {
      error = null;
      for (final folder in List<String>.from(_folders)) {
        if (!_current(identity, generation)) return;
        final directory = Directory(folder);
        if (await FileSystemEntity.type(folder, followLinks: false) !=
            FileSystemEntityType.directory) {
          continue;
        }
        await for (final entry in directory.list(followLinks: false)) {
          if (!_current(identity, generation) || state.busy) return;
          if (entry is! File ||
              !RegExp(
                r'\.(pdf|png|jpe?g)$',
                caseSensitive: false,
              ).hasMatch(entry.path)) {
            continue;
          }
          final stat = await entry.stat();
          if (!_current(identity, generation) || state.busy) return;
          if (stat.size == 0 || stat.size > 25 * 1024 * 1024) continue;
          // Give scanners/downloaders time to finish replacing or writing the file.
          if (DateTime.now().difference(stat.modified) <
              const Duration(seconds: 5)) {
            continue;
          }
          final stamp = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
          if (_stamps[entry.path] == stamp) continue;
          status = 'Indexing document ${imported + 1}…';
          _notify();
          if (!await (_importFile ?? state.importDocumentFile)(entry.path)) {
            if (!_current(identity, generation)) return;
            error =
                state.error ?? 'Document import paused. It will be retried.';
            return;
          }
          if (!_current(identity, generation)) return;
          final after = await entry.stat();
          if (!_current(identity, generation)) return;
          if (after.size != stat.size || after.modified != stat.modified) {
            continue;
          }
          _stamps[entry.path] = stamp;
          await _save();
          imported++;
          if (imported >= 100) {
            status =
                '$imported documents indexed · continuing at the next check.';
            return;
          }
        }
      }
      status =
          '$imported new or updated documents indexed · checking every 5 minutes while unlocked.';
    } catch (_) {
      if (_current(identity, generation)) {
        error =
            'Could not import a document folder. Files will be retried at the next check.';
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancelEvents();
    _folders.clear();
    _stamps.clear();
    if (_started) state.removeListener(_stateChanged);
    super.dispose();
  }
}
