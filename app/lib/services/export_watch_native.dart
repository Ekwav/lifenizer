import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../app_state.dart';

/// Watches only a file selected by the user; vault keys never leave app state.
class ExportWatchService extends ChangeNotifier {
  ExportWatchService({Future<void> Function(String)? importFile})
    : _importFile = importFile;
  static final instance = ExportWatchService();
  final Future<void> Function(String)? _importFile;
  final _storage = const FlutterSecureStorage();
  LifenizerAppState? _state;
  StreamSubscription<FileSystemEvent>? _events;
  Timer? _timer;
  Timer? _debounce;
  String? _key;
  String? _path;
  String? _stamp;
  bool _working = false;
  bool _wasUnlocked = false;

  String? get path => _path;

  Future<void> start(LifenizerAppState state) async {
    if (_state != null || Platform.isAndroid || Platform.isIOS) return;
    _state = state;
    state.addListener(_onState);
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _check());
    _onState();
  }

  void _onState() {
    final state = _state!;
    final unlocked = state.isAuthenticated;
    final resumed = unlocked && !_wasUnlocked;
    _wasUnlocked = unlocked;
    if (!state.isAuthenticated || state.busy || _working) return;
    final key =
        'lifenizer.export-watch.${base64UrlEncode(utf8.encode('${state.apiBaseUrl}\n${state.rememberedEmail}'))}';
    if (_key != key) {
      unawaited(_restore(key));
    } else if (resumed) {
      unawaited(_check());
    }
  }

  Future<void> checkForChanges() => _check();

  @override
  void dispose() {
    _state?.removeListener(_onState);
    _events?.cancel();
    _timer?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _restore(String key) async {
    _working = true;
    try {
      await _events?.cancel();
      _key = key;
      _path = null;
      _stamp = null;
      final raw = await _storage.read(key: key);
      if (raw != null) {
        final saved = jsonDecode(raw) as Map;
        _path = saved['path'] as String;
        _stamp = saved['stamp'] as String?;
        _listen();
      }
      notifyListeners();
    } catch (_) {
      _state!.reportError(
        'Could not restore the watched export from secure storage.',
      );
    } finally {
      _working = false;
    }
    await _check();
  }

  Future<void> watch(String path) async {
    final state = _state;
    if (state == null || !state.isAuthenticated || _working) {
      throw StateError('Unlock the desktop vault before watching an export.');
    }
    if (!path.toLowerCase().endsWith('.zip')) {
      throw const FormatException('Choose a Discord ZIP export to watch.');
    }
    final file = File(path).absolute;
    if (!await file.exists()) {
      throw const FormatException('The export file does not exist.');
    }
    await _events?.cancel();
    _path = file.path;
    _stamp = null;
    await _save();
    _listen();
    notifyListeners();
    await _check();
  }

  Future<void> stopWatching() async {
    _debounce?.cancel();
    await _events?.cancel();
    _events = null;
    _path = null;
    _stamp = null;
    if (_key != null) await _storage.delete(key: _key!);
    notifyListeners();
  }

  void _listen() {
    final path = _path;
    if (path == null) return;
    _events = File(path).parent.watch().listen(
      (event) {
        if (event.path != path &&
            !(event is FileSystemMoveEvent && event.destination == path)) {
          return;
        }
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 5), _check);
      },
      onError: (Object _) {
        // The periodic stat also handles replaced directories and missed events.
      },
    );
  }

  Future<void> _save() async {
    if (_key == null || _path == null) return;
    await _storage.write(
      key: _key!,
      value: jsonEncode({'path': _path, 'stamp': _stamp}),
    );
  }

  Future<void> _check() async {
    final state = _state;
    final path = _path;
    if (_working ||
        state == null ||
        path == null ||
        !state.isAuthenticated ||
        state.busy) {
      return;
    }
    _working = true;
    try {
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file) return;
      final stamp = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
      if (stamp == _stamp) return;
      await (_importFile ?? state.importDiscordArchive)(path);
      if (state.error == null && _path == path) {
        _stamp = stamp;
        await _save();
      }
    } catch (_) {
      state.reportError(
        'Could not read the watched Discord export. Choose it again in Imports.',
      );
    } finally {
      _working = false;
    }
  }
}
