import 'dart:convert';

import 'package:archive/archive.dart';

/// File-name hints used when the server's capabilities are unavailable. They
/// mirror the `fileNameHints` the backend lists per source.
const Map<String, List<String>> defaultFileNameHints = {
  'youtube-watch-history': ['watch-history.json|html'],
  'tiktok-watch-history': [
    'user_data*.json',
    'Video Browsing History.txt',
    'Browsing History.txt',
  ],
};

const Set<String> photoExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'heic',
  'heif',
};

bool isEmailExport(String fileName, String mimeType) {
  final name = fileName.toLowerCase();
  final mime = mimeType.split(';').first.trim().toLowerCase();
  return name.endsWith('.eml') ||
      name.endsWith('.mbox') ||
      mime == 'message/rfc822' ||
      mime == 'application/mbox';
}

/// True for camera-style images that belong to the `photo` source.
bool isPhotoFile(String fileName, [String mimeType = '']) {
  final name = fileName.toLowerCase();
  final extension = name.contains('.') ? name.split('.').last : '';
  final mime = mimeType.toLowerCase();
  return photoExtensions.contains(extension) ||
      const {
        'image/jpeg',
        'image/png',
        'image/webp',
        'image/heic',
        'image/heif',
      }.contains(mime);
}

/// Expands a hint such as `watch-history.json|html` into one RegExp per
/// alternative. `*` is a wildcard; matching ignores case.
List<RegExp> _hintPatterns(String hint) {
  final parts = hint.split('|').map((part) => part.trim()).toList();
  final first = parts.first;
  final dot = first.lastIndexOf('.');
  final stem = dot < 0 ? first : first.substring(0, dot);
  final names = <String>[
    first,
    for (final alternative in parts.skip(1))
      if (alternative.contains('.') || dot < 0)
        alternative
      else
        '$stem.$alternative',
  ];
  return [
    for (final name in names)
      RegExp(
        '^${name.split('*').map(RegExp.escape).join('.*')}\$',
        caseSensitive: false,
      ),
  ];
}

/// The source whose capability `fileNameHints` match [fileName], if any.
String? sourceFromFileNameHints(
  String fileName,
  Map<String, List<String>> hints,
) {
  final base = fileName.split(RegExp(r'[\\/]')).last;
  for (final entry in hints.entries) {
    for (final hint in entry.value) {
      if (_hintPatterns(hint).any((pattern) => pattern.hasMatch(base))) {
        return entry.key;
      }
    }
  }
  return null;
}

bool _hasKeyDeep(Object? node, String key, [int depth = 0]) {
  if (depth > 4 || node is! Map) return false;
  if (node.containsKey(key)) return true;
  return node.values.any((value) => _hasKeyDeep(value, key, depth + 1));
}

bool _isYouTubeTakeoutJson(Object? json) =>
    json is List &&
    json.isNotEmpty &&
    json.any(
      (item) =>
          item is Map &&
          item['titleUrl'] != null &&
          '${item['header'] ?? ''}'.toLowerCase().startsWith('youtube'),
    );

bool _isTikTokText(String content) =>
    !content.startsWith('{') &&
    !content.startsWith('[') &&
    RegExp(r'^\s*Date:\s*\S', multiLine: true).hasMatch(content) &&
    RegExp(r'^\s*Link:\s*https?://', multiLine: true).hasMatch(content);

bool _isYouTubeHtml(String content) {
  final head = content.length > 200000 ? content.substring(0, 200000) : content;
  if (!RegExp(
    r'<(html|!doctype|body|div)',
    caseSensitive: false,
  ).hasMatch(head)) {
    return false;
  }
  final lower = head.toLowerCase();
  return lower.contains('watch-history') ||
      (lower.contains('content-cell') &&
          RegExp(
            r'(watched|angesehen|vu\b|visto)',
            caseSensitive: false,
          ).hasMatch(head) &&
          lower.contains('youtube.com/watch'));
}

/// Recognizes a Paperless manifest or document ZIP without inflating entries.
bool isPaperlessExportZip(List<int> bytes) {
  try {
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    var documents = false;
    for (final entry in directory.fileHeaders) {
      final name = entry.filename.replaceAll('\\', '/').toLowerCase();
      final base = name.split('/').last;
      if (sourceFromFileNameHints(base, defaultFileNameHints) != null ||
          RegExp(
            r'^(?:[^/]+/)?(?:messages|nachrichten)/[^/]+/messages\.json$',
          ).hasMatch(name)) {
        return false;
      }
      if (base == 'manifest.json' ||
          base == 'documents.json' ||
          base.endsWith('.pdf') ||
          isPhotoFile(base)) {
        documents = true;
      }
    }
    return documents;
  } catch (_) {
    return false;
  }
}

/// A watch-history file chosen from inside a Takeout / TikTok ZIP.
class ImportZipEntry {
  const ImportZipEntry({
    required this.name,
    required this.bytes,
    required this.source,
  });
  final String name;
  final List<int> bytes;
  final String source;
}

/// Picks the right watch-history entry from a Google Takeout or TikTok ZIP
/// instead of the first text file. Returns null when none is present.
ImportZipEntry? selectWatchHistoryZipEntry(
  List<int> zipBytes, {
  Map<String, List<String>> fileNameHints = defaultFileNameHints,
  int maxEntryBytes = 64 * 1024 * 1024,
}) {
  try {
    final directory = ZipDirectory()..read(InputMemoryStream(zipBytes));
    ZipFileHeader? selected;
    String? selectedSource;
    var bestRank = 1 << 30;
    for (final entry in directory.fileHeaders) {
      if (entry.uncompressedSize > maxEntryBytes ||
          entry.compressedSize > maxEntryBytes ||
          (entry.generalPurposeBitFlag & 1) != 0 ||
          ((entry.externalFileAttributes >> 16) & 0xf000) == 0xa000 ||
          !const [0, 8].contains(entry.compressionMethod)) {
        continue;
      }
      final base = entry.filename.split(RegExp(r'[\\/]')).last;
      if (base.isEmpty) continue;
      final source = sourceFromFileNameHints(base, fileNameHints);
      if (source == null) continue;
      // JSON beats HTML beats text; shallower paths beat deeper ones.
      final lower = base.toLowerCase();
      final rank =
          (lower.endsWith('.json')
                  ? 0
                  : lower.endsWith('.html')
                  ? 1
                  : 2) *
              100 +
          entry.filename.split(RegExp(r'[\\/]')).length;
      if (rank >= bestRank) continue;
      selected = entry;
      selectedSource = source;
      bestRank = rank;
    }
    if (selected == null) return null;
    final output = _BoundedZipOutput(maxEntryBytes);
    final compressed = selected.file!.getStream(decompress: false);
    if (selected.compressionMethod == 8) {
      const ZLibDecoderWeb().decodeStream(compressed, output, raw: true);
    } else {
      output.writeStream(compressed);
    }
    final bytes = output.getBytes();
    if (bytes.length != selected.uncompressedSize ||
        getCrc32(bytes) != selected.crc32) {
      return null;
    }
    return ImportZipEntry(
      name: selected.filename.split(RegExp(r'[\\/]')).last,
      bytes: bytes,
      source: selectedSource!,
    );
  } catch (_) {
    return null;
  }
}

/// Prefer the export's structure over provider filenames such as result.json.
String detectSharedImportSource({
  required String fileName,
  required String mimeType,
  String? text,
  Map<String, List<String>> fileNameHints = defaultFileNameHints,
}) {
  final name = fileName.toLowerCase();
  if (isEmailExport(name, mimeType)) return 'mbox';
  if (name.endsWith('.pdf') || mimeType == 'application/pdf') {
    return 'scanned-pdf';
  }
  if (isPhotoFile(name, mimeType)) return 'photo';
  final content = text?.trim().replaceFirst(RegExp(r'^\uFEFF'), '') ?? '';
  if (_isTikTokText(content)) return 'tiktok-watch-history';
  if (_isYouTubeHtml(content)) return 'youtube-watch-history';
  if (RegExp(
    r'^\u200e?\[?\d{1,4}[./-]\d{1,2}[./-]\d{1,4},?\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APap][Mm])?(?:\]\s*|\s*-\s*)[^:\n]+:',
    multiLine: true,
  ).hasMatch(content)) {
    return 'whatsapp';
  }
  if (content.startsWith('{') || content.startsWith('[')) {
    final json = jsonDecode(content);
    if (_isYouTubeTakeoutJson(json)) return 'youtube-watch-history';
    if (json is Map && _hasKeyDeep(json, 'Video Browsing History')) {
      return 'tiktok-watch-history';
    }
    if (json is Map) {
      if (json.containsKey('cipherText') && json.containsKey('nonce')) {
        throw const FormatException(
          'This is an encrypted vault snapshot. Connect the original vault, or choose a readable chat export.',
        );
      }
      if (json['conversations'] is List) return 'lifenizer-backup';
      if (json['chats'] is Map && json['chats']['list'] is List) {
        return 'telegram';
      }
      final messages = json['messages'];
      if (messages is List &&
          messages.any(
            (m) =>
                m is Map && (m.containsKey('from') || m.containsKey('actor')),
          )) {
        return 'telegram';
      }
    }
    final hinted = sourceFromFileNameHints(name, fileNameHints);
    if (hinted != null) return hinted;
    // Known source names still support the other existing JSON importers.
    if (!name.contains('backup')) {
      for (final source in [
        'telegram',
        'whatsapp',
        'signal',
        'slack',
        'teams',
        'bookmarks',
      ]) {
        if (name.contains(source)) return source;
      }
    }
    throw const FormatException(
      'Unrecognized JSON export. Choose its source in Imports instead of importing JSON as chat text.',
    );
  }
  for (final source in ['whatsapp', 'telegram', 'signal', 'slack', 'teams']) {
    if (name.contains(source)) return source;
  }
  final hinted = sourceFromFileNameHints(name, fileNameHints);
  if (hinted != null) return hinted;
  if (name.endsWith('.zip') || mimeType.contains('zip')) {
    throw const FormatException(
      'This ZIP needs a source. Use the source file picker in Imports. WhatsApp ZIPs should contain one exported chat text file.',
    );
  }
  if (name.endsWith('.patch') ||
      name.endsWith('.diff') ||
      name.contains('git')) {
    return 'git';
  }
  if (name.contains('bookmark')) return 'bookmarks';
  if (name.contains('google') && name.contains('search')) {
    return 'google-search-history';
  }
  if (name.contains('history')) return 'browser-history';
  if (name.endsWith('.csv') || mimeType.contains('csv')) {
    throw const FormatException('Choose the source for this CSV in Imports.');
  }
  if (name.endsWith('.json') ||
      mimeType.contains('json') ||
      name.endsWith('.lifenizerbackup')) {
    throw const FormatException(
      'This file is not a recognized readable JSON export. Choose its source in Imports.',
    );
  }
  if (mimeType == 'text/uri-list' || content.startsWith('http')) {
    return 'browser-capture';
  }
  return 'manual-text';
}

/// Enforce the actual inflated size, including deflate back-references.
class _BoundedZipOutput extends OutputMemoryStream {
  _BoundedZipOutput(this.limit);
  final int limit;
  void _check(int count) {
    if (length + count > limit) {
      throw const FormatException('ZIP entry exceeds the import limit.');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      writeBytes(
        stream
            .readBytes(stream.length < 65536 ? stream.length : 65536)
            .toUint8List(),
      );
    }
  }
}
