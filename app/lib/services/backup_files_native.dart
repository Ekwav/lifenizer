import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'backup_archive.dart';

const _channel = MethodChannel('com.lifenizer/backup_files');
const _chunkSize = 256 * 1024;

bool get backupFilesSupported =>
    Platform.isAndroid ||
    Platform.isLinux ||
    Platform.isMacOS ||
    Platform.isWindows;

void _requireSupported() {
  if (!backupFilesSupported) {
    throw UnsupportedError(
      'Streaming backup files are supported on Android, Windows, macOS and Linux.',
    );
  }
}

Future<BackupTarget?> pickBackupTarget() async {
  _requireSupported();
  if (Platform.isAndroid) {
    final label = await _channel.invokeMethod<String>('pickTarget');
    return label == null ? null : _AndroidTarget(label);
  }
  final path = await FilePicker.getDirectoryPath(
    dialogTitle: 'Choose a folder for backup files',
  );
  return path == null ? null : _DesktopTarget(path);
}

Future<List<BackupPart>> pickBackupParts() async {
  _requireSupported();
  if (Platform.isAndroid) {
    final files = await _channel.invokeListMethod<dynamic>('pickParts');
    return [
      for (final file in files ?? [])
        BackupPart(
          name: file['name'] as String,
          openRead: () => _readAndroid(file['uri'] as String),
        ),
    ];
  }
  final selection = await FilePicker.pickFiles(
    dialogTitle: 'Select all files belonging to this backup',
    allowMultiple: true,
    withData: false,
    withReadStream: true,
  );
  return [
    for (final file in selection?.files ?? <PlatformFile>[])
      BackupPart(name: file.name, openRead: () => File(file.path!).openRead()),
  ];
}

Stream<List<int>> _readAndroid(String uri) async* {
  await _channel.invokeMethod<void>('openRead', uri);
  try {
    while (true) {
      final bytes = await _channel.invokeMethod<Uint8List>('read', uri);
      if (bytes == null || bytes.isEmpty) break;
      yield bytes;
    }
  } finally {
    await _channel.invokeMethod<void>('closeRead', uri);
  }
}

class _AndroidTarget implements BackupTarget {
  _AndroidTarget(this.label);
  @override
  final String label;

  @override
  Future<void> openPart(String name) =>
      _channel.invokeMethod<void>('openPart', name);
  @override
  Future<void> write(Uint8List bytes) async {
    for (var offset = 0; offset < bytes.length; offset += _chunkSize) {
      final end = offset + _chunkSize;
      await _channel.invokeMethod<void>(
        'write',
        Uint8List.sublistView(
          bytes,
          offset,
          end > bytes.length ? bytes.length : end,
        ),
      );
    }
  }

  @override
  Future<void> closePart() => _channel.invokeMethod<void>('closePart');
  @override
  Future<void> abort() => _channel.invokeMethod<void>('abort');
}

class _DesktopTarget implements BackupTarget {
  _DesktopTarget(this.label);
  @override
  final String label;
  final _created = <File>[];
  RandomAccessFile? _output;

  @override
  Future<void> openPart(String name) async {
    if (_output != null) throw StateError('A backup file is already open.');
    if (name.isEmpty ||
        name.contains(RegExp(r'[/\\]')) ||
        name == '.' ||
        name == '..') {
      throw ArgumentError.value(name, 'name', 'Expected a backup filename.');
    }
    final file = File('$label${Platform.pathSeparator}$name');
    await file.create(exclusive: true);
    _created.add(file);
    _output = await file.open(mode: FileMode.writeOnly);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final output = _output;
    if (output == null) throw StateError('No backup file is open.');
    await output.writeFrom(bytes);
  }

  @override
  Future<void> closePart() async {
    final output = _output;
    _output = null;
    if (output != null) {
      try {
        await output.flush();
      } finally {
        await output.close();
      }
    }
  }

  @override
  Future<void> abort() async {
    try {
      await closePart();
    } finally {
      for (final file in _created) {
        if (await file.exists()) await file.delete();
      }
      _created.clear();
    }
  }
}
