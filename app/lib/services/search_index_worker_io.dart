import 'dart:isolate';
import 'dart:convert';
import 'dart:io';

import '../crypto_service.dart';
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

/// Authenticate and decode the catalog in one operation; only the ready index
/// and small cache metadata return to the UI isolate.
Future<({ConversationSearchIndex index, Map<String, dynamic> metadata})>
decryptSearchSnapshot(
  VaultCrypto crypto, {
  required String cipherText,
  required String nonce,
}) async {
  final bytes = await crypto.exportDeviceKey();
  try {
    return await Isolate.run(
      () => _decryptSearchSnapshot(bytes, cipherText, nonce),
    );
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

Future<({ConversationSearchIndex index, Map<String, dynamic> metadata})>
_decryptSearchSnapshot(List<int> bytes, String cipherText, String nonce) async {
  final crypto = VaultCrypto()..unlockDeviceKey(bytes);
  try {
    final snapshot = await crypto.decryptJson(
      cipherText: cipherText,
      nonce: nonce,
    );
    final index = ConversationSearchIndex.fromJson(_unpack(snapshot));
    snapshot.remove('gzip');
    return (index: index, metadata: snapshot);
  } finally {
    crypto.lock();
    bytes.fillRange(0, bytes.length, 0);
  }
}

Future<
  ({
    Map<String, dynamic> catalog,
    List<Map<String, dynamic>> details,
    List<Map<String, dynamic>> postings,
  })
>
encodeSearchSnapshotParts(ConversationSearchIndex index, int bucketCount) =>
    Isolate.run(() {
      if (bucketCount < 1) {
        throw ArgumentError.value(bucketCount, 'bucketCount');
      }
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
          'titleTokens': entry.value.titleTokens.toList(),
          'personTokens': entry.value.personTokens.toList(),
        };
      }
      return (
        catalog: _pack(
          index.toJson(includeDetails: false, includePostings: false),
        ),
        details: [for (final bucket in buckets) _pack(bucket)],
        postings: [for (final bucket in postings) _pack(bucket)],
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
