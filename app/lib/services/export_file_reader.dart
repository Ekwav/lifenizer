import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<Uint8List> readExportBytes(
  PlatformFile file, {
  int maxBytes = 64 * 1024 * 1024,
}) async {
  if (file.size > maxBytes) {
    throw const FormatException('Choose an export of at most 64 MiB.');
  }
  final stream =
      file.readStream ??
      (file.bytes == null ? null : Stream.value(file.bytes!));
  if (stream == null) {
    throw const FormatException('The selected export is unreadable.');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const FormatException('Choose an export of at most 64 MiB.');
    }
    bytes.add(chunk);
  }
  if (bytes.isEmpty) {
    throw const FormatException('The selected export is empty.');
  }
  return bytes.takeBytes();
}
