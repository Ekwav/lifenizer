import 'dart:convert';

/// Prefer the export's structure over provider filenames such as result.json.
String detectSharedImportSource({
  required String fileName,
  required String mimeType,
  String? text,
}) {
  final name = fileName.toLowerCase();
  if (name.endsWith('.pdf') || mimeType == 'application/pdf') {
    return 'scanned-pdf';
  }
  final content = text?.trim().replaceFirst(RegExp(r'^\uFEFF'), '') ?? '';
  if (RegExp(
    r'^\u200e?\[?\d{1,4}[./-]\d{1,2}[./-]\d{1,4},?\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APap][Mm])?(?:\]\s*|\s*-\s*)[^:\n]+:',
    multiLine: true,
  ).hasMatch(content)) {
    return 'whatsapp';
  }
  if (content.startsWith('{') || content.startsWith('[')) {
    final json = jsonDecode(content);
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
  if (name.endsWith('.zip') || mimeType.contains('zip')) {
    throw const FormatException(
      'This ZIP needs a source. Use the source file picker in Imports. WhatsApp ZIPs should contain one exported chat text file.',
    );
  }
  if (name.endsWith('.mbox')) return 'mbox';
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
