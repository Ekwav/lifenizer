import 'package:path_provider/path_provider.dart';

/// Where the encrypted vault (and with it a pending recording) lives.
Future<String> describeVaultStorage() async {
  final directory = await getApplicationSupportDirectory();
  final parts = directory.path
      .split(RegExp(r'[\\/]'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.length <= 3) return directory.path;
  return '…/${parts.sublist(parts.length - 3).join('/')}';
}
