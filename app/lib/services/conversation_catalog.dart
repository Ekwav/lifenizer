import 'dart:collection';
import 'dart:typed_data';

import '../models.dart';

/// Keeps repeated summary fields shared, while retaining live edits unchanged.
/// Shared summary lists are immutable; edits replace a conversation as usual.
class ConversationCatalog extends ListBase<Conversation> {
  final _items = <Conversation>[];
  var _previews = _PreviewCodec();
  final _strings = <String>{};
  final _lists = HashSet<List<String>>(
    equals: (a, b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    },
    hashCode: Object.hashAll,
  );
  static const _poolLimit = 4096;

  @override
  int get length => _items.length;

  @override
  set length(int value) {
    _items.length = value;
    if (value == 0) {
      _previews = _PreviewCodec();
      _strings.clear();
      _lists.clear();
    }
  }

  @override
  Conversation operator [](int index) => _items[index];

  @override
  void operator []=(int index, Conversation value) {
    _items[index] = _compact(value);
  }

  @override
  void add(Conversation element) => _items.add(_compact(element));

  @override
  void addAll(Iterable<Conversation> iterable) =>
      _items.addAll(iterable.map(_compact));

  @override
  void insert(int index, Conversation element) =>
      _items.insert(index, _compact(element));

  @override
  void insertAll(int index, Iterable<Conversation> iterable) =>
      _items.insertAll(index, iterable.map(_compact));

  @override
  void sort([int Function(Conversation, Conversation)? compare]) =>
      _items.sort(compare);

  @override
  void removeWhere(bool Function(Conversation) test) =>
      _items.removeWhere(test);

  String _string(String value) {
    final existing = _strings.lookup(value);
    if (existing != null) return existing;
    if (_strings.length == _poolLimit) _strings.clear();
    _strings.add(value);
    return value;
  }

  List<String> _list(List<String> value) {
    if (value.isEmpty) return const [];
    final existing = _lists.lookup(value);
    if (existing != null) return existing;
    final compact = List<String>.unmodifiable(value.map(_string));
    if (_lists.length == _poolLimit) _lists.clear();
    _lists.add(compact);
    return compact;
  }

  Conversation _compact(Conversation value) {
    if (value.isLoaded) return value;
    final preview = value.previewText;
    final packed = _previews.pack(preview);
    final compact = Conversation(
      id: value.id,
      title: value.title,
      source: _string(value.source),
      participantIds: _list(value.participantIds),
      segments: const [],
      isLoaded: false,
      segmentCount: value.segmentCount,
      previewText: packed == null ? preview : '',
      artifactNames: _list(value.artifactNames),
      tags: _list(value.tags),
      isFavorite: value.isFavorite,
      importFingerprint: value.importFingerprint,
      startedAt: value.startedAt,
      endedAt: value.startedAt == value.endedAt
          ? value.startedAt
          : value.endedAt,
      location: value.location,
      sourceUrl: value.sourceUrl,
      sourceThreadId: value.sourceThreadId,
      metadata: value.metadata.isEmpty ? const {} : value.metadata,
    );
    return packed == null
        ? compact
        : _PackedSummary(compact, _previews, packed);
  }
}

class _PreviewCodec {
  static final _words = RegExp(r'\S+');
  final _dictionary = <String>[];
  final _indices = <String, int>{};

  Uint8List? pack(String value) {
    final bytes = <int>[];
    void literal(int start, int end) {
      for (var i = start; i < end; i++) {
        final unit = value.codeUnitAt(i);
        if (unit < 128) {
          bytes.add(unit);
        } else {
          bytes.addAll([255, unit & 255, unit >> 8]);
        }
      }
    }

    var offset = 0;
    for (final match in _words.allMatches(value)) {
      literal(offset, match.start);
      final word = match.group(0)!;
      int? index;
      if (word.length >= 3 && word.length <= 64) {
        index = _indices[word];
        if (index == null && _dictionary.length < 4096) {
          index = _dictionary.length;
          _dictionary.add(word);
          _indices[word] = index;
        }
      }
      if (index == null) {
        literal(match.start, match.end);
      } else {
        bytes.addAll([128 + (index >> 8), index & 255]);
      }
      offset = match.end;
    }
    literal(offset, value.length);
    final width = value.codeUnits.any((unit) => unit > 255) ? 2 : 1;
    // Account conservatively for the typed buffer and two subclass references.
    if (bytes.length + 32 >= value.length * width) return null;
    return Uint8List.fromList(bytes);
  }

  String unpack(Uint8List bytes) {
    final text = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      final code = bytes[i];
      if (code == 255) {
        text.writeCharCode(bytes[++i] | bytes[++i] << 8);
      } else if (code >= 128) {
        text.write(_dictionary[((code - 128) << 8) | bytes[++i]]);
      } else {
        text.writeCharCode(code);
      }
    }
    return text.toString();
  }
}

class _PackedSummary extends Conversation {
  _PackedSummary(Conversation value, this._codec, this._packed)
    : super(
        id: value.id,
        title: value.title,
        source: value.source,
        participantIds: value.participantIds,
        segments: const [],
        isLoaded: false,
        segmentCount: value.segmentCount,
        previewText: '',
        artifactNames: value.artifactNames,
        tags: value.tags,
        isFavorite: value.isFavorite,
        importFingerprint: value.importFingerprint,
        startedAt: value.startedAt,
        endedAt: value.endedAt,
        location: value.location,
        sourceUrl: value.sourceUrl,
        sourceThreadId: value.sourceThreadId,
        metadata: value.metadata,
      );
  final _PreviewCodec _codec;
  final Uint8List _packed;
  @override
  String get previewText => _codec.unpack(_packed);
}
