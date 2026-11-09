import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'browser_history_types.dart';

const _videoHosts =
    "(u.url LIKE '%youtube.com/%' OR u.url LIKE '%youtu.be/%' "
    "OR u.url LIKE '%tiktok.com/%')";

/// Reads YouTube/TikTok visits newer than [after] from a Firefox
/// (`places.sqlite`) or Chromium (`History`) database.
///
/// Browsers keep their database locked, so the file (and its `-wal`) is copied
/// to a temporary directory, queried and deleted again. The browser database
/// is never opened or modified. Only rows of YouTube/TikTok URLs are selected.
Future<List<BrowserVisit>> readBrowserVisits(
  BrowserProfile profile,
  DateTime after,
) async {
  final source = File(profile.path);
  if (!await source.exists()) {
    throw FileSystemException('History file not found', profile.path);
  }
  final temp = await Directory.systemTemp.createTemp('lifenizer-history-');
  try {
    final copy = '${temp.path}${Platform.pathSeparator}history.sqlite';
    await source.copy(copy);
    final wal = File('${profile.path}-wal');
    if (await wal.exists()) {
      try {
        await wal.copy('$copy-wal');
      } on FileSystemException {
        // The WAL may be checkpointed away between exists() and copy().
      }
    }
    final db = sqlite3.open(copy);
    try {
      db.execute('PRAGMA query_only = ON');
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'] as String)
          .toSet();
      if (tables.contains('moz_places') &&
          tables.contains('moz_historyvisits')) {
        final rows = db.select(
          'SELECT p.url AS url, p.title AS title, v.visit_date AS t '
          'FROM moz_historyvisits v JOIN moz_places p ON p.id = v.place_id '
          'WHERE v.visit_date > ? AND ${_videoHosts.replaceAll('u.', 'p.')} '
          'ORDER BY v.visit_date',
          [firefoxVisitMicros(after)],
        );
        return [
          for (final row in rows)
            if (row['url'] is String && row['t'] is int)
              BrowserVisit(
                url: row['url'] as String,
                title: (row['title'] as String?) ?? '',
                time: firefoxVisitTime(row['t'] as int),
              ),
        ];
      }
      if (tables.contains('urls') && tables.contains('visits')) {
        final rows = db.select(
          'SELECT u.url AS url, u.title AS title, v.visit_time AS t '
          'FROM visits v JOIN urls u ON u.id = v.url '
          'WHERE v.visit_time > ? AND $_videoHosts ORDER BY v.visit_time',
          [chromiumVisitMicros(after)],
        );
        return [
          for (final row in rows)
            if (row['url'] is String && row['t'] is int)
              BrowserVisit(
                url: row['url'] as String,
                title: (row['title'] as String?) ?? '',
                time: chromiumVisitTime(row['t'] as int),
              ),
        ];
      }
      throw const FormatException(
        'This file is not a Firefox or Chromium history database.',
      );
    } finally {
      db.close();
    }
  } finally {
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // Best effort; the OS cleans the temp directory eventually.
    }
  }
}

/// Finds browser history databases below [home]. [os] is `linux`, `macos` or
/// `windows`; [appData] / [localAppData] are the Windows folders.
Future<List<BrowserProfile>> discoverBrowserProfiles({
  required String home,
  required String os,
  String? appData,
  String? localAppData,
}) async {
  final sep = Platform.pathSeparator;
  String join(List<String> parts) => parts.join(sep);
  final found = <BrowserProfile>[];
  final seen = <String>{};

  Future<void> scan(
    String label,
    String base,
    String file, {
    required bool firefox,
  }) async {
    final dir = Directory(base);
    try {
      if (!await dir.exists()) return;
      final children = await dir.list(followLinks: false).toList();
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        if (child is! Directory) continue;
        final name = child.path.split(RegExp(r'[\\/]')).last;
        if (!firefox && name != 'Default' && !name.startsWith('Profile ')) {
          continue;
        }
        final path = '${child.path}$sep$file';
        if (await File(path).exists() && seen.add(path)) {
          found.add(BrowserProfile(path: path, label: '$label · $name'));
        }
      }
    } on FileSystemException {
      return;
    }
  }

  Future<void> chromium(String label, String base) =>
      scan(label, base, 'History', firefox: false);
  Future<void> firefox(String label, String base) =>
      scan(label, base, 'places.sqlite', firefox: true);

  switch (os) {
    case 'linux':
      await firefox('Firefox', join([home, '.mozilla', 'firefox']));
      await firefox('Firefox', join([home, '.config', 'mozilla', 'firefox']));
      await firefox(
        'Firefox (Snap)',
        join([home, 'snap', 'firefox', 'common', '.mozilla', 'firefox']),
      );
      await firefox(
        'Firefox (Flatpak)',
        join([
          home,
          '.var',
          'app',
          'org.mozilla.firefox',
          '.mozilla',
          'firefox',
        ]),
      );
      const configs = {
        'Chrome': ['google-chrome'],
        'Chromium': ['chromium'],
        'Brave': ['BraveSoftware', 'Brave-Browser'],
        'Edge': ['microsoft-edge'],
        'Vivaldi': ['vivaldi'],
      };
      for (final entry in configs.entries) {
        await chromium(entry.key, join([home, '.config', ...entry.value]));
      }
      const flatpaks = {
        'Chrome (Flatpak)': ['com.google.Chrome', 'config', 'google-chrome'],
        'Chromium (Flatpak)': ['org.chromium.Chromium', 'config', 'chromium'],
        'Brave (Flatpak)': [
          'com.brave.Browser',
          'config',
          'BraveSoftware',
          'Brave-Browser',
        ],
        'Edge (Flatpak)': ['com.microsoft.Edge', 'config', 'microsoft-edge'],
      };
      for (final entry in flatpaks.entries) {
        await chromium(entry.key, join([home, '.var', 'app', ...entry.value]));
      }
      await chromium(
        'Chromium (Snap)',
        join([home, 'snap', 'chromium', 'common', 'chromium']),
      );
    case 'macos':
      final support = join([home, 'Library', 'Application Support']);
      await firefox('Firefox', join([support, 'Firefox', 'Profiles']));
      const apps = {
        'Chrome': ['Google', 'Chrome'],
        'Chromium': ['Chromium'],
        'Brave': ['BraveSoftware', 'Brave-Browser'],
        'Edge': ['Microsoft Edge'],
        'Vivaldi': ['Vivaldi'],
      };
      for (final entry in apps.entries) {
        await chromium(entry.key, join([support, ...entry.value]));
      }
    case 'windows':
      final roaming = appData ?? join([home, 'AppData', 'Roaming']);
      final local = localAppData ?? join([home, 'AppData', 'Local']);
      await firefox(
        'Firefox',
        join([roaming, 'Mozilla', 'Firefox', 'Profiles']),
      );
      const apps = {
        'Chrome': ['Google', 'Chrome', 'User Data'],
        'Chromium': ['Chromium', 'User Data'],
        'Brave': ['BraveSoftware', 'Brave-Browser', 'User Data'],
        'Edge': ['Microsoft', 'Edge', 'User Data'],
        'Vivaldi': ['Vivaldi', 'User Data'],
      };
      for (final entry in apps.entries) {
        await chromium(entry.key, join([local, ...entry.value]));
      }
  }
  return found;
}
