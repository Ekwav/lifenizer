import 'dart:convert';

import 'package:app/models.dart';
import 'package:app/services/shared_import_source.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _youtubeJson =
    '[{"header":"YouTube","title":"Watched Cats","titleUrl":"https://www.youtube.com/watch?v=aaaaaaaaaaa","subtitles":[{"name":"Chan","url":"https://www.youtube.com/channel/x"}],"time":"2026-05-01T10:00:00.000Z","products":["YouTube"]}]';
const _tiktokJson =
    '{"Activity":{"Video Browsing History":{"VideoList":[{"Date":"2026-05-01 10:00:00","Link":"https://www.tiktokv.com/share/video/7000000000000000001/"}]}}}';
const _tiktokText =
    'Date: 2026-05-01 10:00:00\nLink: https://www.tiktokv.com/share/video/7000000000000000001/\n\nDate: 2026-05-02 10:00:00\nLink: https://www.tiktokv.com/share/video/7000000000000000002/\n';
const _youtubeHtml =
    '<html><body><div class="content-cell mdl-cell">Watched <a href="https://www.youtube.com/watch?v=aaaaaaaaaaa">Cats</a><br>May 1, 2026, 10:00:00 AM UTC</div></body></html>';

List<int> _zip(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

void main() {
  test(
    'Paperless ZIP detection uses document names and preserves other sources',
    () {
      for (final name in [
        'manifest.json',
        'export/documents.json',
        'documents/invoice.pdf',
        'documents/scan.png',
      ]) {
        expect(isPaperlessExportZip(_zip({name: 'not inflated'})), isTrue);
      }
      for (final name in [
        'Takeout/history/watch-history.json',
        'Video Browsing History.txt',
        'package/messages/123/messages.json',
      ]) {
        expect(
          isPaperlessExportZip(
            _zip({name: '{}', 'attachment.pdf': 'document'}),
          ),
          isFalse,
        );
      }
      expect(isPaperlessExportZip(_zip({'chat.txt': 'chat'})), isFalse);
      expect(isPaperlessExportZip([1, 2, 3]), isFalse);
    },
  );

  group('detectSharedImportSource', () {
    test('email exports route before generic text or JSON inspection', () {
      for (final (name, mime) in [
        ('MESSAGE.EML', ''),
        ('mailbox.mbox', ''),
        ('download', 'message/rfc822'),
        ('download', 'application/mbox; charset=windows-1252'),
      ]) {
        expect(
          detectSharedImportSource(
            fileName: name,
            mimeType: mime,
            text: '{not JSON: this is a MIME message body',
          ),
          'mbox',
        );
      }
    });

    test('YouTube Takeout JSON, even with a generic file name', () {
      expect(
        detectSharedImportSource(
          fileName: 'export.json',
          mimeType: 'application/json',
          text: _youtubeJson,
        ),
        'youtube-watch-history',
      );
    });

    test('YouTube Takeout HTML', () {
      expect(
        detectSharedImportSource(
          fileName: 'watch-history.html',
          mimeType: 'text/html',
          text: _youtubeHtml,
        ),
        'youtube-watch-history',
      );
      expect(
        detectSharedImportSource(
          fileName: 'x.html',
          mimeType: 'text/html',
          text: '<html><!-- watch-history --></html>',
        ),
        'youtube-watch-history',
      );
    });

    test('TikTok JSON and TXT', () {
      expect(
        detectSharedImportSource(
          fileName: 'user_data_tiktok.json',
          mimeType: 'application/json',
          text: _tiktokJson,
        ),
        'tiktok-watch-history',
      );
      expect(
        detectSharedImportSource(
          fileName: 'Video Browsing History.txt',
          mimeType: 'text/plain',
          text: _tiktokText,
        ),
        'tiktok-watch-history',
      );
    });

    test('capability fileNameHints decide when content is ambiguous', () {
      expect(
        detectSharedImportSource(
          fileName: 'user_data_123.json',
          mimeType: 'application/json',
          text: '{"Profile":{}}',
          fileNameHints: const {
            'tiktok-watch-history': ['user_data*.json'],
          },
        ),
        'tiktok-watch-history',
      );
      expect(
        sourceFromFileNameHints('Takeout/history/watch-history.html', const {
          'youtube-watch-history': ['watch-history.json|html'],
        }),
        'youtube-watch-history',
      );
      expect(
        sourceFromFileNameHints('watch-history.csv', const {
          'youtube-watch-history': ['watch-history.json|html'],
        }),
        isNull,
      );
    });

    test('images go to photo, PDFs stay scanned-pdf', () {
      for (final name in [
        'a.jpg',
        'A.JPEG',
        'a.png',
        'a.webp',
        'a.HEIC',
        'a.heif',
      ]) {
        expect(
          detectSharedImportSource(fileName: name, mimeType: ''),
          'photo',
          reason: name,
        );
      }
      expect(
        detectSharedImportSource(fileName: 'x', mimeType: 'image/jpeg'),
        'photo',
      );
      expect(
        detectSharedImportSource(
          fileName: 'scan.pdf',
          mimeType: 'application/pdf',
        ),
        'scanned-pdf',
      );
    });

    test('other JSON is still rejected', () {
      expect(
        () => detectSharedImportSource(
          fileName: 'x.json',
          mimeType: 'application/json',
          text: '{"foo":1}',
        ),
        throwsFormatException,
      );
    });
  });

  group('selectWatchHistoryZipEntry', () {
    test('picks watch-history.json rather than the first text entry', () {
      final entry = selectWatchHistoryZipEntry(
        _zip({
          'Takeout/archive_browser.html': '<html>no</html>',
          'Takeout/YouTube and YouTube Music/subscriptions/subscriptions.csv':
              'a,b',
          'Takeout/YouTube and YouTube Music/history/watch-history.html':
              _youtubeHtml,
          'Takeout/YouTube and YouTube Music/history/watch-history.json':
              _youtubeJson,
        }),
      );
      expect(entry, isNotNull);
      expect(entry!.name, 'watch-history.json');
      expect(entry.source, 'youtube-watch-history');
      expect(utf8.decode(entry.bytes), _youtubeJson);
    });

    test('falls back to HTML and finds TikTok entries', () {
      expect(
        selectWatchHistoryZipEntry(
          _zip({'a/readme.txt': 'x', 'a/watch-history.html': _youtubeHtml}),
        )?.name,
        'watch-history.html',
      );
      final tiktok = selectWatchHistoryZipEntry(
        _zip({
          'Comments.txt': 'Date: x',
          'Video Browsing History.txt': _tiktokText,
        }),
      );
      expect(tiktok?.source, 'tiktok-watch-history');
      expect(
        selectWatchHistoryZipEntry(
          _zip({'user_data_tiktok.json': _tiktokJson}),
        )?.source,
        'tiktok-watch-history',
      );
    });

    test('returns null for unrelated zips and non-zips', () {
      expect(selectWatchHistoryZipEntry(_zip({'chat.txt': 'hi'})), isNull);
      expect(selectWatchHistoryZipEntry([1, 2, 3]), isNull);
    });
  });

  test('ImportCapability parses fileNameHints and tolerates absence', () {
    final base = {
      'source': 'youtube-watch-history',
      'displayName': 'YouTube',
      'availableNow': true,
      'requiresCredentials': false,
      'status': 'ok',
      'acceptedFormats': ['json'],
    };
    expect(ImportCapability.fromJson(base).fileNameHints, isEmpty);
    expect(
      ImportCapability.fromJson({
        ...base,
        'fileNameHints': ['watch-history.json|html'],
      }).fileNameHints,
      ['watch-history.json|html'],
    );
  });
}
