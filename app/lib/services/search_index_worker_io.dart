import 'dart:isolate';

import 'conversation_search_index.dart';

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
