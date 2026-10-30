import 'dart:typed_data';

/// Positions follow the set bits of a 1024-document posting bitmap, in order.
/// Each document stores a positive occurrence count and ascending delta-coded
/// token offsets. V5 adds a field-boost byte after each count; without
/// [fieldBoosts], encoding remains byte-compatible with v4. The enclosing
/// encrypted posting authenticates and identifies the stream version.
Uint8List encodePostingPositions(
  Uint8List bitmap,
  Map<int, List<int>> positions, {
  Map<int, int>? fieldBoosts,
}) {
  final bytes = <int>[];
  var documents = 0;
  for (final document in _documents(bitmap)) {
    final values = positions[document];
    if (values == null || values.isEmpty) {
      throw const FormatException('Missing posting positions.');
    }
    _write(bytes, values.length);
    if (fieldBoosts != null) {
      final boost = fieldBoosts[document];
      if (boost == null || boost < 0 || boost > 18) {
        throw const FormatException('Invalid posting field boost.');
      }
      bytes.add(boost);
    }
    var previous = 0;
    for (var i = 0; i < values.length; i++) {
      final position = values[i];
      if (position < 0 ||
          position > 0xffffffff ||
          (i > 0 && position <= previous)) {
        throw const FormatException('Invalid posting position order.');
      }
      _write(bytes, position - previous);
      previous = position;
    }
    documents++;
  }
  if (documents != positions.length ||
      (fieldBoosts != null && documents != fieldBoosts.length)) {
    throw const FormatException('Positions do not match the posting bitmap.');
  }
  return Uint8List.fromList(bytes);
}

Map<int, List<int>> decodePostingPositions(
  Uint8List bitmap,
  Uint8List payload, {
  bool hasFieldBoosts = false,
  Map<int, int>? fieldBoosts,
}) {
  final positions = <int, List<int>>{};
  visitPostingPositions(
    bitmap,
    payload,
    (document, values) {
      positions[document] = values;
    },
    hasFieldBoosts: hasFieldBoosts,
    onFieldBoost: fieldBoosts == null
        ? null
        : (document, boost) => fieldBoosts[document] = boost,
  );
  return positions;
}

/// Visits one bounded posting page without retaining its decoded document map.
/// Each supplied list belongs to the visitor and may be retained or mutated.
void visitPostingPositions(
  Uint8List bitmap,
  Uint8List payload,
  void Function(int document, List<int> positions) visitor, {
  bool Function(int document)? include,
  bool hasFieldBoosts = false,
  void Function(int document, int boost)? onFieldBoost,
}) => _visit(
  bitmap,
  payload,
  include: include,
  hasFieldBoosts: hasFieldBoosts,
  positionVisitor: visitor,
  scoreVisitor: onFieldBoost == null
      ? null
      : (document, _, boost) => onFieldBoost(document, boost),
);

/// Reads exact TF and field boost without allocating any position lists.
/// Position deltas are still validated, including for excluded documents.
/// A v4 stream has no stored boosts and reports zero for that field.
void visitPostingScores(
  Uint8List bitmap,
  Uint8List payload,
  void Function(int document, int tf, int boost) visitor, {
  bool hasFieldBoosts = true,
  bool Function(int document)? include,
}) => _visit(
  bitmap,
  payload,
  include: include,
  hasFieldBoosts: hasFieldBoosts,
  scoreVisitor: visitor,
);

void _visit(
  Uint8List bitmap,
  Uint8List payload, {
  required bool hasFieldBoosts,
  bool Function(int document)? include,
  void Function(int document, List<int> positions)? positionVisitor,
  void Function(int document, int tf, int boost)? scoreVisitor,
}) {
  final reader = _Reader(payload);
  if (bitmap.length != 128) {
    throw const FormatException('Invalid posting position bitmap.');
  }
  for (var byte = 0; byte < 128; byte++) {
    final bits = bitmap[byte];
    if (bits == 0) continue;
    for (var pending = bits; pending != 0; pending &= pending - 1) {
      final bit = (pending & -pending).bitLength - 1;
      final document = byte * 8 + bit;
      final count = reader.read();
      var boost = 0;
      if (hasFieldBoosts) {
        if (reader.offset == payload.length) {
          throw const FormatException('Truncated posting field boost.');
        }
        boost = payload[reader.offset++];
        if (boost > 18) {
          throw const FormatException('Invalid posting field boost.');
        }
      }
      // Every position requires at least one byte. Check before allocating.
      if (count == 0 || count > payload.length - reader.offset) {
        throw const FormatException('Invalid posting position count.');
      }
      final selected = include == null || include(document);
      final values = selected && positionVisitor != null
          ? Uint32List(count)
          : null;
      var position = 0;
      for (var i = 0; i < count; i++) {
        final delta = reader.read();
        if ((i > 0 && delta == 0) || position + delta > 0xffffffff) {
          throw const FormatException('Invalid posting position delta.');
        }
        position += delta;
        if (values != null) values[i] = position;
      }
      if (selected) scoreVisitor?.call(document, count, boost);
      if (values != null) positionVisitor!(document, values);
    }
  }
  if (reader.offset != payload.length) {
    throw const FormatException('Trailing posting position bytes.');
  }
}

Iterable<int> _documents(Uint8List bitmap) sync* {
  if (bitmap.length != 128) {
    throw const FormatException('Invalid posting position bitmap.');
  }
  for (var byte = 0; byte < bitmap.length; byte++) {
    final bits = bitmap[byte];
    if (bits == 0) continue;
    for (var bit = 0; bit < 8; bit++) {
      if ((bits & (1 << bit)) != 0) yield byte * 8 + bit;
    }
  }
}

void _write(List<int> bytes, int value) {
  if (value < 0 || value > 0xffffffff) {
    throw const FormatException('Posting position integer is out of range.');
  }
  while (value >= 128) {
    bytes.add((value & 127) | 128);
    value >>= 7;
  }
  bytes.add(value);
}

class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  int offset = 0;

  int read() {
    if (offset == bytes.length) {
      throw const FormatException('Truncated posting position integer.');
    }
    final first = bytes[offset++];
    if (first < 128) return first;
    var value = first & 127;
    for (var shift = 7; shift <= 28; shift += 7) {
      if (offset == bytes.length) {
        throw const FormatException('Truncated posting position integer.');
      }
      final byte = bytes[offset++];
      if (shift == 28 && byte > 15) {
        throw const FormatException('Posting position integer is too large.');
      }
      value |= (byte & 127) << shift;
      if (byte < 128) {
        if (byte == 0) {
          throw const FormatException('Noncanonical posting position integer.');
        }
        return value;
      }
    }
    throw const FormatException('Invalid posting position integer.');
  }
}
