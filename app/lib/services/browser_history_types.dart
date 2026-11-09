import 'dart:convert';

import 'transcript_enrichment.dart';

/// A browser history database found on this computer (or picked by hand).
class BrowserProfile {
  const BrowserProfile({required this.path, required this.label});
  final String path;
  final String label;
}

/// One page visit as stored by the browser (all pages, before filtering).
class BrowserVisit {
  const BrowserVisit({
    required this.url,
    required this.title,
    required this.time,
  });
  final String url;
  final String title;
  final DateTime time;
}

/// A visit of a YouTube or TikTok video.
class VideoVisit {
  const VideoVisit({
    required this.platform,
    required this.id,
    required this.url,
    required this.title,
    required this.time,
    this.music = false,
    this.channel,
  });
  final String platform; // 'youtube' | 'tiktok'
  final String id;
  final String url; // canonical video URL
  final String title;
  final DateTime time;
  final bool music;

  /// Channel name when the source knows it (browser extension), YouTube only.
  final String? channel;
}

/// Microseconds between 1601-01-01 (Chromium/Windows epoch) and 1970-01-01.
const int chromiumEpochOffsetMicros = 11644473600000000;

/// Firefox `moz_historyvisits.visit_date`: microseconds since the Unix epoch.
DateTime firefoxVisitTime(int micros) =>
    DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);

int firefoxVisitMicros(DateTime time) => time.toUtc().microsecondsSinceEpoch;

/// Chromium `visits.visit_time`: microseconds since 1601-01-01 UTC.
DateTime chromiumVisitTime(int micros) => DateTime.fromMicrosecondsSinceEpoch(
  micros - chromiumEpochOffsetMicros,
  isUtc: true,
);

int chromiumVisitMicros(DateTime time) =>
    time.toUtc().microsecondsSinceEpoch + chromiumEpochOffsetMicros;

final _youtubeId = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _tiktokId = RegExp(r'^\d{8,}$');
final _titleSuffix = RegExp(r'\s+-\s+YouTube(?: Music)?$');
final _titleBadge = RegExp(r'^\(\d+\)\s*');

String _cleanTitle(String raw, String url) {
  var title = raw
      .trim()
      .replaceFirst(_titleBadge, '')
      .replaceFirst(_titleSuffix, '')
      .trim();
  if (title == 'YouTube' || title == 'YouTube Music' || title == url) return '';
  return title;
}

/// Maps a browser visit to a YouTube or TikTok video visit, or null for any
/// other page (including `vm.tiktok.com` short links, which cannot be
/// resolved without a network request).
VideoVisit? classifyVisit(BrowserVisit visit) {
  final uri = Uri.tryParse(visit.url.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  String? ytId;
  var music = false;
  if (host == 'youtu.be') {
    if (segments.length == 1) ytId = segments[0];
  } else if (host == 'youtube.com' ||
      host == 'www.youtube.com' ||
      host == 'm.youtube.com' ||
      host == 'music.youtube.com') {
    music = host == 'music.youtube.com';
    if (segments.length == 1 && segments[0] == 'watch') {
      ytId = uri.queryParameters['v'];
    } else if (!music && segments.length == 2 && segments[0] == 'shorts') {
      ytId = segments[1];
    }
  } else if (host == 'tiktok.com' ||
      host == 'www.tiktok.com' ||
      host == 'm.tiktok.com') {
    if (segments.length == 3 &&
        segments[0].startsWith('@') &&
        segments[0].length > 1 &&
        segments[1] == 'video' &&
        _tiktokId.hasMatch(segments[2])) {
      return VideoVisit(
        platform: 'tiktok',
        id: segments[2],
        url: 'https://www.tiktok.com/${segments[0]}/video/${segments[2]}',
        title: '',
        time: visit.time.toUtc(),
      );
    }
    return null;
  }
  if (ytId == null || !_youtubeId.hasMatch(ytId)) return null;
  return VideoVisit(
    platform: 'youtube',
    id: ytId,
    url: 'https://www.youtube.com/watch?v=$ytId',
    title: _cleanTitle(visit.title, visit.url),
    time: visit.time.toUtc(),
    music: music,
  );
}

String _isoSeconds(DateTime time) {
  final utc = time.toUtc();
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(utc.year, 4)}-${p(utc.month)}-${p(utc.day)}T'
      '${p(utc.hour)}:${p(utc.minute)}:${p(utc.second)}Z';
}

String _tiktokDate(DateTime time) {
  final utc = time.toUtc();
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(utc.year, 4)}-${p(utc.month)}-${p(utc.day)} '
      '${p(utc.hour)}:${p(utc.minute)}:${p(utc.second)}';
}

/// One `importSource` payload.
class ViewingImportBatch {
  const ViewingImportBatch({
    required this.source,
    required this.json,
    required this.entries,
  });
  final String source;
  final String json;
  final int entries;
}

const int viewingBatchSize = 500;

/// Builds Takeout/TikTok-shaped JSON payloads for the existing watch-history
/// parsers, at most [maxEntries] per payload. Visits of one video within the
/// same second are sent once (the server dedupes by watch second anyway).
List<ViewingImportBatch> buildViewingBatches(
  Iterable<VideoVisit> visits, {
  int maxEntries = viewingBatchSize,
}) {
  final seen = <String>{};
  final sorted = <VideoVisit>[];
  for (final v in visits) {
    if (seen.add(
      '${v.platform}:${v.id}@${v.time.toUtc().millisecondsSinceEpoch ~/ 1000}',
    )) {
      sorted.add(v);
    }
  }
  sorted.sort((a, b) => a.time.compareTo(b.time));
  final batches = <ViewingImportBatch>[];
  for (final platform in const ['youtube', 'tiktok']) {
    final list = sorted.where((v) => v.platform == platform).toList();
    for (var i = 0; i < list.length; i += maxEntries) {
      final chunk = list.skip(i).take(maxEntries).toList();
      final Object payload = platform == 'youtube'
          ? [
              for (final v in chunk)
                {
                  'header': v.music ? 'YouTube Music' : 'YouTube',
                  'title': v.title,
                  'titleUrl': v.url,
                  'time': _isoSeconds(v.time),
                  if (v.channel != null && v.channel!.isNotEmpty)
                    'subtitles': [
                      {'name': v.channel},
                    ],
                },
            ]
          : {
              'Activity': {
                'Video Browsing History': {
                  'VideoList': [
                    for (final v in chunk)
                      {'Date': _tiktokDate(v.time), 'Link': v.url},
                  ],
                },
              },
            };
      batches.add(
        ViewingImportBatch(
          source: platform == 'youtube'
              ? 'youtube-watch-history'
              : 'tiktok-watch-history',
          json: jsonEncode(payload),
          entries: chunk.length,
        ),
      );
    }
  }
  return batches;
}

/// Reads visits newer than `after` from one browser history database.
typedef BrowserVisitReader =
    Future<List<BrowserVisit>> Function(BrowserProfile profile, DateTime after);

typedef BrowserProfileDiscoverer = Future<List<BrowserProfile>> Function();

/// Imports one payload. Returns the number of conversations added or updated,
/// or null when the import failed (the stamp must then not advance).
typedef ViewingBatchImporter = Future<int?> Function(ViewingImportBatch batch);

/// Fetches transcripts for at most `limit` of the newest videos.
typedef TranscriptAutoFetcher =
    Future<TranscriptBatchProgress> Function(int limit);

/// Allowed polling interval range.
const Duration minBrowserPollInterval = Duration(minutes: 15);
const Duration maxBrowserPollInterval = Duration(hours: 24);
const Duration defaultBrowserPollInterval = Duration(minutes: 60);
const int defaultAutoTranscriptsPerDay = 20;
