import 'dart:math';
import 'dart:typed_data';

import 'package:app/services/search_posting_positions.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bitmap(Iterable<int> documents) {
  final result = Uint8List(128);
  for (final document in documents) {
    result[document >> 3] |= 1 << (document & 7);
  }
  return result;
}

void main() {
  test(
    'v5 boosts and score visitor preserve the v4 byte format by default',
    () {
      final bits = bitmap([0, 7]);
      final positions = <int, List<int>>{
        0: [0, 127, 128],
        7: [2],
      };
      final boosts = <int, int>{0: 18, 7: 0};
      final legacy = encodePostingPositions(bits, positions);
      expect(legacy, [3, 0, 127, 1, 1, 2]);
      final encoded = encodePostingPositions(
        bits,
        positions,
        fieldBoosts: boosts,
      );
      expect(encoded, [3, 18, 0, 127, 1, 1, 0, 2]);
      final decodedBoosts = <int, int>{};
      expect(
        decodePostingPositions(
          bits,
          encoded,
          hasFieldBoosts: true,
          fieldBoosts: decodedBoosts,
        ),
        positions,
      );
      expect(decodedBoosts, boosts);
      final events = <String>[];
      visitPostingPositions(
        bits,
        encoded,
        (document, values) {
          events.add('positions:$document');
        },
        hasFieldBoosts: true,
        onFieldBoost: (document, boost) {
          events.add('boost:$document:$boost');
        },
        include: (document) => document == 7,
      );
      expect(events, ['boost:7:0', 'positions:7']);
      final scores = <int, (int, int)>{};
      visitPostingScores(bits, encoded, (document, tf, boost) {
        scores[document] = (tf, boost);
      });
      expect(scores, {0: (3, 18), 7: (1, 0)});
      scores.clear();
      visitPostingScores(
        bits,
        legacy,
        (document, tf, boost) {
          scores[document] = (tf, boost);
        },
        hasFieldBoosts: false,
        include: (document) => document == 0,
      );
      expect(scores, {0: (3, 0)});
    },
  );

  test('v5 rejects invalid boosts and validates skipped position streams', () {
    final bits = bitmap([0]);
    for (final boosts in <Map<int, int>>[
      {},
      {0: -1},
      {0: 19},
      {1: 4},
      {0: 4, 1: 0},
    ]) {
      expect(
        () => encodePostingPositions(bits, {
          0: [0],
        }, fieldBoosts: boosts),
        throwsFormatException,
      );
    }
    for (final values in <List<int>>[
      [],
      [0, 0],
      [1],
      [1, 0],
      [1, 19, 0],
      [1, 128, 0, 0],
      [1, 255, 255, 255, 255, 15, 0],
      [1, 4, 0, 0],
      [2, 18, 0],
      [2, 4, 127, 0],
      [2, 4, 255, 255, 255, 255, 15, 1],
      [255, 255, 255, 255, 15, 4, 0],
    ]) {
      final payload = Uint8List.fromList(values);
      for (final selected in [true, false]) {
        expect(
          () => visitPostingScores(
            bits,
            payload,
            (_, _, _) {},
            include: (_) => selected,
          ),
          throwsFormatException,
          reason: '$values',
        );
        expect(
          () => visitPostingPositions(
            bits,
            payload,
            (_, _) {},
            hasFieldBoosts: true,
            include: (_) => selected,
          ),
          throwsFormatException,
          reason: '$values',
        );
      }
    }
  });

  test(
    'round trips sparse positions across document and varint boundaries',
    () {
      final positions = <int, List<int>>{
        0: [0, 127, 128, 16383, 16384],
        7: [0],
        8: [128],
        127: [1, 2, 3],
        128: [0xfffffffe, 0xffffffff],
        1023: [0xffffffff],
      };
      final bits = bitmap(positions.keys);
      final encoded = encodePostingPositions(bits, positions);
      expect(decodePostingPositions(bits, encoded), positions);
      final visited = <int, List<int>>{};
      visitPostingPositions(bits, encoded, (document, values) {
        visited[document] = values;
      });
      expect(visited, positions);
      visited.clear();
      visitPostingPositions(bits, encoded, (document, values) {
        visited[document] = values;
      }, include: (document) => document == 128);
      expect(visited, {128: positions[128]});
      expect(encodePostingPositions(Uint8List(128), {}), isEmpty);
      expect(decodePostingPositions(Uint8List(128), Uint8List(0)), isEmpty);
    },
  );

  test('partial document updates preserve the rest of a posting page', () {
    final random = Random(42);
    final positions = <int, List<int>>{
      for (var document = 0; document < 1024; document++)
        if (random.nextBool()) document: [random.nextInt(100), 200, 300],
    };
    final bits = bitmap(positions.keys);
    final mutable = decodePostingPositions(
      bits,
      encodePostingPositions(bits, positions),
    );
    for (var document = 128; document < 256; document++) {
      if (document.isEven) {
        mutable.remove(document);
      } else {
        mutable[document] = [0, 1234, 65536];
      }
    }
    final updated = bitmap(mutable.keys);
    final decoded = decodePostingPositions(
      updated,
      encodePostingPositions(updated, mutable),
    );
    for (var document = 0; document < 1024; document++) {
      expect(
        decoded[document],
        document >= 128 && document < 256
            ? (document.isEven ? null : [0, 1234, 65536])
            : positions[document],
      );
    }
  });

  test('rejects malformed streams before oversized allocations', () {
    final bits = bitmap([0]);
    for (final bytes in <List<int>>[
      [],
      [0],
      [1],
      [2, 0],
      [1, 0, 0],
      [1, 128],
      [1, 128, 0],
      [1, 255, 255, 255, 255, 16],
      [2, 255, 255, 255, 255, 15, 1],
      [2, 0, 0],
      [255, 255, 255, 255, 15, 0],
    ]) {
      expect(
        () => decodePostingPositions(bits, Uint8List.fromList(bytes)),
        throwsFormatException,
        reason: '$bytes',
      );
      expect(
        () => visitPostingPositions(
          bits,
          Uint8List.fromList(bytes),
          (_, _) {},
          include: (_) => false,
        ),
        throwsFormatException,
        reason: 'Excluded document still validates $bytes',
      );
    }
    expect(
      () => decodePostingPositions(Uint8List(127), Uint8List(0)),
      throwsFormatException,
    );
    expect(
      () => decodePostingPositions(Uint8List(128), Uint8List.fromList([0])),
      throwsFormatException,
    );
    for (final positions in <Map<int, List<int>>>[
      {},
      {0: []},
      {
        0: [-1],
      },
      {
        0: [0x100000000],
      },
      {
        0: [1, 1],
      },
      {
        0: [2, 1],
      },
      {
        1: [0],
      },
      {
        0: [0],
        1: [1],
      },
    ]) {
      expect(
        () => encodePostingPositions(bits, positions),
        throwsFormatException,
      );
    }
  });
}
