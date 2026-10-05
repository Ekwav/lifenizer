import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto_service.dart';
import 'vault_chunk_store.dart';
import 'vault_chunks.dart';

/// Test hook: writes [bytes] to [temp]. The default flushes (fsync) the file.
typedef ChunkFileWriter = Future<void> Function(File temp, Uint8List bytes);

/// One file per chunk: `<root>/<hash(key) hex>/chunk-<n>.bin`.
///
/// File layout: magic `LCK1`, one byte nonce length, the ASCII nonce, then the
/// ASCII cipherText (base64 produced by the vault crypto) to end of file.
///
/// A save writes `chunk-<n>.bin.tmp`, flushes it to disk and renames it over the
/// old file, so a reader sees either the previous or the new chunk, never a
/// partial one. Every I/O error is thrown to the caller, which keeps the
/// outbox and cursor from advancing on a failed save.
class FileVaultChunkStore implements VaultChunkStore {
  FileVaultChunkStore(this.root, {ChunkFileWriter? writeFile})
    : _writeFile = writeFile ?? _flushedWrite;

  final String root;
  final ChunkFileWriter _writeFile;

  @override
  String get kind => 'files';

  static final _magic = [0x4c, 0x43, 0x4b, 0x31];
  static final _name = RegExp(r'^chunk-(\d+)\.bin$');

  String directoryFor(String key) =>
      '$root/${stableStringHash(key).toRadixString(16).padLeft(8, '0')}';
  String pathFor(String key, int n) => '${directoryFor(key)}/chunk-$n.bin';

  static Future<void> _flushedWrite(File temp, Uint8List bytes) async {
    final file = await temp.open(mode: FileMode.write);
    try {
      await file.writeFrom(bytes);
      await file.flush();
    } finally {
      await file.close();
    }
  }

  static Uint8List encode(Map<String, dynamic> record) {
    final nonce = ascii.encode(record['nonce'] as String);
    final cipher = ascii.encode(record['cipherText'] as String);
    final bytes = Uint8List(5 + nonce.length + cipher.length)
      ..setRange(0, 4, _magic)
      ..[4] = nonce.length
      ..setRange(5, 5 + nonce.length, nonce)
      ..setRange(5 + nonce.length, 5 + nonce.length + cipher.length, cipher);
    return bytes;
  }

  static Map<String, dynamic> decode(Uint8List bytes) {
    if (bytes.length < 5 ||
        bytes[0] != _magic[0] ||
        bytes[1] != _magic[1] ||
        bytes[2] != _magic[2] ||
        bytes[3] != _magic[3] ||
        bytes.length < 5 + bytes[4]) {
      throw const FormatException('Not a vault chunk file.');
    }
    return {
      'nonce': ascii.decode(bytes.sublist(5, 5 + bytes[4])),
      'cipherText': ascii.decode(bytes.sublist(5 + bytes[4])),
    };
  }

  @override
  Future<List<int>> listChunks(String key) async {
    final directory = Directory(directoryFor(key));
    if (!await directory.exists()) return [];
    final found = <int>[];
    await for (final entity in directory.list()) {
      final match = _name.firstMatch(entity.uri.pathSegments.last);
      if (entity is File && match != null) found.add(int.parse(match[1]!));
    }
    return found..sort();
  }

  @override
  Future<Map<String, dynamic>?> readChunk(String key, int n) async {
    final file = File(pathFor(key, n));
    if (!await file.exists()) return null;
    return decode(await file.readAsBytes());
  }

  @override
  Future<void> writeChunks(
    String key,
    Map<int, Map<String, dynamic>> records,
  ) async {
    await Directory(directoryFor(key)).create(recursive: true);
    for (final entry in records.entries) {
      await _writeAtomic(pathFor(key, entry.key), entry.value);
    }
  }

  Future<void> _writeAtomic(String target, Map<String, dynamic> record) async {
    final temp = File('$target.tmp');
    try {
      await _writeFile(temp, encode(record));
      await temp.rename(target);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  String _blobPath(String key, String name) => '${directoryFor(key)}/$name.bin';

  @override
  Future<Map<String, dynamic>?> readBlob(String key, String name) async {
    final file = File(_blobPath(key, name));
    if (!await file.exists()) return null;
    return decode(await file.readAsBytes());
  }

  @override
  Future<void> writeBlob(
    String key,
    String name,
    Map<String, dynamic> record,
  ) async {
    await Directory(directoryFor(key)).create(recursive: true);
    await _writeAtomic(_blobPath(key, name), record);
  }

  @override
  Future<void> deleteBlob(String key, String name) async {
    final file = File(_blobPath(key, name));
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> deleteChunks(String key, Iterable<int> chunks) async {
    for (final n in chunks) {
      final file = File(pathFor(key, n));
      if (await file.exists()) await file.delete();
    }
  }

  @override
  Future<void> deleteAll(String key) async {
    await deleteChunks(key, await listChunks(key));
    final directory = Directory(directoryFor(key));
    if (await directory.exists() && await directory.list().isEmpty) {
      await directory.delete();
    }
  }

  @override
  Future<String?> chunkNonce(String key, int n) async {
    final file = File(pathFor(key, n));
    if (!await file.exists()) return null;
    final handle = await file.open();
    try {
      final header = await handle.read(5 + 255);
      return decode(Uint8List.fromList(header))['nonce'] as String;
    } finally {
      await handle.close();
    }
  }

  @override
  Future<Map<String, dynamic>> decryptChunk(
    VaultCrypto crypto,
    String key,
    int n,
    String expectedNonce, {
    Iterable<String> alternateNonces = const [],
    bool background = true,
  }) => crypto.decryptLoaded(
    chunkFileLoader(pathFor(key, n)),
    expectedNonce: expectedNonce,
    alternateNonces: alternateNonces.toList(),
    background: background,
  );
}

/// Top level so the closure captures only the path and can run in a worker.
Future<({String cipherText, String nonce})> Function() chunkFileLoader(
  String path,
) => () async {
  final record = FileVaultChunkStore.decode(await File(path).readAsBytes());
  return (
    cipherText: record['cipherText'] as String,
    nonce: record['nonce'] as String,
  );
};
