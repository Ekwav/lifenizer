import 'backup_archive.dart';

bool get backupFilesSupported => false;

Never _unsupported() => throw UnsupportedError(
  'Streaming backup files are supported on Android, Windows, macOS and Linux. '
  'Use one of those apps to export or restore a large backup.',
);

Future<BackupTarget?> pickBackupTarget() async => _unsupported();
Future<List<BackupPart>> pickBackupParts() async => _unsupported();
