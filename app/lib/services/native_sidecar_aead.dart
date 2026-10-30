import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ffi/ffi.dart';
import 'package:sodium/sodium.ffi.dart';

/// Optional Linux accelerator for the existing nonce/tag/ciphertext envelope.
class NativeSidecarAead {
  NativeSidecarAead._(this._key);
  static const _lib = LibSodiumFFI();
  SodiumPointer<UnsignedChar>? _key;

  static NativeSidecarAead? tryCreate(List<int> bytes) {
    if (!Platform.isLinux) return null;
    if (bytes.length != 32) throw ArgumentError('Invalid device key.');
    SodiumPointer<UnsignedChar>? key;
    try {
      if (_lib.sodium_init() < 0 ||
          _lib.crypto_aead_aes256gcm_is_available() != 1) {
        return null;
      }
      key = SodiumPointer<UnsignedChar>.alloc(_lib, count: 32);
      key.fill(bytes);
      key.memoryProtection = MemoryProtection.noAccess;
      return NativeSidecarAead._(key);
    } catch (_) {
      key?.dispose();
      return null; // Missing library, unsupported CPU or failed initialization.
    }
  }

  Uint8List encrypt(
    List<int> plain,
    List<int> nonce, {
    List<int> aad = const [],
  }) {
    final key = _key ?? (throw StateError('The native key is disposed.'));
    if (nonce.length != 12) throw ArgumentError('Invalid nonce.');
    final size = 28 + 2 * plain.length + aad.length;
    final buffer = calloc<UnsignedChar>(size);
    try {
      final view = buffer.cast<Uint8>().asTypedList(size);
      view.setRange(0, 12, nonce);
      view.setRange(28 + plain.length, 28 + 2 * plain.length, plain);
      view.setRange(28 + 2 * plain.length, size, aad);
      key.memoryProtection = MemoryProtection.readOnly;
      try {
        final status = _lib.crypto_aead_aes256gcm_encrypt_detached(
          buffer + 28,
          buffer + 12,
          nullptr,
          buffer + 28 + plain.length,
          plain.length,
          buffer + 28 + 2 * plain.length,
          aad.length,
          nullptr,
          buffer,
          key.ptr,
        );
        if (status != 0) throw StateError('Native AES-GCM encryption failed.');
        return Uint8List.fromList(
          Uint8List.sublistView(view, 0, 28 + plain.length),
        );
      } finally {
        key.memoryProtection = MemoryProtection.noAccess;
      }
    } finally {
      try {
        _lib.sodium_memzero(buffer.cast(), size);
      } finally {
        calloc.free(buffer);
      }
    }
  }

  Uint8List decrypt(Uint8List packed, {List<int> aad = const []}) =>
      _decryptRow(
        packed,
        aad,
        _key ?? (throw StateError('The native key is disposed.')),
      );

  /// Synchronous bounded batch; each row keeps its own wiped native scratch.
  /// The caller uses [decrypt] for an individual payload larger than 4 MiB.
  List<Uint8List> decryptMany(
    List<Uint8List> packed, {
    List<int> aad = const [],
  }) {
    if (packed.length > 512) {
      throw ArgumentError('At most 512 payloads per batch.');
    }
    final inputs = List<Uint8List>.of(packed, growable: false);
    if (inputs.length > 512) {
      throw ArgumentError('At most 512 payloads per batch.');
    }
    final authenticatedData = Uint8List.fromList(aad);
    var bytes = 0;
    for (final row in inputs) {
      bytes += row.length;
      if (bytes > 4 * 1024 * 1024) {
        throw ArgumentError('At most 4 MiB of packed bytes per batch.');
      }
    }
    final key = _key ?? (throw StateError('The native key is disposed.'));
    final outputs = List<Uint8List>.filled(inputs.length, Uint8List(0));
    key.memoryProtection = MemoryProtection.readOnly;
    try {
      for (var i = 0; i < inputs.length; i++) {
        outputs[i] = _decryptRow(
          inputs[i],
          authenticatedData,
          key,
          guardKey: false,
        );
      }
      return outputs;
    } catch (_) {
      for (final output in outputs) {
        output.fillRange(0, output.length, 0);
      }
      rethrow;
    } finally {
      key.memoryProtection = MemoryProtection.noAccess;
    }
  }

  Uint8List _decryptRow(
    Uint8List packed,
    List<int> aad,
    SodiumPointer<UnsignedChar> key, {
    bool guardKey = true,
  }) {
    RangeError.checkNotNegative(packed.length - 28, 'ciphertext length');
    final length = packed.length - 28;
    final size = packed.length + length + aad.length;
    final buffer = calloc<UnsignedChar>(size);
    try {
      final view = buffer.cast<Uint8>().asTypedList(size);
      view.setRange(0, packed.length, packed);
      view.setRange(packed.length + length, size, aad);
      if (guardKey) key.memoryProtection = MemoryProtection.readOnly;
      try {
        final status = _lib.crypto_aead_aes256gcm_decrypt_detached(
          buffer + packed.length,
          nullptr,
          buffer + 28,
          length,
          buffer + 12,
          buffer + packed.length + length,
          aad.length,
          buffer,
          key.ptr,
        );
        if (status != 0) throw SecretBoxAuthenticationError();
        return Uint8List.fromList(
          (buffer + packed.length).cast<Uint8>().asTypedList(length),
        );
      } finally {
        if (guardKey) key.memoryProtection = MemoryProtection.noAccess;
      }
    } finally {
      try {
        _lib.sodium_memzero(buffer.cast(), size);
      } finally {
        calloc.free(buffer);
      }
    }
  }

  void dispose() {
    final key = _key;
    _key = null;
    if (key == null) return;
    try {
      key.memoryProtection = MemoryProtection.readWrite;
      key.zeroMemory();
    } finally {
      key.dispose();
    }
  }
}
