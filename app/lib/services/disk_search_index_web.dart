// Native SQLite search is unavailable in the browser. Keep the established
// encrypted browser cache and in-memory index there.
import '../models.dart';
import 'search_criteria.dart';
import 'search_scorer.dart';

class DiskSearchIndex {
  static const int writeBatchSize = 1024;
  static Future<DiskSearchIndex> open({
    required String path,
    required List<int> vaultKey,
    bool recreateOnFailure = false,
  }) => throw UnsupportedError('Disk search requires native SQLite.');
  Future<int> get count => throw UnsupportedError('Native SQLite required');
  Future<void> upsert(
    List<Conversation> batch, {
    required Map<String, String> participantById,
    required Map<String, String> relationTextByConversation,
  }) async {}
  Future<void> remove(List<String> ids) async {}
  Future<void> clear() async {}
  Future<void> prepare() async {}
  Future<void> cancelSearch() async {}
  Future<List<Conversation>> search(
    SearchCriteria criteria,
    SearchScorer scorer,
    List<String> tokens,
    String normalized, {
    int maxResults = 100,
  }) async => [];
  Future<List<Conversation>> summaries({
    int offset = 0,
    int limit = 1000,
    String? afterId,
  }) async => [];
  Future<List<Conversation>> loadConversations(List<String> ids) async => [];
  Future<Object?> readMetadata(String key) async => null;
  Future<void> writeMetadata(String key, Object? value) async {}
  Future<void> close() async {}
}
