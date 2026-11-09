import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Granule positions of Ogg Opus are always in 48 kHz samples (RFC 7845).
const opusGranuleRate = 48000;

/// Writes one mono Ogg Opus stream (RFC 7845) from raw Opus packets.
class OggOpusWriter {
  OggOpusWriter({
    required this.preSkip,
    this.inputSampleRate = 16000,
    this.packetsPerPage = 50,
    int? serial,
  }) : _pages = _OggPager(serial ?? _randomSerial()) {
    _pages.addPacket(opusHead(preSkip, inputSampleRate), granule: 0);
    _pages.flush();
    _pages.addPacket(opusTags(), granule: 0);
    _pages.flush();
  }

  /// Encoder delay in 48 kHz samples; decoders drop this many samples.
  final int preSkip;
  final int inputSampleRate;

  /// About one second of 20 ms packets per page.
  final int packetsPerPage;
  final _OggPager _pages;
  int _granule = 0;

  /// Adds a packet that decodes to [samples48k] samples.
  void addPacket(Uint8List packet, {int samples48k = 960}) {
    if (_pages.completedPackets >= packetsPerPage) _pages.flush();
    _granule += samples48k;
    _pages.addPacket(packet, granule: _granule);
  }

  /// Ends the stream. [endGranule] trims the padding of the last packet:
  /// pre-skip plus the real sample count, in 48 kHz units.
  Uint8List finish({required int endGranule}) {
    _pages.flush(endOfStream: true, granuleOverride: endGranule);
    return _pages.takeBytes();
  }
}

// nextInt(1 << 32) fails on dart2js, where 1 << 32 is 0.
int _randomSerial() {
  final random = math.Random.secure();
  return random.nextInt(0x10000) << 16 | random.nextInt(0x10000);
}

Uint8List opusHead(int preSkip, int inputSampleRate) {
  final head = ByteData(19);
  final bytes = head.buffer.asUint8List()..setAll(0, ascii.encode('OpusHead'));
  head.setUint8(8, 1); // version
  head.setUint8(9, 1); // channels
  head.setUint16(10, preSkip, Endian.little);
  head.setUint32(12, inputSampleRate, Endian.little);
  head.setInt16(16, 0, Endian.little); // output gain
  head.setUint8(18, 0); // mapping family: mono/stereo
  return bytes;
}

Uint8List opusTags([String vendor = 'Lifenizer']) {
  final vendorBytes = utf8.encode(vendor);
  final tags = ByteData(8 + 4 + vendorBytes.length + 4);
  final bytes = tags.buffer.asUint8List()..setAll(0, ascii.encode('OpusTags'));
  tags.setUint32(8, vendorBytes.length, Endian.little);
  bytes.setAll(12, vendorBytes);
  tags.setUint32(12 + vendorBytes.length, 0, Endian.little); // no comments
  return bytes;
}

/// Splits packets into pages with 255-lacing; a packet may span pages.
class _OggPager {
  _OggPager(this.serial);
  final int serial;
  final _out = BytesBuilder(copy: false);
  final _lacing = <int>[];
  final _body = BytesBuilder(copy: false);
  int _sequence = 0;
  int _granule = -1;
  bool _continued = false;
  int completedPackets = 0;

  void addPacket(Uint8List packet, {required int granule}) {
    var offset = 0;
    while (packet.length - offset >= 255) {
      _addSegment(packet, offset, 255);
      offset += 255;
    }
    // Always end with a segment below 255 bytes, possibly empty.
    _addSegment(packet, offset, packet.length - offset);
    _granule = granule;
    completedPackets++;
  }

  void _addSegment(Uint8List packet, int offset, int length) {
    if (_lacing.length == 255) {
      flush();
      _continued = offset > 0;
    }
    _lacing.add(length);
    _body.add(Uint8List.sublistView(packet, offset, offset + length));
  }

  void flush({bool endOfStream = false, int? granuleOverride}) {
    final flags =
        (_continued ? 0x01 : 0) |
        (_sequence == 0 ? 0x02 : 0) |
        (endOfStream ? 0x04 : 0);
    _out.add(
      oggPage(
        flags: flags,
        granule: granuleOverride ?? _granule,
        serial: serial,
        sequence: _sequence++,
        lacing: _lacing,
        body: _body.takeBytes(),
      ),
    );
    _lacing.clear();
    _granule = -1;
    _continued = false;
    completedPackets = 0;
  }

  Uint8List takeBytes() => _out.takeBytes();
}

/// One Ogg page; a granule of -1 means no packet ends on it.
Uint8List oggPage({
  required int flags,
  required int granule,
  required int serial,
  required int sequence,
  required List<int> lacing,
  required Uint8List body,
}) {
  final headerLength = 27 + lacing.length;
  final page = Uint8List(headerLength + body.length);
  final header = ByteData.sublistView(page);
  page.setAll(0, ascii.encode('OggS'));
  header.setUint8(5, flags);
  _setGranule(header, granule);
  header.setUint32(14, serial, Endian.little);
  header.setUint32(18, sequence, Endian.little);
  header.setUint8(26, lacing.length);
  page.setAll(27, lacing);
  page.setAll(headerLength, body);
  header.setUint32(22, oggCrc32(page), Endian.little);
  return page;
}

// Two 32-bit halves: dart2js has no 64-bit ByteData accessors.
void _setGranule(ByteData header, int granule) {
  final unset = granule == -1;
  header.setUint32(6, unset ? 0xFFFFFFFF : granule & 0xFFFFFFFF, Endian.little);
  header.setUint32(
    10,
    unset ? 0xFFFFFFFF : granule ~/ 0x100000000,
    Endian.little,
  );
}

int _granuleOf(ByteData header) {
  final low = header.getUint32(6, Endian.little);
  final high = header.getUint32(10, Endian.little);
  if (low == 0xFFFFFFFF && high == 0xFFFFFFFF) return -1;
  return high * 0x100000000 + low;
}

/// Ogg's CRC-32: polynomial 0x04C11DB7, initial 0, not reflected, no xor.
int oggCrc32(Uint8List data) {
  var crc = 0;
  for (final byte in data) {
    crc = ((crc << 8) & 0xFFFFFFFF) ^ _crcTable[((crc >> 24) ^ byte) & 0xFF];
  }
  return crc;
}

final _crcTable = Uint32List.fromList(
  List<int>.generate(256, (index) {
    var value = index << 24;
    for (var bit = 0; bit < 8; bit++) {
      final shifted = (value << 1) & 0xFFFFFFFF;
      value = value & 0x80000000 != 0 ? shifted ^ 0x04C11DB7 : shifted;
    }
    return value;
  }),
);

/// The packets of the first logical stream of an Ogg Opus file.
class OggOpusStream {
  OggOpusStream({
    required this.preSkip,
    required this.channels,
    required this.packets,
    required this.endGranule,
  });

  final int preSkip;
  final int channels;

  /// Audio packets, without the OpusHead and OpusTags headers.
  final List<Uint8List> packets;

  /// Granule of the last page: pre-skip plus playable samples at 48 kHz.
  final int? endGranule;

  static OggOpusStream parse(Uint8List bytes) {
    final reader = _OggReader(bytes)..read();
    final packets = reader.packets;
    if (packets.length < 2) throw const FormatException('Ogg Opus is empty.');
    final head = packets.first;
    if (head.length < 19 || ascii.decode(head.sublist(0, 8)) != 'OpusHead') {
      throw const FormatException('The Ogg stream is not Opus.');
    }
    final fields = ByteData.sublistView(head);
    return OggOpusStream(
      preSkip: fields.getUint16(10, Endian.little),
      channels: fields.getUint8(9),
      packets: packets.sublist(2),
      endGranule: reader.lastGranule,
    );
  }
}

/// Reads pages of the first serial number and rebuilds their packets.
class _OggReader {
  _OggReader(this.bytes);
  final Uint8List bytes;
  final packets = <Uint8List>[];
  final _partial = BytesBuilder(copy: false);
  int? _serial;
  int? lastGranule;

  /// Stops at a page cut off by an interrupted write; what came before it
  /// stays usable.
  void read() {
    int? offset = 0;
    while (offset != null && offset + 27 <= bytes.length) {
      offset = _readPage(offset);
    }
  }

  /// The offset of the next page, or null if this one is truncated.
  int? _readPage(int offset) {
    final header = ByteData.sublistView(bytes, offset);
    if (ascii.decode(bytes.sublist(offset, offset + 4)) != 'OggS') {
      throw const FormatException('Broken Ogg page.');
    }
    final segments = header.getUint8(26);
    final bodyStart = offset + 27 + segments;
    if (bodyStart > bytes.length) return null;
    final lacing = Uint8List.sublistView(bytes, offset + 27, bodyStart);
    final bodyLength = lacing.fold<int>(0, (sum, value) => sum + value);
    final end = bodyStart + bodyLength;
    if (end > bytes.length) return null;
    _checkCrc(offset, end, header.getUint32(22, Endian.little));
    final serial = header.getUint32(14, Endian.little);
    _serial ??= serial;
    if (serial == _serial) {
      _collect(lacing, bodyStart);
      final granule = _granuleOf(header);
      if (granule != -1) lastGranule = granule;
    }
    return end;
  }

  void _checkCrc(int start, int end, int expected) {
    final page = Uint8List.fromList(bytes.sublist(start, end));
    page.fillRange(22, 26, 0);
    if (oggCrc32(page) != expected) {
      throw const FormatException('Ogg page checksum mismatch.');
    }
  }

  void _collect(Uint8List lacing, int bodyStart) {
    var position = bodyStart;
    for (final length in lacing) {
      _partial.add(Uint8List.sublistView(bytes, position, position + length));
      position += length;
      if (length < 255) packets.add(_partial.takeBytes());
    }
  }
}

/// Samples (at 48 kHz) one Opus packet decodes to, from its TOC byte
/// (RFC 6716, section 3.1). Zero for an empty or malformed packet.
int opusPacketSamples48k(Uint8List packet) {
  if (packet.isEmpty) return 0;
  final toc = packet[0];
  final frames = switch (toc & 0x03) {
    0 => 1,
    1 || 2 => 2,
    _ => packet.length > 1 ? packet[1] & 0x3F : 0,
  };
  return frames * _frameSamples48k(toc >> 3);
}

int _frameSamples48k(int config) {
  if (config < 12) return const [480, 960, 1920, 2880][config % 4]; // SILK
  if (config < 16) return const [480, 960][config % 2]; // hybrid
  return const [120, 240, 480, 960][config % 4]; // CELT
}

/// RFC 7845 (4.6) asks for at least 80 ms of decoding before a seek point;
/// SILK speech needs about 300 ms to match a full decode, so we use 500 ms.
const _preRoll48k = 24000;

/// Which packets to decode for output samples [start, end) at [rate], with
/// the pre-skip removed and the end trimmed to the playable length.
class OpusDecodeWindow {
  OpusDecodeWindow._({
    required this.firstPacket,
    required this.decodeFrom,
    required this.outputFrom,
    required this.samples,
  });

  /// Index into [OggOpusStream.packets] where decoding starts.
  final int firstPacket;

  /// Decoded-sample index (pre-skip included) of that packet's first sample.
  final int decodeFrom;

  /// Decoded-sample index of the first output sample.
  final int outputFrom;

  /// Exact number of output samples.
  final int samples;

  static OpusDecodeWindow plan(
    OggOpusStream stream, {
    int rate = 16000,
    int start = 0,
    int? end,
  }) {
    final scale = opusGranuleRate ~/ rate;
    final durations = stream.packets.map(opusPacketSamples48k).toList();
    final playable = trustedPlayable48k(stream, durations) ~/ scale;
    final from = start.clamp(0, playable);
    final to = (end ?? playable).clamp(from, playable);
    final seekTo = stream.preSkip + from * scale - _preRoll48k;
    var first = 0;
    var position = 0;
    while (first < durations.length && position + durations[first] <= seekTo) {
      position += durations[first++];
    }
    return OpusDecodeWindow._(
      firstPacket: first,
      decodeFrom: position ~/ scale,
      outputFrom: stream.preSkip ~/ scale + from,
      samples: to - from,
    );
  }
}

/// A trimmed end granule may cut at most one packet's padding; a granule far
/// below what the packets decode to (or below the pre-skip) is ignored.
int trustedPlayable48k(OggOpusStream stream, List<int> durations) {
  final decoded = durations.fold<int>(0, (sum, value) => sum + value);
  final available = math.max(0, decoded - stream.preSkip);
  final granule = stream.endGranule;
  if (granule == null) return available;
  final claimed = granule - stream.preSkip;
  final plausible = claimed >= 0 && claimed >= available - opusGranuleRate;
  return plausible ? math.min(claimed, available) : available;
}
