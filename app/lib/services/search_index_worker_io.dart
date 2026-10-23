import 'dart:isolate';
import 'dart:convert';
import 'dart:io';

import 'conversation_search_index.dart';

// Compress before encryption: repeated vocabulary and summary fields otherwise
// dominate startup decryption. No plaintext index is ever written to disk.
Future<Map<String, dynamic>> encodeSearchSnapshot(
  ConversationSearchIndex index,
) => Isolate.run(
  () => {
    'gzip': base64Encode(gzip.encode(utf8.encode(jsonEncode(index.toJson())))),
  },
);

Future<ConversationSearchIndex> decodeSearchSnapshot(
  Map<String, dynamic> snapshot,
) => Isolate.run(
  () => ConversationSearchIndex.fromJson(
    jsonDecode(
          utf8.decode(gzip.decode(base64Decode(snapshot['gzip'] as String))),
        )
        as Map<String, dynamic>,
  ),
);

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
