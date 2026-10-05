import 'dart:convert';
import 'dart:io';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/browser_history_reader.dart';
import 'package:app/services/browser_history_watch_service.dart';
import 'package:app/services/document_credentials.dart';
import 'package:app/services/transcript_enrichment.dart';
import 'package:app/widgets/viewing_history_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

class _Vault extends LifenizerAppState {
  @override
  bool get isAuthenticated => true;
}

class _Store extends DocumentCredentialStore {
  final saved = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String identity, String source) async =>
      saved['$identity/$source'];
  @override
  Future<void> write(
    String identity,
    String source,
    Map<String, dynamic> value,
  ) async => saved['$identity/$source'] = jsonDecode(jsonEncode(value));
}

BrowserVisit _visit(String url, DateTime time, [String title = '']) =>
    BrowserVisit(url: url, title: title, time: time);

const _id = 'dQw4w9WgXcQ';
final _t0 = DateTime.utc(2026, 10, 1, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('URL classification', () {
    test('YouTube watch, youtu.be, m., music and shorts normalise', () {
      for (final url in [
        'https://www.youtube.com/watch?v=$_id',
        'https://youtube.com/watch?feature=share&v=$_id&t=30s',
        'https://m.youtube.com/watch?v=$_id',
        'https://music.youtube.com/watch?v=$_id&list=x',
        'https://youtu.be/$_id?si=abc',
        'https://www.youtube.com/shorts/$_id',
      ]) {
        final video = classifyVisit(_visit(url, _t0));
        expect(video, isNotNull, reason: url);
        expect(video!.platform, 'youtube');
        expect(video.id, _id);
        expect(video.url, 'https://www.youtube.com/watch?v=$_id');
      }
    });

    test('non-video pages and short links are ignored', () {
      for (final url in [
        'https://www.youtube.com/',
        'https://www.youtube.com/results?search_query=cats',
        'https://www.youtube.com/@channel',
        'https://www.youtube.com/playlist?list=PL123',
        'https://music.youtube.com/shorts/$_id',
        'https://www.youtube.com/watch?v=short',
        'https://example.com/watch?v=$_id',
        'https://evil.com/youtube.com/watch?v=$_id',
        'https://vm.tiktok.com/ZMabc123/',
        'https://www.tiktok.com/@user',
        'https://www.tiktok.com/@user/video/abc',
        'ftp://youtube.com/watch?v=$_id',
        'about:blank',
      ]) {
        expect(classifyVisit(_visit(url, _t0)), isNull, reason: url);
      }
    });

    test('TikTok video URLs are canonicalised', () {
      final video = classifyVisit(
        _visit(
          'https://tiktok.com/@some.user/video/7234567890123456789?lang=en',
          _t0,
        ),
      )!;
      expect(video.platform, 'tiktok');
      expect(video.id, '7234567890123456789');
      expect(
        video.url,
        'https://www.tiktok.com/@some.user/video/7234567890123456789',
      );
    });

    test('titles lose the YouTube suffix and notification badge', () {
      expect(
        classifyVisit(
          _visit(
            'https://www.youtube.com/watch?v=$_id',
            _t0,
            '(3) Cats - YouTube',
          ),
        )!.title,
        'Cats',
      );
      expect(
        classifyVisit(
          _visit(
            'https://music.youtube.com/watch?v=$_id',
            _t0,
            'Song - YouTube Music',
          ),
        )!.title,
        'Song',
      );
      expect(
        classifyVisit(
          _visit('https://www.youtube.com/watch?v=$_id', _t0, 'YouTube'),
        )!.title,
        '',
      );
    });
  });

  group('time conversion', () {
    test('Firefox microseconds since the Unix epoch', () {
      final micros = _t0.microsecondsSinceEpoch;
      expect(firefoxVisitTime(micros), _t0);
      expect(firefoxVisitMicros(_t0), micros);
    });

    test('Chromium microseconds since 1601-01-01', () {
      // 2026-10-01T12:00:00Z
      final micros = _t0.microsecondsSinceEpoch + 11644473600000000;
      expect(chromiumVisitTime(micros), _t0);
      expect(chromiumVisitMicros(_t0), micros);
      expect(chromiumVisitTime(0), DateTime.utc(1601));
    });
  });

  group('synthetic payloads', () {
    test('YouTube entries have the exact Takeout shape', () {
      final batches = buildViewingBatches([
        classifyVisit(
          _visit(
            'https://youtu.be/$_id',
            DateTime.utc(2026, 10, 1, 12, 0, 5, 700),
            'Cats - YouTube',
          ),
        )!,
      ]);
      expect(batches, hasLength(1));
      expect(batches.single.source, 'youtube-watch-history');
      expect(jsonDecode(batches.single.json), [
        {
          'header': 'YouTube',
          'title': 'Cats',
          'titleUrl': 'https://www.youtube.com/watch?v=$_id',
          'time': '2026-10-01T12:00:05Z',
        },
      ]);
    });

    test('TikTok entries have the exact export shape', () {
      final batches = buildViewingBatches([
        classifyVisit(
          _visit(
            'https://www.tiktok.com/@u/video/7234567890123456789',
            DateTime.utc(2026, 1, 2, 3, 4, 5),
          ),
        )!,
      ]);
      expect(batches.single.source, 'tiktok-watch-history');
      expect(jsonDecode(batches.single.json), {
        'Activity': {
          'Video Browsing History': {
            'VideoList': [
              {
                'Date': '2026-01-02 03:04:05',
                'Link': 'https://www.tiktok.com/@u/video/7234567890123456789',
              },
            ],
          },
        },
      });
    });

    test('batches hold at most 500 entries and repeated seconds collapse', () {
      final visits = [
        for (var i = 0; i < 1203; i++)
          VideoVisit(
            platform: 'youtube',
            id: 'a${i.toString().padLeft(10, '0')}',
            url: 'u',
            title: 't',
            time: _t0.add(Duration(seconds: i)),
          ),
        // Same video at the same second (a reload): sent once.
        VideoVisit(
          platform: 'youtube',
          id: 'a0000000000',
          url: 'u',
          title: 't',
          time: _t0.add(const Duration(milliseconds: 300)),
        ),
      ];
      final batches = buildViewingBatches(visits);
      expect(batches.map((b) => b.entries), [500, 500, 203]);
      expect(batches.every((b) => b.source == 'youtube-watch-history'), isTrue);
      final first = jsonDecode(batches.first.json) as List;
      expect(first.first['time'], '2026-10-01T12:00:00Z');
    });
  });

  group('reading databases', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('lifenizer-bh-test'));
    tearDown(() => dir.deleteSync(recursive: true));

    String firefoxDb() {
      final path = '${dir.path}/places.sqlite';
      final db = sqlite3.open(path);
      db.execute(
        'CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT)',
      );
      db.execute(
        'CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER)',
      );
      db.execute(
        "INSERT INTO moz_places VALUES (1, 'https://www.youtube.com/watch?v=$_id', 'Cats - YouTube')",
      );
      db.execute(
        "INSERT INTO moz_places VALUES (2, 'https://example.com/', 'Example')",
      );
      db.execute(
        "INSERT INTO moz_places VALUES (3, 'https://www.tiktok.com/@u/video/7234567890123456789', NULL)",
      );
      final old = _t0.subtract(const Duration(days: 1)).microsecondsSinceEpoch;
      db.execute(
        'INSERT INTO moz_historyvisits (place_id, visit_date) VALUES (1, $old)',
      );
      db.execute(
        'INSERT INTO moz_historyvisits (place_id, visit_date) VALUES (1, ${_t0.microsecondsSinceEpoch})',
      );
      db.execute(
        'INSERT INTO moz_historyvisits (place_id, visit_date) VALUES (2, ${_t0.microsecondsSinceEpoch})',
      );
      db.execute(
        'INSERT INTO moz_historyvisits (place_id, visit_date) VALUES (3, ${_t0.microsecondsSinceEpoch + 1000000})',
      );
      db.close();
      return path;
    }

    String chromiumDb() {
      final path = '${dir.path}/History';
      final db = sqlite3.open(path);
      db.execute(
        'CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT)',
      );
      db.execute(
        'CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER)',
      );
      db.execute(
        "INSERT INTO urls VALUES (1, 'https://youtu.be/$_id', 'Cats - YouTube')",
      );
      db.execute(
        "INSERT INTO urls VALUES (2, 'https://news.example/', 'News')",
      );
      int w(DateTime t) => t.microsecondsSinceEpoch + 11644473600000000;
      db.execute(
        'INSERT INTO visits (url, visit_time) VALUES (1, ${w(_t0.subtract(const Duration(days: 1)))})',
      );
      db.execute('INSERT INTO visits (url, visit_time) VALUES (1, ${w(_t0)})');
      db.execute('INSERT INTO visits (url, visit_time) VALUES (2, ${w(_t0)})');
      db.close();
      return path;
    }

    test(
      'Firefox places.sqlite: only newer video visits, correct times',
      () async {
        final path = firefoxDb();
        final visits = await readBrowserVisits(
          BrowserProfile(path: path, label: 'ff'),
          _t0.subtract(const Duration(hours: 1)),
        );
        expect(visits.map((v) => v.url), [
          'https://www.youtube.com/watch?v=$_id',
          'https://www.tiktok.com/@u/video/7234567890123456789',
        ]);
        expect(visits.first.time, _t0);
        expect(visits.first.title, 'Cats - YouTube');
        expect(visits.last.title, '');
      },
    );

    test(
      'Chromium History: Windows-epoch times, non-video rows skipped',
      () async {
        final path = chromiumDb();
        final visits = await readBrowserVisits(
          BrowserProfile(path: path, label: 'c'),
          _t0.subtract(const Duration(hours: 1)),
        );
        expect(visits, hasLength(1));
        expect(visits.single.time, _t0);
      },
    );

    test('the original is untouched and no temp copy is left behind', () async {
      final path = firefoxDb();
      final before = File(path).lengthSync();
      int temps() => Directory.systemTemp
          .listSync()
          .where((e) => e.path.contains('lifenizer-history-'))
          .length;
      final tempsBefore = temps();
      await readBrowserVisits(
        BrowserProfile(path: path, label: 'ff'),
        DateTime.utc(2000),
      );
      expect(File(path).lengthSync(), before);
      expect(temps(), tempsBefore);
    });

    test('unrelated sqlite files are rejected', () async {
      final path = '${dir.path}/other.sqlite';
      sqlite3.open(path)
        ..execute('CREATE TABLE t (a)')
        ..close();
      expect(
        readBrowserVisits(
          BrowserProfile(path: path, label: 'x'),
          DateTime.utc(2000),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('profile discovery finds Firefox and Chromium-family profiles', () async {
      Directory(
        '${dir.path}/.mozilla/firefox/abc.default',
      ).createSync(recursive: true);
      File(
        '${dir.path}/.mozilla/firefox/abc.default/places.sqlite',
      ).writeAsStringSync('');
      Directory(
        '${dir.path}/.config/google-chrome/Default',
      ).createSync(recursive: true);
      File(
        '${dir.path}/.config/google-chrome/Default/History',
      ).writeAsStringSync('');
      Directory(
        '${dir.path}/.config/google-chrome/Profile 2',
      ).createSync(recursive: true);
      File(
        '${dir.path}/.config/google-chrome/Profile 2/History',
      ).writeAsStringSync('');
      Directory(
        '${dir.path}/.config/google-chrome/Crashpad',
      ).createSync(recursive: true);
      Directory(
        '${dir.path}/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser/Default',
      ).createSync(recursive: true);
      File(
        '${dir.path}/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser/Default/History',
      ).writeAsStringSync('');
      final found = await discoverBrowserProfiles(home: dir.path, os: 'linux');
      expect(found.map((p) => p.label), [
        'Firefox · abc.default',
        'Chrome · Default',
        'Chrome · Profile 2',
        'Brave (Flatpak) · Default',
      ]);
    });
  });

  group('service', () {
    late _Vault state;
    late _Store store;
    late DateTime now;
    late Map<String, List<BrowserVisit>> history;
    late List<ViewingImportBatch> sent;
    late List<int> fetchLimits;
    late BrowserHistoryWatchService service;
    int? Function(ViewingImportBatch) importResult = (b) => b.entries;
    var fetchDone = 1;
    String? fetchStop;

    const profile = BrowserProfile(
      path: '/p/places.sqlite',
      label: 'Firefox · x',
    );

    Future<void> create() async {
      state = _Vault()
        ..session = AuthSession(
          authToken: 't',
          userId: 'u',
          vaultId: 'v',
          vaultSalt: 's',
        );
      addTearDown(state.dispose);
      store = _Store();
      service = BrowserHistoryWatchService(
        state,
        store: store,
        supportedOverride: true,
        now: () => now,
        discoverer: () async => [profile],
        reader: (p, after) async => [
          for (final v in history[p.path] ?? const <BrowserVisit>[])
            if (v.time.isAfter(after)) v,
        ],
        importer: (batch) async {
          final result = importResult(batch);
          if (result != null) sent.add(batch);
          return result;
        },
        fetcher: (limit) async {
          fetchLimits.add(limit);
          return TranscriptBatchProgress(
            total: limit,
            done: fetchDone,
            enriched: fetchDone,
            unavailable: 0,
            failed: 0,
            stopReason: fetchStop,
            finished: true,
          );
        },
      );
      addTearDown(service.dispose);
      service.start();
      while (service.working) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    setUp(() {
      now = _t0;
      history = {};
      sent = [];
      fetchLimits = [];
      importResult = (b) => b.entries;
      fetchDone = 1;
      fetchStop = null;
    });

    BrowserVisit yt(String id, Duration after) => _visit(
      'https://www.youtube.com/watch?v=$id',
      _t0.add(after),
      'T $id - YouTube',
    );

    test('old visits are skipped and new ones imported exactly once', () async {
      await create();
      history[profile.path] = [yt('aaaaaaaaaaa', const Duration(days: -2))];
      await service.setProfileSelected(profile.path, true);
      await service.setEnabled(true);
      expect(sent, isEmpty);

      history[profile.path]!.add(yt('bbbbbbbbbbb', const Duration(minutes: 5)));
      now = _t0.add(const Duration(minutes: 10));
      await service.check();
      expect(sent, hasLength(1));
      expect(sent.single.source, 'youtube-watch-history');
      expect(service.visitsFound, 1);
      expect(service.videosImported, 1);

      await service.check();
      await service.check();
      expect(sent, hasLength(1), reason: 'stamp advanced; no double import');
      expect(service.error, isNull);
      expect(service.lastCheck, now);
    });

    test('the stamp does not advance when the import fails', () async {
      await create();
      await service.setProfileSelected(profile.path, true);
      await service.setEnabled(true);
      history[profile.path] = [yt('bbbbbbbbbbb', const Duration(minutes: 5))];
      importResult = (_) => null;
      await service.check();
      expect(sent, isEmpty);
      expect(service.error, isNotNull);

      importResult = (b) => b.entries;
      await service.check();
      expect(sent, hasLength(1), reason: 'retried after the failure');
      expect(service.error, isNull);
      await service.check();
      expect(sent, hasLength(1));
    });

    test('large histories go out in batches of at most 500', () async {
      await create();
      await service.setProfileSelected(profile.path, true);
      await service.setEnabled(true);
      history[profile.path] = [
        for (var i = 0; i < 1100; i++)
          yt('v${i.toString().padLeft(10, '0')}', Duration(seconds: i + 1)),
      ];
      await service.check();
      expect(sent.map((b) => b.entries), [500, 500, 100]);
      expect(service.videosImported, 1100);
    });

    test('settings and stamps are restored per vault identity', () async {
      await create();
      await service.setProfileSelected(profile.path, true);
      await service.setEnabled(true);
      await service.setInterval(const Duration(minutes: 1));
      expect(service.interval, minBrowserPollInterval);
      history[profile.path] = [yt('bbbbbbbbbbb', const Duration(minutes: 5))];
      await service.check();

      final again = BrowserHistoryWatchService(
        state,
        store: store,
        supportedOverride: true,
        now: () => now,
        discoverer: () async => [profile],
        reader: (p, after) async => [
          for (final v in history[p.path]!)
            if (v.time.isAfter(after)) v,
        ],
        importer: (b) async {
          sent.add(b);
          return b.entries;
        },
      );
      addTearDown(again.dispose);
      again.start();
      while (again.working) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(again.enabled, isTrue);
      expect(again.selected, {profile.path});
      expect(again.interval, minBrowserPollInterval);
      expect(sent, hasLength(1), reason: 'restored stamp prevents a re-import');
    });

    test('auto transcripts respect the daily cap and reset next day', () async {
      await create();
      await service.setProfileSelected(profile.path, true);
      await service.setTranscriptsPerDay(3);
      await service.setAutoTranscripts(true);
      await service.setEnabled(true);

      history[profile.path] = [
        for (var i = 0; i < 5; i++)
          yt('v${i.toString().padLeft(10, '0')}', Duration(minutes: i + 1)),
      ];
      fetchDone = 3;
      await service.check();
      expect(fetchLimits, [3], reason: 'limited by the daily cap');
      expect(service.transcriptsToday, 3);

      history[profile.path]!.add(
        yt('zzzzzzzzzzz', const Duration(minutes: 30)),
      );
      now = _t0.add(const Duration(minutes: 40));
      await service.check();
      expect(fetchLimits, [3], reason: 'cap reached: no more fetching today');
      expect(service.status, contains('Daily transcript limit'));

      history[profile.path]!.add(
        yt('yyyyyyyyyyy', const Duration(days: 1, minutes: 30)),
      );
      now = _t0.add(const Duration(days: 1, hours: 1));
      fetchDone = 1;
      await service.check();
      expect(fetchLimits, [3, 1]);
      expect(service.transcriptsToday, 1);
    });

    test('auto transcripts are off by default and pause after a block', () async {
      await create();
      expect(service.autoTranscripts, isFalse);
      expect(service.transcriptsPerDay, 20);
      await service.setProfileSelected(profile.path, true);
      await service.setEnabled(true);
      history[profile.path] = [yt('bbbbbbbbbbb', const Duration(minutes: 1))];
      await service.check();
      expect(fetchLimits, isEmpty);

      await service.setAutoTranscripts(true);
      fetchStop =
          'YouTube is blocking caption requests from the server. Try again later.';
      history[profile.path]!.add(yt('ccccccccccc', const Duration(minutes: 2)));
      await service.check();
      expect(fetchLimits, hasLength(1));
      history[profile.path]!.add(yt('ddddddddddd', const Duration(minutes: 3)));
      await service.check();
      expect(
        fetchLimits,
        hasLength(1),
        reason: 'paused after provider_blocked',
      );
    });
  });

  testWidgets('viewing history panel shows the browser history section', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = LifenizerAppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ViewingHistoryPanel(state: state)),
        ),
      ),
    );
    expect(find.byKey(const Key('browser-history-section')), findsOneWidget);
    expect(find.text('Keep updated from browser history'), findsOneWidget);
    if (state.browserHistory.supported) {
      expect(find.byKey(const Key('browser-history-enabled')), findsOneWidget);
      expect(
        find.byKey(const Key('browser-history-auto-transcripts')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('browser-history-pick-file')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Nothing else is read or uploaded'),
        findsOneWidget,
      );
    } else {
      expect(
        find.byKey(const Key('browser-history-unsupported')),
        findsOneWidget,
      );
    }
  });
}
