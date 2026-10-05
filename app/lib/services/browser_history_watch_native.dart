import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../app_state.dart';
import 'browser_history_reader.dart';
import 'browser_history_types.dart';
import 'document_credentials.dart';
import 'transcript_enrichment.dart';

/// Keeps the YouTube/TikTok viewing history current from the local browser
/// history database (desktop only).
///
/// Neither YouTube (since 2016) nor TikTok exposes watch history through an
/// API, so after an initial Takeout/TikTok export the visits are read from the
/// history database of the browsers the user selected. Only YouTube/TikTok
/// video URLs and titles are used; nothing else is read or uploaded. Polling
/// happens on enable, on app resume and every [interval] while the app is in
/// the foreground. The stamp of a profile advances only after all its batches
/// were imported (the import merges by video id and watch second, so a retry
/// never duplicates a watch).
class BrowserHistoryWatchService extends ChangeNotifier
    with WidgetsBindingObserver {
  BrowserHistoryWatchService(
    this.state, {
    DocumentCredentialStore? store,
    BrowserProfileDiscoverer? discoverer,
    BrowserVisitReader? reader,
    ViewingBatchImporter? importer,
    TranscriptAutoFetcher? fetcher,
    DateTime Function()? now,
    bool? supportedOverride,
  }) : _store = store ?? const DocumentCredentialStore(),
       _discoverer = discoverer ?? _discover,
       _reader = reader ?? readBrowserVisits,
       _now = now ?? DateTime.now,
       _supported = supportedOverride ?? _desktop {
    _importer = importer ?? _importBatch;
    _fetcher = fetcher ?? _fetchTranscripts;
  }

  static const _blockedPause = Duration(hours: 6);
  static bool get _desktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  final LifenizerAppState state;
  final DocumentCredentialStore _store;
  final BrowserProfileDiscoverer _discoverer;
  final BrowserVisitReader _reader;
  final DateTime Function() _now;
  final bool _supported;
  late final ViewingBatchImporter _importer;
  late final TranscriptAutoFetcher _fetcher;

  final _detected = <BrowserProfile>[];
  final _manual = <String>[];
  // Selected profile path -> only visits after this time are imported.
  final _stamps = <String, DateTime>{};
  bool _enabled = false;
  Duration _interval = defaultBrowserPollInterval;
  bool _autoTranscripts = false;
  int _perDay = defaultAutoTranscriptsPerDay;
  String _day = '';
  int _dayCount = 0;
  DateTime? _blockedUntil;
  String? _identity;
  Timer? _timer;
  Future<void>? _running;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;
  bool _restoring = false;
  String? status;
  String? error;
  DateTime? lastCheck;
  int visitsFound = 0;
  int videosImported = 0;

  bool get supported => _supported;
  bool get enabled => _enabled;
  bool get working => _running != null || _restoring;
  Duration get interval => _interval;
  bool get autoTranscripts => _autoTranscripts;
  int get transcriptsPerDay => _perDay;
  int get transcriptsToday =>
      _dayCount == 0 || _day != _today() ? 0 : _dayCount;
  Set<String> get selected => Set.unmodifiable(_stamps.keys);
  List<BrowserProfile> get profiles => [
    ..._detected,
    for (final path in _manual)
      if (!_detected.any((p) => p.path == path))
        BrowserProfile(
          path: path,
          label: 'Chosen file · ${path.split(RegExp(r'[\\/]')).last}',
        ),
  ];

  String _today() {
    final n = _now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${p(n.month)}-${p(n.day)}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started || _disposed || !_supported) return;
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
      _timer = Timer.periodic(_interval, (_) => unawaited(check()));
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
    _manual.clear();
    _stamps.clear();
    _enabled = false;
    _restoring = false;
    _interval = defaultBrowserPollInterval;
    _autoTranscripts = false;
    _perDay = defaultAutoTranscriptsPerDay;
    _day = '';
    _dayCount = 0;
    _blockedUntil = null;
    status = null;
    error = null;
    lastCheck = null;
    visitsFound = videosImported = 0;
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
      final saved = await _store.read(identity, 'browser-history');
      if (!_current(identity, generation)) return;
      if (saved != null) {
        _enabled = saved['enabled'] == true;
        final minutes = saved['intervalMinutes'] as int?;
        if (minutes != null) {
          _interval = _clampInterval(Duration(minutes: minutes));
        }
        _autoTranscripts = saved['autoTranscripts'] == true;
        _perDay = saved['perDay'] as int? ?? defaultAutoTranscriptsPerDay;
        _day = saved['day'] as String? ?? '';
        _dayCount = saved['dayCount'] as int? ?? 0;
        _blockedUntil = DateTime.tryParse('${saved['blockedUntil'] ?? ''}');
        _manual.addAll((saved['manual'] as List? ?? []).cast<String>());
        for (final e in Map<String, dynamic>.from(
          saved['stamps'] as Map? ?? {},
        ).entries) {
          final stamp = DateTime.tryParse('${e.value}');
          if (stamp != null) _stamps[e.key] = stamp;
        }
        visitsFound = saved['visitsFound'] as int? ?? 0;
        videosImported = saved['videosImported'] as int? ?? 0;
        lastCheck = DateTime.tryParse('${saved['lastCheck'] ?? ''}');
      }
      _schedule();
    } catch (_) {
      if (_current(identity, generation)) {
        error =
            'Could not restore browser history settings from the OS '
            'credential store.';
      }
    } finally {
      if (_current(identity, generation)) _restoring = false;
      _notify();
    }
    if (_current(identity, generation)) {
      await refreshProfiles();
      if (_enabled) await check();
    }
  }

  static Duration _clampInterval(Duration value) =>
      value < minBrowserPollInterval
      ? minBrowserPollInterval
      : value > maxBrowserPollInterval
      ? maxBrowserPollInterval
      : value;

  Future<void> _save() => _store.write(_identity!, 'browser-history', {
    'enabled': _enabled,
    'intervalMinutes': _interval.inMinutes,
    'autoTranscripts': _autoTranscripts,
    'perDay': _perDay,
    'day': _day,
    'dayCount': _dayCount,
    'blockedUntil': _blockedUntil?.toUtc().toIso8601String(),
    'manual': List<String>.from(_manual),
    'stamps': {
      for (final e in _stamps.entries) e.key: e.value.toUtc().toIso8601String(),
    },
    'visitsFound': visitsFound,
    'videosImported': videosImported,
    'lastCheck': lastCheck?.toUtc().toIso8601String(),
  });

  Future<void> _trySave() async {
    if (_identity == null) return;
    try {
      await _save();
    } catch (_) {
      error ??= 'Could not save the browser history position.';
    }
  }

  Future<void> refreshProfiles() async {
    try {
      final found = await _discoverer();
      _detected
        ..clear()
        ..addAll(found);
    } catch (exception) {
      error = 'Could not look for browser profiles: $exception';
    }
    _notify();
  }

  /// Selects or deselects a profile. A newly selected profile imports visits
  /// from now on, or from [backfillDays] days ago.
  Future<void> setProfileSelected(
    String path,
    bool value, {
    int backfillDays = 0,
  }) async {
    if (value) {
      _stamps.putIfAbsent(
        path,
        () => _now().subtract(Duration(days: backfillDays)),
      );
    } else {
      _stamps.remove(path);
    }
    _notify();
    await _trySave();
    if (value && _enabled && _identity != null) await check();
  }

  /// Adds a history file picked by hand (Firefox `places.sqlite` or Chromium
  /// `History`) and selects it.
  Future<void> addProfileFile(String path, {int backfillDays = 0}) async {
    start();
    if (_identity == null) {
      throw StateError('Unlock the desktop vault before choosing a file.');
    }
    if (await FileSystemEntity.type(path) != FileSystemEntityType.file) {
      throw const FormatException('Choose an existing history database file.');
    }
    final absolute = File(path).absolute.path;
    if (!_manual.contains(absolute) &&
        !_detected.any((p) => p.path == absolute)) {
      _manual.add(absolute);
    }
    await setProfileSelected(absolute, true, backfillDays: backfillDays);
  }

  Future<void> setEnabled(bool value) async {
    start();
    if (_identity == null) {
      throw StateError('Unlock the vault before enabling browser history.');
    }
    _enabled = value;
    error = null;
    if (!value) {
      _timer?.cancel();
      _timer = null;
      status = 'Browser history updates are off.';
      await _trySave();
      _notify();
      return;
    }
    await _trySave();
    _schedule();
    _notify();
    await check();
  }

  Future<void> setInterval(Duration value) async {
    _interval = _clampInterval(value);
    _schedule();
    _notify();
    await _trySave();
  }

  Future<void> setAutoTranscripts(bool value) async {
    _autoTranscripts = value;
    _notify();
    await _trySave();
  }

  Future<void> setTranscriptsPerDay(int value) async {
    _perDay = value < 1 ? 1 : value;
    _notify();
    await _trySave();
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
    var found = 0;
    var imported = 0;
    final errors = <String>[];
    try {
      error = null;
      final all = profiles;
      if (_stamps.isEmpty) {
        status = 'Select at least one browser profile.';
        return;
      }
      for (final entry in _stamps.entries.toList()) {
        if (!_current(identity, generation)) return;
        final profile = all.firstWhere(
          (p) => p.path == entry.key,
          orElse: () => BrowserProfile(path: entry.key, label: entry.key),
        );
        status = 'Reading ${profile.label}…';
        _notify();
        try {
          final visits = await _reader(profile, entry.value);
          final videos = <VideoVisit>[
            for (final visit in visits)
              if (visit.time.isAfter(entry.value)) ?classifyVisit(visit),
          ];
          found += videos.length;
          var ok = true;
          for (final batch in buildViewingBatches(videos)) {
            if (!_current(identity, generation)) return;
            if (state.busy) {
              ok = false;
              errors.add('${profile.label}: the vault was busy; will retry.');
              break;
            }
            final added = await _importer(batch);
            if (added == null) {
              ok = false;
              errors.add(
                '${profile.label}: ${state.error ?? 'Import failed. It will be retried.'}',
              );
              break;
            }
            imported += added;
          }
          if (!_current(identity, generation)) return;
          if (ok) {
            if (videos.isNotEmpty) {
              _stamps[entry.key] = videos
                  .map((v) => v.time)
                  .reduce((a, b) => a.isAfter(b) ? a : b);
            }
          }
        } catch (exception) {
          errors.add('${profile.label}: $exception');
        }
      }
      if (!_current(identity, generation)) return;
      visitsFound += found;
      videosImported += imported;
      status = found == 0
          ? 'No new YouTube or TikTok visits.'
          : '$found visit(s) found · $imported video(s) imported or updated.';
      if (errors.isNotEmpty) error = errors.join('\n');
      if (imported > 0 && _autoTranscripts) await _autoFetch(imported);
    } catch (exception) {
      if (_current(identity, generation)) {
        error = 'Could not check browser history: $exception';
      }
    } finally {
      if (_current(identity, generation)) {
        lastCheck = _now();
        await _trySave();
      }
    }
  }

  Future<void> _autoFetch(int newVideos) async {
    final today = _today();
    if (_day != today) {
      _day = today;
      _dayCount = 0;
    }
    if (_blockedUntil != null && _now().isBefore(_blockedUntil!)) return;
    final remaining = _perDay - _dayCount;
    if (remaining <= 0) {
      status = '$status Daily transcript limit ($_perDay) reached.';
      return;
    }
    final limit = newVideos < remaining ? newVideos : remaining;
    final progress = await _fetcher(limit);
    _dayCount += progress.done;
    if (progress.stopReason != null) {
      _blockedUntil = _now().add(_blockedPause);
      status = '$status ${progress.stopReason}';
    } else if (progress.done > 0) {
      status = '$status ${progress.summary}.';
    }
  }

  Future<int?> _importBatch(ViewingImportBatch batch) async {
    state.lastImportSummary = null;
    await state.importSource(
      source: batch.source,
      title: 'Browser viewing history',
      text: batch.json,
      originalFileName: 'browser-history.json',
      mimeType: 'application/json',
    );
    final summary = state.lastImportSummary;
    if (summary == null || state.error != null) return null;
    return summary.added;
  }

  Future<TranscriptBatchProgress> _fetchTranscripts(int limit) {
    final cancel = TranscriptBatchCancel();
    return state.enrichRecentWatchedVideos(limit: limit, cancel: cancel);
  }

  static Future<List<BrowserProfile>> _discover() async {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home == null) return const [];
    return discoverBrowserProfiles(
      home: home,
      os: Platform.isMacOS
          ? 'macos'
          : Platform.isWindows
          ? 'windows'
          : 'linux',
      appData: env['APPDATA'],
      localAppData: env['LOCALAPPDATA'],
    );
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
