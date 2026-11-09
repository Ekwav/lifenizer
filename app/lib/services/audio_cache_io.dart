import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import 'vault_worker_io.dart';

Future<File> _file(String key) async {
  final hash = await Sha256().hash(utf8.encode(key));
  final name = hash.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  final directory = await getApplicationSupportDirectory();
  return File('${directory.path}/audio/$name.json');
}

Future<Map<String, dynamic>?> readAudioCache(String key) async {
  final file = await _file(key);
  if (!await file.exists()) return null;
  return _read(file.path);
}

Future<Map<String, dynamic>> _read(String path) => runVaultWork(
  () async => Map<String, dynamic>.from(
    jsonDecode(await File(path).readAsString()) as Map,
  ),
);

Future<void> writeAudioCache(String key, Map<String, dynamic> value) async {
  final file = await _file(key);
  await _write(file.path, value);
}

Future<void> _write(String path, Map<String, dynamic> value) =>
    runVaultWork(() async {
      final target = File(path);
      await target.parent.create(recursive: true);
      final temporary = File('$path.tmp');
      await temporary.writeAsString(jsonEncode(value), flush: true);
      await temporary.rename(path);
    });
