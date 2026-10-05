/// Layout helpers for the chunked local vault (format v2).
library;

/// Deterministic 32-bit FNV-1a over UTF-16 code units. Dart's `hashCode` is not
/// stable across runs, and bucket assignment must survive restarts. The
/// multiplication is split so intermediate values stay below 2^53 (web safe).
int stableStringHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit & 0xFFFF;
    // hash * 16777619 == hash * 403 + (hash << 24)  (mod 2^32)
    hash = (hash * 403 + ((hash & 0xFF) << 24)) & 0xFFFFFFFF;
  }
  return hash;
}

int vaultChunkFor(String conversationId, int chunkCount) =>
    chunkCount <= 1 ? 0 : stableStringHash(conversationId) % chunkCount;

/// Chosen once at the first v2 write: one chunk for small vaults, otherwise
/// roughly 250 conversations per chunk within 4..128 chunks.
int vaultChunkCountFor(int conversationCount) =>
    conversationCount < 200 ? 1 : (conversationCount ~/ 250).clamp(4, 128);
