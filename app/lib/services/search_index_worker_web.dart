import 'conversation_search_index.dart';
import 'dart:convert';
import 'package:archive/archive.dart';

Future<Map<String, dynamic>> encodeSearchSnapshot(
  ConversationSearchIndex index,
) async => {
  'gzip': base64Encode(
    GZipEncoder().encode(utf8.encode(jsonEncode(index.toJson()))),
  ),
};

Future<ConversationSearchIndex> decodeSearchSnapshot(
  Map<String, dynamic> snapshot,
) async => ConversationSearchIndex.fromJson(
  jsonDecode(
        utf8.decode(
          GZipDecoder().decodeBytes(base64Decode(snapshot['gzip'] as String)),
        ),
      )
      as Map<String, dynamic>,
);

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
