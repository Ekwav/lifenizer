import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<Uint8List> readExportBytes(
  PlatformFile file, {
  int maxBytes = 64 * 1024 * 1024,
}) async {
  final sizeError =
      'Choose an export of at most ${maxBytes ~/ (1024 * 1024)} MiB.';
  if (file.size > maxBytes) {
    throw FormatException(sizeError);
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
      throw FormatException(sizeError);
    }
    bytes.add(chunk);
  }
  if (bytes.isEmpty) {
    throw const FormatException('The selected export is empty.');
  }
  return bytes.takeBytes();
}
