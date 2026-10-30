import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// z_stream from the installed zlib.h: Linux LP64, sizeof112.
final class _ZStream extends Struct {
  external Pointer<Uint8> nextIn;
  @Uint32()
  external int availableIn;
  @UnsignedLong()
  external int totalIn;
  external Pointer<Uint8> nextOut;
  @Uint32()
  external int availableOut;
  @UnsignedLong()
  external int totalOut;
  external Pointer<Char> message;
  external Pointer<Void> state;
  external Pointer<Void> allocate;
  external Pointer<Void> release;
  external Pointer<Void> opaque;
  @Int32()
  external int dataType;
  @UnsignedLong()
  external int checksum;
  @UnsignedLong()
  external int reserved;
}

typedef _InitC = Int32 Function(Pointer<_ZStream>, Int32, Pointer<Char>, Int32);
typedef _Init = int Function(Pointer<_ZStream>, int, Pointer<Char>, int);
typedef _StepC = Int32 Function(Pointer<_ZStream>, Int32);
typedef _Step = int Function(Pointer<_ZStream>, int);
typedef _EndC = Int32 Function(Pointer<_ZStream>);
typedef _End = int Function(Pointer<_ZStream>);
typedef _VersionC = Pointer<Char> Function();
typedef _Version = Pointer<Char> Function();

/// Optional query-only inflation. Unsupported/unsuccessful inputs return null
/// for the existing strict managed decoder. No encoder or retained z_stream.
class NativePostingInflate {
  NativePostingInflate._(this.library)
    : _init = library.lookupFunction<_InitC, _Init>('inflateInit2_'),
      _step = library.lookupFunction<_StepC, _Step>('inflate'),
      _end = library.lookupFunction<_EndC, _End>('inflateEnd'),
      _version = library.lookupFunction<_VersionC, _Version>('zlibVersion');
  final DynamicLibrary library;
  final _Init _init;
  final _Step _step;
  final _End _end;
  final _Version _version;
  int successfulInflates = 0;

  static NativePostingInflate? tryCreate() {
    if (!Platform.isLinux ||
        sizeOf<IntPtr>() != 8 ||
        sizeOf<UnsignedLong>() != 8 ||
        sizeOf<_ZStream>() != 112) {
      return null;
    }
    try {
      final decoder = NativePostingInflate._(DynamicLibrary.open('libz.so.1'));
      if (decoder._version().value != 49) return null; // zlib1.x ABI.
      final buffer = calloc<Uint8>(sizeOf<_ZStream>());
      var initialized = false;
      try {
        initialized =
            decoder._init(
              buffer.cast(),
              31,
              decoder._version(),
              sizeOf<_ZStream>(),
            ) ==
            0;
        return initialized ? decoder : null;
      } finally {
        decoder._release(buffer, sizeOf<_ZStream>(), initialized);
      }
    } catch (_) {
      return null;
    }
  }

  Uint8List? decode(Uint8List bytes) {
    if (bytes.length < 18 ||
        bytes.length > 128 * 1024 ||
        bytes[0] != 31 ||
        bytes[1] != 139 ||
        bytes[2] != 8 ||
        bytes[3] != 0) {
      return null;
    }
    final expected = ByteData.sublistView(
      bytes,
    ).getUint32(bytes.length - 4, Endian.little);
    if (expected > 65536) return null;
    final capacity = expected + 1,
        size = sizeOf<_ZStream>() + bytes.length + capacity;
    final buffer = calloc<Uint8>(size);
    var initialized = false;
    try {
      final stream = buffer.cast<_ZStream>();
      final input = buffer + sizeOf<_ZStream>(), output = input + bytes.length;
      input.asTypedList(bytes.length).setAll(0, bytes);
      stream.ref
        ..nextIn = input
        ..availableIn = bytes.length
        ..nextOut = output
        ..availableOut = capacity;
      if (_init(stream, 31, _version(), sizeOf<_ZStream>()) != 0) return null;
      initialized = true;
      // Z_FINISH; only complete, fully consumed single members are successes.
      if (_step(stream, 4) != 1 ||
          stream.ref.availableIn != 0 ||
          stream.ref.totalOut != expected) {
        return null;
      }
      final decoded = Uint8List.fromList(output.asTypedList(expected));
      successfulInflates++;
      return decoded;
    } finally {
      _release(buffer, size, initialized);
    }
  }

  void _release(Pointer<Uint8> buffer, int size, bool initialized) {
    try {
      if (initialized) _end(buffer.cast());
    } finally {
      try {
        buffer.asTypedList(size).fillRange(0, size, 0);
      } finally {
        calloc.free(buffer);
      }
    }
  }
}
