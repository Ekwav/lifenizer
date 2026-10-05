import '../crypto_service.dart';

/// Where the encrypted conversation chunks of the local vault (format v2) live.
/// The small core record always stays in the Sembast database; the native app
/// keeps chunk ciphertext in one file per chunk so saving one chunk never
/// rewrites or compacts the whole database.
abstract class VaultChunkStore {
  /// Recorded in the core record (`chunkStorage`): `files` or `sembast`.
  String get kind;

  /// Chunk numbers currently stored for the vault [key].
  Future<List<int>> listChunks(String key);

  /// The `{cipherText, nonce}` record, or null when absent.
  Future<Map<String, dynamic>?> readChunk(String key, int n);

  /// Durably stores every record. Throws on any I/O failure.
  Future<void> writeChunks(String key, Map<int, Map<String, dynamic>> records);

  Future<void> deleteChunks(String key, Iterable<int> chunks);

  /// Removes every numbered chunk of [key] (blobs such as the audio draft stay).
  Future<void> deleteAll(String key);

  /// Decrypts chunk [n] and requires its nonce to equal [expectedNonce] or one of
  /// [alternateNonces] (a chunk written by a save whose final core never landed). File
  /// stores read the file inside the worker isolate, so the main isolate never
  /// handles the ciphertext. Throws when the chunk is missing or damaged.
  Future<Map<String, dynamic>> decryptChunk(
    VaultCrypto crypto,
    String key,
    int n,
    String expectedNonce, {
    Iterable<String> alternateNonces = const [],
    bool background = true,
  });

  /// Named single-record blobs next to the chunks (the pending audio draft),
  /// stored with the same `{cipherText, nonce}` shape and the same durability.
  Future<Map<String, dynamic>?> readBlob(String key, String name);
  Future<void> writeBlob(String key, String name, Map<String, dynamic> record);
  Future<void> deleteBlob(String key, String name);

  /// The nonce stored with chunk [n] (without decrypting), or null if absent.
  Future<String?> chunkNonce(String key, int n);
}
