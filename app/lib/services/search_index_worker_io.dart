import 'dart:isolate';
import 'dart:convert';
import 'dart:io';

import 'conversation_search_index.dart';
import 'vault_chunks.dart';

// Compress before encryption. No plaintext index is ever written to disk.
Map<String, dynamic> _pack(Map<String, dynamic> value) => {
  'gzip': base64Encode(gzip.encode(utf8.encode(jsonEncode(value)))),
};

Map<String, dynamic> _unpack(Map<String, dynamic> value) =>
    jsonDecode(utf8.decode(gzip.decode(base64Decode(value['gzip'] as String))))
        as Map<String, dynamic>;

Future<Map<String, dynamic>> encodeSearchSnapshot(
  ConversationSearchIndex index,
) => Isolate.run(() => _pack(index.toJson()));

Future<ConversationSearchIndex> decodeSearchSnapshot(
  Map<String, dynamic> snapshot,
) => Isolate.run(() => ConversationSearchIndex.fromJson(_unpack(snapshot)));

Future<({Map<String, dynamic> catalog, List<Map<String, dynamic>> details})>
encodeSearchSnapshotParts(ConversationSearchIndex index, int bucketCount) =>
    Isolate.run(() {
      if (bucketCount < 1) {
        throw ArgumentError.value(bucketCount, 'bucketCount');
      }
      final buckets = List.generate(bucketCount, (_) => <String, dynamic>{});
      for (final entry in index.documents.entries) {
        buckets[vaultChunkFor(entry.key, bucketCount)][entry.key] = {
          'haystack': entry.value.haystack,
          'termFrequency': entry.value.termFrequency,
        };
      }
      return (
        catalog: _pack(index.toJson(includeDetails: false)),
        details: [for (final bucket in buckets) _pack(bucket)],
      );
    });

Future<Map<String, dynamic>> decodeSearchDetails(
  Map<String, dynamic> details,
) => Isolate.run(() => _unpack(details));

Future<ConversationSearchIndex> prepareSearchIndex(
  SearchIndexInputs inputs,
  void Function(SearchIndexProgress) onProgress,
) async {
  final progress = ReceivePort();
  final listener = progress.listen(
    (value) => onProgress(value as SearchIndexProgress),
  );
  try {
    return await _buildIndex(inputs, progress.sendPort);
  } finally {
    await listener.cancel();
    progress.close();
  }
}

// Keep this closure separate from the listener so it cannot capture app state.
Future<ConversationSearchIndex> _buildIndex(
  SearchIndexInputs inputs,
  SendPort progress,
) => Isolate.run(
  () => ConversationSearchIndex.build(
    conversations: inputs.$1,
    participantById: inputs.$2,
    relationTextByConversation: inputs.$3,
    onProgress: progress.send,
  ),
  debugName: 'conversation-search-index',
);
