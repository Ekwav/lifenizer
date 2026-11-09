import 'dart:convert';
import 'dart:typed_data';

import 'package:app/services/audio_format.dart';
import 'package:app/services/ogg_opus.dart';
import 'package:app/services/wav_audio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/opus_fixture.dart';

/// Every page of [bytes] as (flags, granule, sequence, lacing, body length).
List<({int flags, int granule, int sequence, List<int> lacing})> pages(
  Uint8List bytes,
) {
  final result = <({int flags, int granule, int sequence, List<int> lacing})>[];
  var offset = 0;
  while (offset < bytes.length) {
    final header = ByteData.sublistView(bytes, offset);
    expect(ascii.decode(bytes.sublist(offset, offset + 4)), 'OggS');
    final count = header.getUint8(26);
    final lacing = bytes.sublist(offset + 27, offset + 27 + count);
    final low = header.getUint32(6, Endian.little);
    final high = header.getInt32(10, Endian.little);
    result.add((
      flags: header.getUint8(5),
      granule: high * 0x100000000 + low,
      sequence: header.getUint32(18, Endian.little),
      lacing: lacing,
    ));
    offset += 27 + count + lacing.fold<int>(0, (sum, value) => sum + value);
  }
  return result;
}

Uint8List packet(int length, [int fill = 7]) =>
    Uint8List(length)..fillRange(0, length, fill);

void main() {
  group('Ogg CRC-32', () {
    test('matches the catalogue check value', () {
      // CRC-32/POSIX check 0x765E7680 without its final xor.
      expect(oggCrc32(Uint8List.fromList('123456789'.codeUnits)), 0x89A1897F);
    });

    test('accepts the checksums of an ffmpeg file', () {
      final stream = OggOpusStream.parse(ffmpegOgg);
      expect(stream.preSkip, 312);
      expect(stream.channels, 1);
      expect(stream.endGranule, 5112);
    });

    test('rejects a corrupted page', () {
      final broken = Uint8List.fromList(ffmpegOgg)..[60] ^= 0x01;
      expect(() => OggOpusStream.parse(broken), throwsFormatException);
    });
  });

  group('OggOpusWriter', () {
    test('writes OpusHead and OpusTags on their own pages', () {
      final ogg = (OggOpusWriter(
        preSkip: 312,
        serial: 9,
      )..addPacket(packet(80))).finish(endGranule: 312 + 900);
      final all = pages(ogg);

      expect(all, hasLength(3));
      expect(all[0].flags, 0x02);
      expect(all[0].granule, 0);
      expect(all[0].lacing, [19]);
      final head = ByteData.sublistView(ogg, 28, 28 + 19);
      expect(ascii.decode(ogg.sublist(28, 36)), 'OpusHead');
      expect(head.getUint8(8), 1);
      expect(head.getUint8(9), 1);
      expect(head.getUint16(10, Endian.little), 312);
      expect(head.getUint32(12, Endian.little), 16000);
      expect(head.getInt16(16, Endian.little), 0);
      expect(head.getUint8(18), 0);
      expect(all[1].flags, 0);
      expect(all[1].granule, 0);
      expect(all[2].flags, 0x04);
      expect(all[2].granule, 1212);
      expect(all.map((p) => p.sequence), [0, 1, 2]);
      expect(RecordingFormat.detect(ogg), RecordingFormat.oggOpus);
    });

    test('groups about one second of packets per page', () {
      final writer = OggOpusWriter(preSkip: 0, serial: 1);
      for (var i = 0; i < 120; i++) {
        writer.addPacket(packet(60));
      }
      final audio = pages(writer.finish(endGranule: 120 * 960)).skip(2);

      expect(audio.map((p) => p.lacing.length), [50, 50, 20]);
      expect(audio.map((p) => p.granule), [50 * 960, 100 * 960, 120 * 960]);
      expect(audio.map((p) => p.flags), [0, 0, 0x04]);
    });

    test('ends a 255-byte packet with a zero-length segment', () {
      final ogg =
          (OggOpusWriter(preSkip: 0, serial: 1)
                ..addPacket(packet(255))
                ..addPacket(packet(3)))
              .finish(endGranule: 1920);

      expect(pages(ogg).last.lacing, [255, 0, 3]);
      final stream = OggOpusStream.parse(ogg);
      expect(stream.packets.map((p) => p.length), [255, 3]);
    });

    test('continues packets longer than one page', () {
      final big = Uint8List.fromList(
        List<int>.generate(255 * 255 + 10, (i) => i % 256),
      );
      final ogg =
          (OggOpusWriter(preSkip: 0, serial: 1)
                ..addPacket(big)
                ..addPacket(packet(5)))
              .finish(endGranule: 1920);
      final audio = pages(ogg).skip(2).toList();

      expect(audio, hasLength(2));
      expect(audio[0].lacing, List.filled(255, 255));
      expect(audio[0].granule, -1, reason: 'no packet ends on this page');
      expect(audio[1].flags, 0x01 | 0x04);
      expect(audio[1].lacing, [10, 5]);
      final stream = OggOpusStream.parse(ogg);
      expect(stream.packets.first, big);
      expect(stream.packets.last, packet(5));
    });

    test('a packet ending exactly at the page limit is not continued', () {
      final ogg =
          (OggOpusWriter(preSkip: 0, serial: 1)
                ..addPacket(packet(255 * 254 + 3))
                ..addPacket(packet(4)))
              .finish(endGranule: 1920);
      final audio = pages(ogg).skip(2).toList();

      expect(audio[0].lacing.length, 255);
      expect(audio[0].granule, 960);
      expect(audio[1].flags, 0x04);
      expect(OggOpusStream.parse(ogg).packets.map((p) => p.length), [
        255 * 254 + 3,
        4,
      ]);
    });
  });

  group('truncated files', () {
    Uint8List threePages() {
      final writer = OggOpusWriter(preSkip: 0, serial: 1, packetsPerPage: 2);
      for (var i = 0; i < 6; i++) {
        writer.addPacket(packet(40, i));
      }
      return writer.finish(endGranule: 6 * 960);
    }

    test('stop at a page cut off mid-write', () {
      final ogg = threePages();
      final cut = Uint8List.sublistView(ogg, 0, ogg.length - 30);
      final stream = OggOpusStream.parse(cut);
      expect(stream.packets, hasLength(4));
      expect(stream.endGranule, 4 * 960, reason: 'from complete pages only');
    });

    test('stop at a header cut off mid-write', () {
      final ogg = threePages();
      final lastPage = ogg.length - (27 + 2 + 80);
      final cut = Uint8List.sublistView(ogg, 0, lastPage + 10);
      expect(OggOpusStream.parse(cut).packets, hasLength(4));
    });
  });

  group('opusPacketSamples48k', () {
    test('reads the frame size and count from the TOC byte', () {
      expect(opusPacketSamples48k(Uint8List(0)), 0);
      // config 31 (CELT 20 ms), one frame.
      expect(opusPacketSamples48k(Uint8List.fromList([0xF8])), 960);
      // config 1 (SILK 20 ms), two frames.
      expect(opusPacketSamples48k(Uint8List.fromList([0x09])), 1920);
      // config 15 (hybrid 20 ms), code 3 with 3 frames.
      expect(opusPacketSamples48k(Uint8List.fromList([0x7B, 0x03])), 2880);
      // config 16 (CELT 2.5 ms), one frame.
      expect(opusPacketSamples48k(Uint8List.fromList([0x80])), 120);
      // config 3 (SILK 60 ms), one frame.
      expect(opusPacketSamples48k(Uint8List.fromList([0x18])), 2880);
    });
  });

  group('decode window', () {
    // 100 CELT packets of 20 ms: 2 s at 48 kHz.
    OggOpusStream stream({int preSkip = 312, int? endGranule}) => OggOpusStream(
      preSkip: preSkip,
      channels: 1,
      packets: List.generate(100, (_) => Uint8List.fromList([0xF8])),
      endGranule: endGranule,
    );

    test('starts 500 ms before the clip and skips the pre-skip', () {
      final window = OpusDecodeWindow.plan(
        stream(endGranule: 312 + 90000),
        start: 16000,
        end: 24000,
      );
      // Seek to 312 + 48000 - 24000 = 24312 at 48 kHz: packet 25 starts at
      // 24000 and ends after it.
      expect(window.firstPacket, 25);
      expect(window.decodeFrom, 8000);
      expect(window.outputFrom, 104 + 16000);
      expect(window.samples, 8000);
    });

    test('trims to the end granule and clamps the request', () {
      final window = OpusDecodeWindow.plan(
        stream(endGranule: 312 + 90000),
        start: 0,
        end: 1 << 30,
      );
      expect(window.firstPacket, 0);
      expect(window.samples, 30000);
    });

    test('ignores an end granule below the pre-skip', () {
      final bogus = stream(endGranule: 100);
      expect(trustedPlayable48k(bogus, List.filled(100, 960)), 96000 - 312);
      expect(OpusDecodeWindow.plan(bogus).samples, (96000 - 312) ~/ 3);
    });

    test('ignores an end granule far below the decoded length', () {
      final bogus = stream(endGranule: 312 + 960);
      expect(OpusDecodeWindow.plan(bogus).samples, (96000 - 312) ~/ 3);
    });

    test('ignores an end granule beyond the decoded length', () {
      final bogus = stream(endGranule: 1 << 40);
      expect(OpusDecodeWindow.plan(bogus).samples, (96000 - 312) ~/ 3);
    });

    test('uses the packets when there is no granule', () {
      expect(OpusDecodeWindow.plan(stream()).samples, (96000 - 312) ~/ 3);
    });
  });

  test('the default serial is random and 32-bit', () {
    final serials = {
      for (var i = 0; i < 8; i++)
        ByteData.sublistView(
          OggOpusWriter(preSkip: 0).finish(endGranule: 0),
        ).getUint32(14, Endian.little),
    };
    expect(serials.length, greaterThan(1));
  });

  group('RecordingFormat.detect', () {
    test('recognizes WAV, Ogg Opus and nothing else', () {
      expect(
        RecordingFormat.detect(encodeWav(Uint8List(4))),
        RecordingFormat.wav,
      );
      expect(RecordingFormat.detect(ffmpegOgg), RecordingFormat.oggOpus);
      expect(RecordingFormat.detect([1, 2, 3]), isNull);
      final vorbis = Uint8List.fromList(ffmpegOgg)
        ..setAll(28, '\x01vorbis\x00'.codeUnits);
      expect(RecordingFormat.detect(vorbis), isNull);
      expect(RecordingFormat.oggOpus.contentType, 'audio/ogg');
      expect(RecordingFormat.oggOpus.fileName, 'recording.ogg');
    });
  });
}
