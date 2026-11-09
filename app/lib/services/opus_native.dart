import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ogg_opus.dart';
import 'wav_audio.dart';

// libopus is a real shared library in every native build: flutter_soloud
// links it (Android bundles libopus.so, Linux uses the system libopus.so.0 or
// its bundled copy). We bind only its public, versioned API.

typedef _EncoderCreateC =
    Pointer<Void> Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _EncoderCreate = Pointer<Void> Function(int, int, int, Pointer<Int32>);
typedef _EncodeC =
    Int32 Function(Pointer<Void>, Pointer<Int16>, Int32, Pointer<Uint8>, Int32);
typedef _Encode =
    int Function(Pointer<Void>, Pointer<Int16>, int, Pointer<Uint8>, int);
typedef _CtlIntC = Int32 Function(Pointer<Void>, Int32, VarArgs<(Int32,)>);
typedef _CtlInt = int Function(Pointer<Void>, int, int);
typedef _CtlPointerC =
    Int32 Function(Pointer<Void>, Int32, VarArgs<(Pointer<Int32>,)>);
typedef _CtlPointer = int Function(Pointer<Void>, int, Pointer<Int32>);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _Destroy = void Function(Pointer<Void>);
typedef _DecoderCreateC = Pointer<Void> Function(Int32, Int32, Pointer<Int32>);
typedef _DecoderCreate = Pointer<Void> Function(int, int, Pointer<Int32>);
typedef _DecodeC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Int32,
      Pointer<Int16>,
      Int32,
      Int32,
    );
typedef _Decode =
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Int16>, int, int);

const _applicationVoip = 2048;
const _setBitrate = 4002;
const _setVbr = 4006;
const _getLookahead = 4027;

/// 16 kHz mono, 20 ms frames, 32 kbps VBR: about 7 MB for 30 minutes.
const opusSampleRate = 16000;
const opusFrameSamples = 320;
const opusBitrate = 32000;
const _maxPacketBytes = 1500;
const _maxDecodedSamples = 1920; // 120 ms at 16 kHz.

class OpusLibrary {
  OpusLibrary._(DynamicLibrary library)
    : _encoderCreate = library.lookupFunction<_EncoderCreateC, _EncoderCreate>(
        'opus_encoder_create',
      ),
      _encode = library.lookupFunction<_EncodeC, _Encode>('opus_encode'),
      _ctlInt = library.lookupFunction<_CtlIntC, _CtlInt>('opus_encoder_ctl'),
      _ctlPointer = library.lookupFunction<_CtlPointerC, _CtlPointer>(
        'opus_encoder_ctl',
      ),
      _encoderDestroy = library.lookupFunction<_DestroyC, _Destroy>(
        'opus_encoder_destroy',
      ),
      _decoderCreate = library.lookupFunction<_DecoderCreateC, _DecoderCreate>(
        'opus_decoder_create',
      ),
      _decode = library.lookupFunction<_DecodeC, _Decode>('opus_decode'),
      _decoderDestroy = library.lookupFunction<_DestroyC, _Destroy>(
        'opus_decoder_destroy',
      );

  final _EncoderCreate _encoderCreate;
  final _Encode _encode;
  final _CtlInt _ctlInt;
  final _CtlPointer _ctlPointer;
  final _Destroy _encoderDestroy;
  final _DecoderCreate _decoderCreate;
  final _Decode _decode;
  final _Destroy _decoderDestroy;

  /// Null when no usable libopus is installed on this platform.
  static OpusLibrary? tryOpen(List<String> names) {
    if (!Platform.isLinux && !Platform.isAndroid) return null;
    for (final name in names) {
      try {
        return OpusLibrary._(DynamicLibrary.open(name));
      } on ArgumentError {
        continue;
      }
    }
    return null;
  }

  /// Encodes 16 kHz mono PCM16 (little-endian) into an Ogg Opus file.
  Uint8List encodeOggOpus(Uint8List pcm) {
    final encoder = _OpusEncoder.open(this);
    try {
      return encoder.encode(pcm);
    } finally {
      encoder.dispose();
    }
  }

  /// Decodes output samples [start, end) of an Ogg Opus file into a 16 kHz
  /// mono WAV, skipping packets before the window (with Opus' pre-roll).
  Uint8List decodeOggOpusWav(Uint8List ogg, {int start = 0, int? end}) {
    final stream = OggOpusStream.parse(ogg);
    final window = OpusDecodeWindow.plan(stream, start: start, end: end);
    final decoder = _OpusDecoder.open(this);
    try {
      return decoder.decodeWindow(stream, window);
    } finally {
      decoder.dispose();
    }
  }
}

class _OpusEncoder {
  _OpusEncoder._(this._opus, this._state, this._input, this._output);

  /// Native memory is only allocated once the encoder is fully configured.
  static _OpusEncoder open(OpusLibrary opus) {
    final state = _createEncoder(opus);
    try {
      _configure(opus, state);
    } catch (_) {
      opus._encoderDestroy(state);
      rethrow;
    }
    return _OpusEncoder._(
      opus,
      state,
      calloc<Int16>(opusFrameSamples),
      calloc<Uint8>(_maxPacketBytes),
    );
  }

  static Pointer<Void> _createEncoder(OpusLibrary opus) => using((arena) {
    final error = arena<Int32>();
    final state = opus._encoderCreate(
      opusSampleRate,
      1,
      _applicationVoip,
      error,
    );
    if (error.value != 0 || state == nullptr) {
      throw StateError('Opus encoder failed (${error.value}).');
    }
    return state;
  });

  static void _configure(OpusLibrary opus, Pointer<Void> state) {
    for (final (request, value) in [(_setBitrate, opusBitrate), (_setVbr, 1)]) {
      if (opus._ctlInt(state, request, value) != 0) {
        throw StateError('Opus setting $request failed.');
      }
    }
  }

  final OpusLibrary _opus;
  final Pointer<Void> _state;
  final Pointer<Int16> _input;
  final Pointer<Uint8> _output;

  int get _lookahead => using((arena) {
    final value = arena<Int32>();
    if (_opus._ctlPointer(_state, _getLookahead, value) != 0) {
      throw StateError('Opus lookahead unavailable.');
    }
    return value.value;
  });

  Uint8List encode(Uint8List pcm) {
    final lookahead = _lookahead;
    final scale = opusGranuleRate ~/ opusSampleRate;
    final writer = OggOpusWriter(preSkip: lookahead * scale);
    final samples = pcm.length ~/ 2;
    // Feed the encoder delay as silence so the last real samples come out.
    final total = samples + lookahead;
    for (var start = 0; start < total; start += opusFrameSamples) {
      writer.addPacket(_encodeFrame(pcm, start, samples));
    }
    return writer.finish(endGranule: (lookahead + samples) * scale);
  }

  Uint8List _encodeFrame(Uint8List pcm, int start, int samples) {
    final frame = _input.asTypedList(opusFrameSamples)
      ..fillRange(0, opusFrameSamples, 0);
    final count = (samples - start).clamp(0, opusFrameSamples);
    if (count > 0) {
      final view = ByteData.sublistView(pcm, start * 2, (start + count) * 2);
      for (var i = 0; i < count; i++) {
        frame[i] = view.getInt16(i * 2, Endian.little);
      }
    }
    final length = _opus._encode(
      _state,
      _input,
      opusFrameSamples,
      _output,
      _maxPacketBytes,
    );
    if (length < 0) throw StateError('Opus encoding failed ($length).');
    return Uint8List.fromList(_output.asTypedList(length));
  }

  void dispose() {
    _opus._encoderDestroy(_state);
    calloc.free(_input);
    calloc.free(_output);
  }
}

class _OpusDecoder {
  _OpusDecoder._(this._opus, this._state, this._output);

  /// Native memory is only allocated once the decoder exists.
  static _OpusDecoder open(OpusLibrary opus) {
    final state = using((arena) {
      final error = arena<Int32>();
      // A mono decoder also downmixes stereo streams.
      final state = opus._decoderCreate(opusSampleRate, 1, error);
      if (error.value != 0 || state == nullptr) {
        throw StateError('Opus decoder failed (${error.value}).');
      }
      return state;
    });
    return _OpusDecoder._(opus, state, calloc<Int16>(_maxDecodedSamples));
  }

  final OpusLibrary _opus;
  final Pointer<Void> _state;
  final Pointer<Int16> _output;
  Pointer<Uint8> _packet = nullptr;
  int _packetCapacity = 0;

  /// Writes the window straight into a preallocated WAV.
  Uint8List decodeWindow(OggOpusStream stream, OpusDecodeWindow window) {
    final wav = wavBuffer(window.samples);
    final out = _WavWriter(wav, window);
    var position = window.decodeFrom;
    final packets = stream.packets;
    for (var i = window.firstPacket; i < packets.length && !out.full; i++) {
      final decoded = _decodePacket(packets[i]);
      out.write(decoded, position);
      position += decoded.length;
    }
    return out.full ? wav : truncateWav(wav, out.written);
  }

  Int16List _decodePacket(Uint8List packet) {
    _reserve(packet.length);
    _packet.asTypedList(packet.length).setAll(0, packet);
    final count = _opus._decode(
      _state,
      _packet,
      packet.length,
      _output,
      _maxDecodedSamples,
      0,
    );
    if (count < 0) throw FormatException('Opus decoding failed ($count).');
    return _output.asTypedList(count);
  }

  void _reserve(int length) {
    if (length <= _packetCapacity) return;
    if (_packet != nullptr) calloc.free(_packet);
    _packetCapacity = length;
    _packet = calloc<Uint8>(length);
  }

  void dispose() {
    _opus._decoderDestroy(_state);
    calloc.free(_output);
    if (_packet != nullptr) calloc.free(_packet);
  }
}

/// Copies the part of each decoded packet that falls inside the window.
class _WavWriter {
  _WavWriter(Uint8List wav, this.window) : _data = ByteData.sublistView(wav);
  final OpusDecodeWindow window;
  final ByteData _data;
  int written = 0;

  bool get full => written >= window.samples;

  /// [position] is the decoded-sample index of `decoded[0]`.
  void write(Int16List decoded, int position) {
    final skipped = (window.outputFrom + written - position).clamp(
      0,
      decoded.length,
    );
    final wanted = window.samples - written;
    final count = (decoded.length - skipped).clamp(0, wanted);
    for (var i = 0; i < count; i++) {
      _data.setInt16(
        44 + (written + i) * 2,
        decoded[skipped + i],
        Endian.little,
      );
    }
    written += count;
  }
}
