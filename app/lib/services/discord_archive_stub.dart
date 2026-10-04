import '../models.dart';

Future<bool> isDiscordArchive(String path) async => false;

Stream<NormalizedImportResult> readDiscordArchive(
  String path, {
  void Function(int channels, int total, int messages)? onProgress,
  int maxEntryBytes = 8 * 1024 * 1024,
  int maxSelectedBytes = 256 * 1024 * 1024,
}) => Stream.error(
  UnsupportedError(
    'Open the Discord ZIP in the native desktop app; a large data package is not uploaded through the browser.',
  ),
);
