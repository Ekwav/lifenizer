import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_worker_io.dart'
    if (dart.library.js_interop) 'vault_worker_web.dart';

const backupPartBytes = 5000000000;
const _headerBytes = 44;
const _frameOverhead = 29;
const _maxFrameBytes = 1024 * 1024;
const _maxRecordBytes = 64 * 1024 * 1024;
final _magic = ascii.encode('LFBAK001');

abstract class BackupTarget {
  String get label;
  Future<void> openPart(String name);
  Future<void> write(Uint8List bytes);
  Future<void> closePart();
  Future<void> abort();
}

class BackupPart {
  BackupPart({required this.name, required this.openRead});
  final String name;
  final Stream<List<int>> Function() openRead;
}

class BackupSummary {
  BackupSummary({required this.bytes, required this.parts});
  final int bytes;
  final int parts;
}

Future<SecretKey> _derive(String password, List<int> salt) async {
  final bytes = await runVaultWork(() async {
    final input = SecretKeyData(
      utf8.encode(password),
      overwriteWhenDestroyed: true,
    );
    SecretKey? key;
    try {
      key =
          await Pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: 180000,
            bits: 256,
          ).deriveKey(
            secretKey: input,
            nonce: [...ascii.encode('lifenizer-backup-v1:'), ...salt],
          );
      return (await key.extractBytes()).toList();
    } finally {
      input.destroy();
      key?.destroy();
    }
  });
  try {
    return SecretKeyData(bytes.toList(), overwriteWhenDestroyed: true);
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

Uint8List _number(int value, int size) {
  final bytes = Uint8List(size);
  final data = ByteData.sublistView(bytes);
  if (size == 4) {
    data.setUint32(0, value);
  } else {
    data.setUint64(0, value);
  }
  return bytes;
}

/// Writes encrypted NDJSON in independently bounded files. No plaintext files
/// or password-derived keys are persisted. Each frame authenticates its part,
/// sequence and type, including the mandatory end-of-archive marker.
Future<BackupSummary> writeBackup(
  Stream<Map<String, dynamic>> records, {
  required String password,
  required BackupTarget target,
  int partBytes = backupPartBytes,
  void Function(int bytes, int parts)? onProgress,
}) async {
  if (partBytes <= _headerBytes + _frameOverhead ||
      partBytes > backupPartBytes) {
    throw ArgumentError.value(partBytes, 'partBytes');
  }
  final random = Random.secure();
  final prefix = Uint8List.fromList([
    ..._magic,
    ...List.generate(32, (_) => random.nextInt(256)),
  ]);
  final id = prefix
      .sublist(24)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  SecretKey? key;
  final cipher = AesGcm.with256bits();
  var parts = 0;
  var bytes = 0;
  var used = partBytes;
  var sequence = 0;
  var header = Uint8List(0);
  try {
    key = await _derive(password, prefix.sublist(8, 24));
    Future<void> frame(List<int> clear, int type) async {
      if (used + _frameOverhead + clear.length > partBytes) {
        if (parts > 0) await target.closePart();
        header = Uint8List.fromList([...prefix, ..._number(parts, 4)]);
        parts++;
        await target.openPart(
          'lifenizer-$id.part${parts.toString().padLeft(8, '0')}.lfb',
        );
        await target.write(header);
        bytes += header.length;
        used = header.length;
      }
      final metadata = Uint8List.fromList([
        ..._number(clear.length, 4),
        type,
        ..._number(sequence, 8),
      ]);
      final box = await cipher.encrypt(
        clear,
        secretKey: key!,
        nonce: [0, 0, 0, 0, ..._number(sequence, 8)],
        aad: [...header, ...metadata],
      );
      final encoded = Uint8List.fromList([
        ...metadata,
        ...box.cipherText,
        ...box.mac.bytes,
      ]);
      await target.write(encoded);
      used += encoded.length;
      bytes += encoded.length;
      sequence++;
      onProgress?.call(bytes, parts);
    }

    final capacity = min(
      _maxFrameBytes,
      partBytes - _headerBytes - _frameOverhead,
    );
    await for (final record in records) {
      final encoded = utf8.encode('${jsonEncode(record)}\n');
      if (encoded.length > _maxRecordBytes) {
        throw const FormatException('Backup record exceeds 64 MiB.');
      }
      var offset = 0;
      while (offset < encoded.length) {
        final remaining = partBytes - used - _frameOverhead;
        final length = min(
          encoded.length - offset,
          remaining > 0 ? min(capacity, remaining) : capacity,
        );
        await frame(Uint8List.sublistView(encoded, offset, offset + length), 0);
        offset += length;
      }
    }
    await frame(const [], 1);
    await target.closePart();
    return BackupSummary(bytes: bytes, parts: parts);
  } catch (_) {
    await target.abort();
    rethrow;
  } finally {
    key?.destroy();
  }
}

class _Input {
  _Input(Stream<List<int>> stream) : iterator = StreamIterator(stream);
  final StreamIterator<List<int>> iterator;
  List<int> chunk = const [];
  int offset = 0;

  Future<Uint8List?> read(int count, {bool allowEnd = false}) async {
    final result = Uint8List(count);
    var copied = 0;
    while (copied < count) {
      if (offset == chunk.length) {
        if (!await iterator.moveNext()) {
          if (copied == 0 && allowEnd) return null;
          throw const FormatException('Truncated backup.');
        }
        chunk = iterator.current;
        offset = 0;
        continue;
      }
      final take = min(count - copied, chunk.length - offset);
      result.setRange(copied, copied + take, chunk, offset);
      copied += take;
      offset += take;
    }
    return result;
  }
}

/// Selection order is irrelevant; embedded indexes and authenticated headers
/// reject missing, duplicated, foreign or modified parts. Consume to completion
/// before applying records: only the final marker proves archive completeness.
Stream<Map<String, dynamic>> readBackup(
  List<BackupPart> parts, {
  required String password,
}) async* {
  if (parts.isEmpty) throw const FormatException('No backup parts selected.');
  final ordered = [...parts]..sort((a, b) => a.name.compareTo(b.name));
  final cipher = AesGcm.with256bits();
  SecretKey? key;
  List<int>? prefix;
  var sequence = 0;
  var ended = false;
  var pending = BytesBuilder(copy: false);
  try {
    for (var partIndex = 0; partIndex < ordered.length; partIndex++) {
      if (ended) {
        throw const FormatException('Unexpected backup parts after end.');
      }
      final input = _Input(ordered[partIndex].openRead());
      try {
        final header = (await input.read(_headerBytes))!;
        if (!_sameBytes(header.sublist(0, 8), _magic) ||
            ByteData.sublistView(header).getUint32(40) != partIndex ||
            (prefix != null && !_sameBytes(header.sublist(0, 40), prefix))) {
          throw const FormatException('Invalid or missing backup part.');
        }
        prefix ??= header.sublist(0, 40);
        key ??= await _derive(password, header.sublist(8, 24));
        var frameCount = 0;
        while (true) {
          final metadata = await input.read(13, allowEnd: true);
          if (metadata == null) break;
          if (ended) throw const FormatException('Trailing backup data.');
          final data = ByteData.sublistView(metadata);
          final length = data.getUint32(0);
          final type = metadata[4];
          if (length > _maxFrameBytes ||
              type > 1 ||
              (type == 1 && length != 0) ||
              (type == 0 && length == 0) ||
              data.getUint64(5) != sequence) {
            throw const FormatException('Invalid backup frame.');
          }
          final encrypted = (await input.read(length + 16))!;
          final clear = await cipher.decrypt(
            SecretBox(
              encrypted.sublist(0, length),
              nonce: [0, 0, 0, 0, ..._number(sequence, 8)],
              mac: Mac(encrypted.sublist(length)),
            ),
            secretKey: key,
            aad: [...header, ...metadata],
          );
          sequence++;
          frameCount++;
          if (type == 1) {
            if (pending.length != 0) {
              throw const FormatException('Incomplete backup record.');
            }
            ended = true;
            continue;
          }
          var start = 0;
          for (var i = 0; i < clear.length; i++) {
            if (clear[i] != 10) continue;
            if (pending.length + i - start + 1 > _maxRecordBytes) {
              throw const FormatException('Backup record exceeds 64 MiB.');
            }
            pending.add(clear.sublist(start, i));
            final record = jsonDecode(utf8.decode(pending.takeBytes()));
            if (record is! Map<String, dynamic>) {
              throw const FormatException('Invalid backup record.');
            }
            yield record;
            start = i + 1;
          }
          if (pending.length + clear.length - start > _maxRecordBytes) {
            throw const FormatException('Backup record exceeds 64 MiB.');
          }
          pending.add(clear.sublist(start));
        }
        if (frameCount == 0) throw const FormatException('Empty backup part.');
      } finally {
        await input.iterator.cancel();
      }
    }
    if (!ended) throw const FormatException('Missing backup end marker.');
  } finally {
    key?.destroy();
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
