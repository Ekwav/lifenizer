import '../crypto_service.dart';
import 'local_vault_store.dart';
import 'vault_chunk_store.dart';

/// Chunks as `<key>:chunk:<n>` records in the vault database (web, tests and
/// vaults saved before chunk files existed).
class SembastVaultChunkStore implements VaultChunkStore {
  SembastVaultChunkStore(this._store);
  final LocalVaultStore _store;

  @override
  String get kind => 'sembast';

  static String recordKey(String key, int n) => '$key:chunk:$n';

  @override
  Future<List<int>> listChunks(String key) async {
    final found = <int>[];
    for (var n = 0; await _store.read(recordKey(key, n)) != null; n++) {
      found.add(n);
    }
    return found;
  }

  @override
  Future<Map<String, dynamic>?> readChunk(String key, int n) =>
      _store.read(recordKey(key, n));

  @override
  Future<void> writeChunks(
    String key,
    Map<int, Map<String, dynamic>> records,
  ) => _store.writeMany({
    for (final entry in records.entries) recordKey(key, entry.key): entry.value,
  });

  @override
  Future<void> deleteChunks(String key, Iterable<int> chunks) =>
      _store.deleteMany([for (final n in chunks) recordKey(key, n)]);

  @override
  Future<void> deleteAll(String key) async =>
      deleteChunks(key, await listChunks(key));

  @override
  Future<Map<String, dynamic>?> readBlob(String key, String name) =>
      _store.read('$key:$name');

  @override
  Future<void> writeBlob(
    String key,
    String name,
    Map<String, dynamic> record,
  ) => _store.write('$key:$name', record);

  @override
  Future<void> deleteBlob(String key, String name) =>
      _store.deleteMany(['$key:$name']);

  @override
  Future<String?> chunkNonce(String key, int n) async =>
      (await readChunk(key, n))?['nonce'] as String?;

  @override
  Future<Map<String, dynamic>> decryptChunk(
    VaultCrypto crypto,
    String key,
    int n,
    String expectedNonce, {
    Iterable<String> alternateNonces = const [],
    bool background = true,
  }) async {
    final record = await readChunk(key, n);
    if (record == null ||
        (record['nonce'] != expectedNonce &&
            !alternateNonces.contains(record['nonce']))) {
      throw StateError('Chunk $n is missing or does not match the vault.');
    }
    return crypto.decryptJson(
      cipherText: record['cipherText'] as String,
      nonce: record['nonce'] as String,
      background: background,
    );
  }
}
