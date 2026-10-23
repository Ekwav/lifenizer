import 'conversation_search_index.dart';
import 'vault_chunks.dart';
import 'dart:convert';
import 'package:archive/archive.dart';

Map<String, dynamic> _pack(Map<String, dynamic> value) => {
  'gzip': base64Encode(GZipEncoder().encode(utf8.encode(jsonEncode(value)))),
};

Map<String, dynamic> _unpack(Map<String, dynamic> value) =>
    jsonDecode(
          utf8.decode(
            GZipDecoder().decodeBytes(base64Decode(value['gzip'] as String)),
          ),
        )
        as Map<String, dynamic>;

Future<Map<String, dynamic>> encodeSearchSnapshot(
  ConversationSearchIndex index,
) async => _pack(index.toJson());

Future<ConversationSearchIndex> decodeSearchSnapshot(
  Map<String, dynamic> snapshot,
) async => ConversationSearchIndex.fromJson(_unpack(snapshot));

Future<
  ({
    Map<String, dynamic> catalog,
    List<Map<String, dynamic>> details,
    List<Map<String, dynamic>> postings,
  })
>
encodeSearchSnapshotParts(
  ConversationSearchIndex index,
  int bucketCount,
) async {
  if (bucketCount < 1) throw ArgumentError.value(bucketCount, 'bucketCount');
  if (!index.postingsLoaded) {
    throw StateError('Load search postings before saving index parts');
  }
  final buckets = List.generate(bucketCount, (_) => <String, dynamic>{});
  final postings = List.generate(bucketCount, (_) => <String, dynamic>{});
  for (final entry in index.invertedIndex.entries) {
    postings[vaultChunkFor(entry.key, bucketCount)][entry.key] = entry.value
        .toList();
  }
  for (final entry in index.documents.entries) {
    buckets[vaultChunkFor(entry.key, bucketCount)][entry.key] = {
      'haystack': entry.value.haystack,
      'termFrequency': entry.value.termFrequency,
    };
  }
  return (
    catalog: _pack(index.toJson(includeDetails: false, includePostings: false)),
    details: [for (final bucket in buckets) _pack(bucket)],
    postings: [for (final bucket in postings) _pack(bucket)],
  );
}

Future<Map<String, dynamic>> decodeSearchDetails(
  Map<String, dynamic> details,
) async => _unpack(details);

Future<ConversationSearchIndex> prepareSearchIndex(
  SearchIndexInputs inputs,
  void Function(SearchIndexProgress) onProgress,
) async {
  await Future<void>.delayed(Duration.zero);
  return ConversationSearchIndex.build(
    conversations: inputs.$1,
    participantById: inputs.$2,
    relationTextByConversation: inputs.$3,
    onProgress: onProgress,
  );
}
