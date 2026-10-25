import 'dart:convert';
import 'dart:typed_data';

import 'package:app/services/shared_import_source.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List zip(List<ArchiveFile> files) {
  final archive = Archive();
  for (final file in files) {
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

ArchiveFile history(List<int> bytes) =>
    ArchiveFile('watch-history.json', bytes.length, bytes);

void patchHeaders(Uint8List bytes, {int? size, int? crc, int? flags}) {
  final data = ByteData.sublistView(bytes);
  for (var offset = 0; offset + 46 <= bytes.length; offset++) {
    final signature = data.getUint32(offset, Endian.little);
    final central = signature == 0x02014b50;
    if (!central && signature != 0x04034b50) continue;
    if (size != null) {
      data.setUint32(offset + (central ? 24 : 22), size, Endian.little);
    }
    if (crc != null) {
      data.setUint32(offset + (central ? 16 : 14), crc, Endian.little);
    }
    if (flags != null) {
      data.setUint16(offset + (central ? 8 : 6), flags, Endian.little);
    }
  }
}

void main() {
  test('rejects forged small size during deflate expansion', () {
    final bytes = zip([history(List.filled(8192, 65))]);
    patchHeaders(bytes, size: 16);
    expect(selectWatchHistoryZipEntry(bytes, maxEntryBytes: 128), isNull);
  });

  test('accepts exact output limit and rejects declared oversized entry', () {
    final content = List.filled(4096, 65);
    final bytes = zip([history(content)]);
    expect(
      selectWatchHistoryZipEntry(bytes, maxEntryBytes: 4096)?.bytes,
      content,
    );
    expect(selectWatchHistoryZipEntry(bytes, maxEntryBytes: 4095), isNull);
  });

  test('never inflates unrelated symbolic links', () {
    final bytes = zip([
      ArchiveFile('unrelated-link', 1, [255])..mode = 0xa1ff,
      history(utf8.encode('[{"header":"YouTube"}]')),
    ]);
    expect(selectWatchHistoryZipEntry(bytes)?.source, 'youtube-watch-history');
  });

  test('rejects selected symbolic links and encrypted entries', () {
    final linked = zip([history(utf8.encode('target'))..mode = 0xa1ff]);
    expect(selectWatchHistoryZipEntry(linked), isNull);
    final encrypted = zip([history(utf8.encode('content'))]);
    patchHeaders(encrypted, flags: 1);
    expect(selectWatchHistoryZipEntry(encrypted), isNull);
  });

  test('rejects corrupted CRC without exposing partial contents', () {
    final bytes = zip([history(utf8.encode('content'))]);
    patchHeaders(bytes, crc: 0);
    expect(selectWatchHistoryZipEntry(bytes), isNull);
  });

  test('leaves unrelated large compressed media untouched', () {
    final bytes = zip([
      ArchiveFile('media.zip', 8192, List.filled(8192, 65)),
      history(utf8.encode('content')),
    ]);
    expect(
      selectWatchHistoryZipEntry(bytes, maxEntryBytes: 128)?.bytes,
      utf8.encode('content'),
    );
  });
}
