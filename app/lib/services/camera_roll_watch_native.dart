import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../api_client.dart';
import '../app_state.dart';
import 'camera_roll_types.dart';
import 'document_credentials.dart';

/// Imports new camera photos while the app is open.
///
/// Android: polls the public DCIM/Camera folder (inotify is unreliable on
/// shared storage). Desktop: polls folders the user picked. There is no
/// background service: photos taken while the app is closed are imported the
/// next time it is opened and unlocked.
///
/// Polling happens on enable, on app resume and every [pollInterval] while the
/// app is in the foreground. Only images modified after the stored stamp are
/// listed; the stamp advances after the encrypted vault save succeeded.
class CameraRollWatchService extends ChangeNotifier
    with WidgetsBindingObserver {
  CameraRollWatchService(
    this.state, {
    DocumentCredentialStore? store,
    CameraFolderLister? lister,
    CameraPhotoImporter? importer,
    CameraPhotoKeeper? keeper,
    CameraRollPlatform? platform,
    DateTime Function()? now,
  }) : _store = store ?? const DocumentCredentialStore(),
       _lister = lister ?? _listFolders,
       _platform = platform ?? const MediaChannelPlatform(),
       _now = now ?? DateTime.now {
    _importer =
        importer ??
        (photo) =>
            state.importPhotoFile(photo.path, capturedAt: photo.modified);
    _keeper = keeper ?? ((photo, id) => state.keepPhotoInVault(photo.path, id));
  }

  static const pollInterval = Duration(minutes: 10);
  static const _settleTime = Duration(seconds: 5);
  static const _maxPerCheck = 25;

  final LifenizerAppState state;
  final DocumentCredentialStore _store;
  final CameraFolderLister _lister;
  final CameraRollPlatform _platform;
  final DateTime Function() _now;
  late final CameraPhotoImporter _importer;
  late final CameraPhotoKeeper _keeper;

  final _folders = <String>[];
  // Files newer than the stamp that were already handled (path -> size:mtime).
  final _done = <String, String>{};
  DateTime? _stamp;
  bool _enabled = false;
  bool _keepInVault = true;
  String? _identity;
  Timer? _timer;
  Future<void>? _running;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;
  bool _restoring = false;
  CameraPermission _permission = CameraPermission.unknown;
  String? status;
  String? error;
  String? vaultNote;
  String? lastFile;
  DateTime? lastCheck;
  int imported = 0;
  int skipped = 0;
  int failed = 0;

  bool get supported => true;
  bool get needsFolderChoice => !_platform.isMobile;
  bool get enabled => _enabled;
  bool get keepInVault => _keepInVault;
  List<String> get folders => List.unmodifiable(_folders);
  CameraPermission get permission => _permission;
  bool get working => _running != null || _restoring;
  bool get _unsupportedPlatform => !kIsWeb && Platform.isIOS;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started || _disposed || _unsupportedPlatform) return;
    _started = true;
    state.addListener(_stateChanged);
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {
      // No binding (pure unit tests): polling still works without lifecycle.
    }
    _stateChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _schedule();
      unawaited(check());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_enabled && _identity != null) {
      _timer = Timer.periodic(pollInterval, (_) => unawaited(check()));
    }
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
    _timer?.cancel();
    _timer = null;
    _folders.clear();
    _done.clear();
    _stamp = null;
    _enabled = false;
    _restoring = false;
    status = null;
    error = null;
    vaultNote = null;
    lastCheck = null;
    imported = skipped = failed = 0;
    _identity = identity;
    _notify();
    if (identity != null) unawaited(_restore(identity, _generation));
  }

  bool _current(String identity, int generation) =>
      !_disposed &&
      _identity == identity &&
      _generation == generation &&
      state.isAuthenticated;

  Future<void> _restore(String identity, int generation) async {
    _restoring = true;
    try {
      final saved = await _store.read(identity, 'camera-roll');
      if (!_current(identity, generation)) return;
      if (saved != null) {
        _enabled = saved['enabled'] == true;
        _keepInVault = saved['keepInVault'] != false;
        _folders.addAll((saved['folders'] as List? ?? []).cast<String>());
        _stamp = DateTime.tryParse('${saved['stamp'] ?? ''}');
        _done.addAll(Map<String, String>.from(saved['done'] as Map? ?? {}));
        imported = saved['imported'] as int? ?? 0;
        skipped = saved['skipped'] as int? ?? 0;
        failed = saved['failed'] as int? ?? 0;
        lastCheck = DateTime.tryParse('${saved['lastCheck'] ?? ''}');
      }
      _schedule();
    } catch (_) {
      if (_current(identity, generation)) {
        error =
            'Could not restore camera photo settings from the OS '
            'credential store.';
      }
    } finally {
      if (_current(identity, generation)) _restoring = false;
      _notify();
    }
    if (_current(identity, generation) && _enabled) await check();
  }

  Future<void> _save() => _store.write(_identity!, 'camera-roll', {
    'enabled': _enabled,
    'keepInVault': _keepInVault,
    'folders': List<String>.from(_folders),
    'stamp': _stamp?.toUtc().toIso8601String(),
    'done': Map<String, String>.from(_done),
    'imported': imported,
    'skipped': skipped,
    'failed': failed,
    'lastCheck': lastCheck?.toUtc().toIso8601String(),
  });

  /// Turns auto-import on or off. When turned on, only photos newer than now
  /// (or, with [includeLastWeek], newer than seven days ago) are imported.
  Future<void> setEnabled(bool value, {bool includeLastWeek = false}) async {
    start();
    if (_identity == null) {
      throw StateError('Unlock the vault before enabling photo import.');
    }
    final identity = _identity!;
    final generation = _generation;
    if (!value) {
      _enabled = false;
      _timer?.cancel();
      _timer = null;
      status = 'Camera photo import is off.';
      await _save();
      _notify();
      return;
    }
    error = null;
    if (_platform.isMobile) {
      final granted =
          await _platform.hasImagesPermission() ||
          await _platform.requestImagesPermission();
      if (!_current(identity, generation)) return;
      _permission = granted
          ? CameraPermission.granted
          : CameraPermission.denied;
      if (!granted) {
        error = 'Allow access to photos to import camera pictures.';
        _notify();
        return;
      }
    } else {
      _permission = CameraPermission.notNeeded;
    }
    final now = _now();
    _stamp = includeLastWeek ? now.subtract(const Duration(days: 7)) : now;
    _done.clear();
    _enabled = true;
    await _save();
    if (!_current(identity, generation)) return;
    _schedule();
    _notify();
    await check();
  }

  Future<void> setKeepInVault(bool value) async {
    _keepInVault = value;
    _notify();
    if (_identity != null) await _save();
  }

  Future<void> addFolder(String path) async {
    start();
    if (_identity == null) {
      throw StateError('Unlock the desktop vault before choosing a folder.');
    }
    final directory = Directory(path).absolute;
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException(
        'Choose an existing folder, rather than a symbolic link.',
      );
    }
    if (_folders.contains(directory.path)) return;
    _folders.add(directory.path);
    await _save();
    _notify();
    if (_enabled) await check();
  }

  Future<void> removeFolder(String path) async {
    if (_identity == null) return;
    _folders.remove(path);
    await _save();
    _notify();
  }

  Future<void> check() {
    if (_running != null) return _running!;
    if (_identity == null || !_enabled || state.busy || _restoring) {
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
    var attempted = 0;
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    try {
      error = null;
      if (_platform.isMobile) {
        if (!await _platform.hasImagesPermission()) {
          _permission = CameraPermission.denied;
          error =
              'Photo access was revoked. Turn auto-import off and on again '
              'to grant it.';
          return;
        }
        _permission = CameraPermission.granted;
      }
      final folders = _platform.isMobile
          ? await _platform.cameraFolders()
          : List<String>.from(_folders);
      if (!_current(identity, generation)) return;
      if (folders.isEmpty) {
        status = _platform.isMobile
            ? 'No camera folder found on this device.'
            : 'Choose the folder your camera photos sync to.';
        return;
      }
      final stamp = _stamp ?? _now();
      final now = _now();
      final candidates = (await _lister(folders)).where((photo) {
        if (photo.name.startsWith('.')) return false; // trashed/pending
        if (!cameraImagePattern.hasMatch(photo.name)) return false;
        if (!photo.modified.isAfter(stamp)) return false;
        if (now.difference(photo.modified) < _settleTime) return false;
        return _done[photo.path] != _stampOf(photo);
      }).toList()..sort((a, b) => a.modified.compareTo(b.modified));
      if (!_current(identity, generation)) return;
      var hadFailure = false;
      var newest = stamp;
      for (final photo in candidates) {
        if (!_current(identity, generation) || state.busy) return;
        if (attempted >= _maxPerCheck) {
          status = 'Importing in batches; continuing at the next check.';
          hadFailure = true; // keep the stamp so the rest is listed again
          break;
        }
        if (photo.size > cameraPhotoMaxBytes) {
          skipped++;
          _done[photo.path] = _stampOf(photo);
          if (photo.modified.isAfter(newest)) newest = photo.modified;
          continue;
        }
        attempted++;
        lastFile = photo.name;
        status = 'Importing photo $attempted of ${candidates.length}…';
        _notify();
        String? conversationId;
        try {
          conversationId = await _importer(photo);
        } catch (exception) {
          conversationId = null;
          error ??= '${photo.name}: $exception';
        }
        if (!_current(identity, generation)) return;
        if (conversationId == null) {
          failed++;
          hadFailure = true;
          error ??=
              '${photo.name}: ${state.error ?? 'Import failed. It will be retried.'}';
          continue;
        }
        imported++;
        _done[photo.path] = _stampOf(photo);
        if (photo.modified.isAfter(newest)) newest = photo.modified;
        if (_keepInVault) {
          try {
            await _keeper(photo, conversationId);
            vaultNote = null;
          } on QuotaExceededException {
            vaultNote =
                'Photo text was imported, but the image was not kept in the '
                'vault: storage quota exceeded.';
          } catch (exception) {
            vaultNote =
                'Photo text was imported, but keeping the image failed: '
                '$exception';
          }
        }
      }
      if (!_current(identity, generation)) return;
      // Advance the stamp only past a contiguous successful prefix.
      if (!hadFailure) {
        if (newest.isAfter(stamp)) _stamp = newest;
        _done.clear();
      }
      status = imported == 0 && skipped == 0 && failed == 0
          ? 'No new photos.'
          : '$imported new photo(s) imported'
                '${skipped > 0 ? ' · $skipped over 25 MiB skipped' : ''}'
                '${failed > 0 ? ' · $failed failed (will retry)' : ''}.';
    } catch (exception) {
      if (_current(identity, generation)) {
        error = 'Could not check for new photos: $exception';
      }
    } finally {
      if (_current(identity, generation)) {
        this.imported += imported;
        this.skipped += skipped;
        this.failed = failed;
        lastCheck = _now();
        try {
          await _save();
        } catch (_) {
          error ??= 'Could not save the camera photo position.';
        }
      }
    }
  }

  static String _stampOf(CameraPhotoFile photo) =>
      '${photo.size}:${photo.modified.microsecondsSinceEpoch}';

  static Future<List<CameraPhotoFile>> _listFolders(
    List<String> folders,
  ) async {
    final files = <CameraPhotoFile>[];
    for (final folder in folders) {
      try {
        if (await FileSystemEntity.type(folder, followLinks: false) !=
            FileSystemEntityType.directory) {
          continue;
        }
        await for (final entry in Directory(folder).list(followLinks: false)) {
          if (entry is! File || !cameraImagePattern.hasMatch(entry.path)) {
            continue;
          }
          final stat = await entry.stat();
          if (stat.size == 0) continue;
          files.add(
            CameraPhotoFile(
              path: entry.path,
              size: stat.size,
              modified: stat.modified,
            ),
          );
        }
      } on FileSystemException {
        continue;
      }
    }
    return files;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    if (_started) {
      state.removeListener(_stateChanged);
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
    }
    super.dispose();
  }
}
