# Conversation search

Search runs on the decrypted vault on the device. It indexes conversation titles,
message text, sources, tags, participant display names, aliases, linked provider
identifiers, and relation evidence. Merging people keeps their earlier names and
identifiers searchable across the linked conversations.
The server receives encrypted sync envelopes; searching never sends the query or
plaintext search index to the server. Locking clears the in-memory vault and its
index. Unlocking rebuilds the index from the restored encrypted vault (see
"Local vault format v2" and "Incremental search index" below).

All ordinary query terms must match. Matching accepts exact words, prefixes,
fragments of at least two characters, and spelling errors for words of at least
four characters (one edit, or two edits for words of at least six characters).
Exact matches receive more weight than prefixes, fragments, and spelling errors.
Unicode letters and numbers are preserved. German umlauts use their ae/oe/ue
spellings and ß uses ss; common Latin accents and combining marks are folded.
For example, `Joerg Muell`, `Jorg Muller`, and `Jörg Müller` find that participant.

Ranking uses BM25 term saturation and document-length normalization, with title,
participant, tag, and exact phrase boosts. This prevents repeated words in a long
transcript from overwhelming a useful title or participant match. An optional
TF-IDF cosine boost, enabled by default, adds statistical word similarity.
It is word overlap, not neural embeddings or synonym expansion. There is no
stemming, wildcard syntax, or language-specific semantic model. The typo rule
covers some plural differences incidentally; it does not promise stemming.

Repeated queries preserve relevance ordering. A new short query starts a fresh
search. Only explicit phrases such as `same as before`, `previous search`, or
`wie zuvor` reuse the previous query. Scores then break ties by conversation
start time and ID, giving pagination and launcher results stable ordering.

Relative dates add a ranking preference rather than excluding other dates:
`today`, `yesterday`, `last week`, `last month`, `last year`, and
`same time last year`; German `heute`, `gestern`, `letzte woche`, `letzten monat`,
and `letztes jahr` also work. They use the device's local calendar and daylight
saving boundaries. Last week means the previous Monday–Sunday; last month means
the previous calendar month. Morning/afternoon/evening/night qualifiers use local
hours. A query containing only a date ranks conversations by that date without
requiring the date phrase to occur in their text. Ordinary words such as `time`,
`year`, and `search` remain searchable topics. The explicit When filter requires
a conversation's time span to overlap its inclusive calendar-date range.

## Source categories and ranking weights

Sources are grouped (`app/lib/services/source_categories.dart`):

| Category | Sources | Weight |
| --- | --- | --- |
| personal | everything else (chats, mail, recordings, notes, ...) | 1.0 |
| documents | `scanned-pdf`, `paperless`, `photo` | 0.9 |
| consumed | `youtube-watch-history`, `tiktok-watch-history`, `youtube-transcript`, `browser-history`, `google-search-history`, `bookmarks`, `browser-capture` | 0.6 |

The weight multiplies the final score (lexical + vector + recency/temporal), also for
the empty-query timeline, so an equally matching personal chat always outranks a watched
video or document, and recent chats outrank recent watch history. Weights are constants
in `source_categories.dart`. Result cards show a **Consumed** badge for the consumed
category; watch-history cards without participants show "platform • channel • watched N×".

The **Hide consumed media** filter chip (`SearchCriteria.includeConsumed`, default true)
removes consumed items entirely. Saved searches store it as `hideConsumed` only when set,
so older saved searches keep showing everything.

## Repeatable relevance and performance checks

```sh
cd app
flutter test test/search_features_test.dart test/services/search_service_test.dart \
  test/services/search_scorer_test.dart test/services/string_distance_service_test.dart
dart run tool/search_benchmark.dart 10000
```

The tests exercise a real index, including participant/topic combinations,
Unicode and German names, phrase order, repeated words, strict term coverage,
stable top-eight results, and encrypted offline lock/unlock. The large corpus
regression verifies that only 100 relevant conversations reach scoring in a
10,000-conversation vault, and an unmatched term scores zero conversations.

Measured on the development KDE machine on 2026-10-03, using the Dart VM (JIT),
10,000 synthetic conversations and 10,017 vocabulary terms. Each query ran once
to warm up, then 20 times; these are local measurements, not a device-independent
latency guarantee. Building the index took 337 ms.

| Query | Median | 95th percentile | Scored conversations |
| --- | ---: | ---: | ---: |
| `insurance renewal` | 8.79 ms | 11.28 ms | 100 |
| `insuranc alice` | 9.70 ms | 10.80 ms | 100 |
| `ali muell` | 5.22 ms | 5.90 ms | 100 |
| `insurance banana` | 9.90 ms | 11.11 ms | 0 |
| Recent conversations (empty query) | 1.80 ms | 2.40 ms | 10,000 |

Query expansion scans vocabulary terms once for each distinct query word,
then intersects indexed conversation IDs. Document scoring reuses that expansion
instead of splitting and fuzzy-matching every transcript. Index rebuilding is
proportional to archive text size; query expansion is proportional to vocabulary
size. Large real exports and Android devices should be measured separately.

The same KDE machine was also checked against an imported Discord archive with
10,833 conversations, 126,281 messages and 1,272 detected people. After unlocking
and building the index, 12 real KRunner calls for `discord`, `skyblock` and `auction`
each returned eight results in 55–194 ms, including D-Bus client startup. The full
encrypted vault restored with unchanged counts after locking and restarting the
release app. These are desktop measurements; phone latency remains unmeasured.

## Import responsiveness

Native clients serialize/encrypt large snapshots, decrypt saved vaults and build
search indexes in background isolates. Imports keep the previous search index
until the replacement is ready, and long transcripts render messages lazily as
you scroll. Card previews are bounded to 500 characters. An unchanged sync poll
does not rewrite the encrypted snapshot.

Cached unlock restores messages in yielding batches and reports actual message
counts. Native key derivation and search preparation run in background isolates;
search reports conversation counts for tokenization and finalization. Progress
shows stage elapsed time and a measured remaining-time estimate when counts are
available. Unchanged cached startup also avoids a full snapshot rewrite, storing
only the refreshed session encrypted and bound to the cached snapshot instead.

One background isolate owns the native Sembast database, including encoding and
file I/O. Saves explicitly compact the encrypted records because Sembast 3.8.7 can
swallow lazy append errors. This adds a file rewrite but ensures write failures
reach the app before its outbox or email cursor advances. The file format is
unchanged; opening existing vaults and filesystem-failure recovery are tested.

The synthetic snapshot benchmark uses 126,288 messages in 10,524 conversations
and about 70 MB of ciphertext. On this KDE machine (2026-10-03, Dart JIT), maximum
event-loop gaps measured with a 10 ms heartbeat changed as follows:

| Operation | Previous main-isolate work | Background work |
| --- | ---: | ---: |
| JSON serialization and encryption | 7,555 ms | 167 ms |
| Snapshot decryption and JSON parsing | 6,014 ms | 26 ms |
| Encrypted database write | about 1,000 ms | 39 ms |

These measure UI-isolate availability, not total import duration or a latency
guarantee. The final background operations still took about 6.0 s, 5.3 s and 1.2 s
respectively. The browser uses its existing single-isolate fallback.

Refreshing the real Discord archive above and finishing encrypted sync took
620 seconds in the installed Linux release. During that refresh, 1,153 D-Bus
status calls had a median response of 17 ms, a 95th percentile of 81 ms and a
maximum of 1,509 ms; one KRunner query returned eight results in 100 ms. These
measure service responsiveness rather than frame times. Occasional pauses and
the roughly ten-minute bulk refresh remain; the change reduces blocking work,
not the amount of data processed. Final counts were unchanged with no pending
sync writes or reported errors.

## Local vault format v2, early unlock and incremental search

**Chunked storage.** The local vault is no longer one encrypted blob. A core
record at `vault:<key>` holds `{vaultSalt, format: 2, cipherText, nonce,
chunkCount, chunkNonces}`; its plaintext contains the session, sync cursor,
people, relations, saved searches, the pending outbox, the audio draft and a
`conversationBuckets` summary (per-chunk conversation and message counts), but no
conversation messages. Conversations live in chunks whose plaintext is `{conversations: [...]}`. On
native platforms each chunk is a file,
`<application support>/lifenizer-vaults/<FNV-1a(key) hex>/chunk-<n>.bin`: the
magic `LCK1`, one nonce-length byte, the ASCII nonce, then the ASCII cipherText to
end of file. The core records `chunkStorage: files`. The browser (and the unit
tests' default) keep the same `{cipherText, nonce}` records as
`vault:<key>:chunk:<n>` entries in the vault database (`chunkStorage: sembast`). A conversation belongs to chunk
`FNV-1a(id) % chunkCount` (a deterministic hash; Dart's `hashCode` is not stable
across runs). `chunkCount` is chosen at the first v2 write (1 below 200
conversations, otherwise conversations/250 clamped to 4..128) and kept, except
that a vault that has grown fourfold past its layout is re-bucketed with one full
rewrite.

Saves track which conversations changed (`_markConversationChanged`) and
encrypt/write only the core plus the affected chunks. Saving existing chunks is
two-phase so a crash never forces a re-download: (1) a core with the current
`chunkNonces`, the previous cursor and counts, the new outbox and a
`pendingChunkNonces` map of the nonces about to be written; (2) the chunk files; (3)
the final core with updated `chunkNonces`. On load a chunk is valid if its nonce
equals `chunkNonces[n]` or a pending nonce; a missing file or a nonce matching
neither takes the damaged-vault path. A chunk file can therefore be newer than the
core's cursor; that is safe because sync re-applies the same entities, which
replace conversations by id. Pending nonces are cleared by the next successful
save (a load that finds them forces one). The first save, a re-bucketing and a
storage migration use only the single final core write: the previous layout stays
valid until it lands, except that a crash during a re-bucketing still means a
re-download. Chunk files are written
first, each atomically: a temporary `chunk-<n>.bin.tmp` in the same directory is
written and flushed (fsync) and then renamed over the old file, so a reader sees
the previous or the new chunk, never a partial one. Any I/O error (disk full)
is thrown immediately and the temporary file is removed, so the outbox and cursor
do not advance on a failed save; this replaces the database compaction guard for
chunks. The small core record is then written to the database, which keeps its
explicit compaction (now cheap because the database holds no chunk ciphertext).
The directory name is a 32-bit hash; a collision between two vaults would be
caught by the nonce binding below and treated as a damaged vault. Chunk
decryption reads the file inside the worker isolate, so the main isolate never
handles the ciphertext. An audio-draft save, a session renewal or an
outbox change rewrites only the core. Vaults written by older builds (no
`format`) are read as before and converted by the first save. Chunks stored as
database records (`chunkStorage` absent or `sembast`) also load, and the first
save rewrites them as files, writes the core and only then deletes the old
records. Damaged-vault recovery deletes the chunk directory as well as any chunk
records; there is no separate "remove vault" feature, and locking only saves.

Loading reads the core, then decrypts all chunks on up to
`min(processors, 6)` background isolates (decryption and `jsonDecode` run in the
worker), while the UI isolate builds models from finished chunks in yielding
batches. The browser keeps a single sequential lane. A missing chunk, a chunk
(or chunk file) whose nonce differs from `chunkNonces`, an undecryptable chunk or a conversation
count that disagrees with the core makes unlock fail with a message that the
local vault is incomplete and must be re-downloaded online. The core was
authenticated, so the unsent outbox and microphone draft are first rewritten
into a minimal core (cursor 0, marked incomplete) and the chunk records are
deleted; the next online unlock downloads everything again and uploads the
preserved outbox. Offline unlock of such a vault keeps reporting the error.

**Audio draft.** A pending microphone recording (up to tens of MB) is not part of
the core. The core's `audioDraft` holds only metadata (`recordedAt`, `title`,
`participantNames`, `detailsPrompted`, `payloadBytes`, `payloadNonce`); the WAV is
encrypted into its own record (`audio-draft.bin` in the vault directory, or a
database record in the browser layout), written atomically like a chunk and bound
to the core by `payloadNonce`. `saveAudioDraft` writes the payload first, then the
core; `discardAudioDraft` deletes the payload after the core is written; editing
the draft's details writes only the core. `loadAudioDraftPayload()` returns the
bytes (kept in memory while the draft exists, else decrypted on demand in a
background isolate). Older vaults that stored the payload inside the core load it
and move it to its own record on the first save. Damaged-vault recovery removes
only numbered chunks, so the draft payload and metadata survive it. The payload is
still serialized as base64 inside its encrypted JSON envelope.

**Early unlock.** When a cached vault exists (and this is not a registration),
`login` opens the UI as soon as the vault is decrypted and the server vault ID
matches, with the status "Vault unlocked · syncing in background". The remote
sync, capability refresh, session/settings saving and search preparation then run
as the normal background sync (`_syncInFlight`), so `lock()` still waits for it,
progress still appears through `syncProgress`, and a failure sets `syncError` and
the failed stage instead of failing the unlock. The cached vault is authenticated
by its own AES-GCM tags; remote ciphertext is validated by that sync. The first
unlock on a device (nothing cached) and registration keep the blocking behaviour.

**Incremental search index.** Edits mark conversation IDs dirty. Participant and
relation changes, a missing index, or more than max(300, 5% of the corpus) dirty
conversations set a full-rebuild flag. Otherwise `ConversationSearchIndex.upsert`
and `remove` update the live index on the UI isolate in yielding batches (no
isolate copy): the document, its postings, IDF and average length are refreshed;
only the changed document's vector norm is recomputed and other documents keep
slightly stale norms until the next full build. After a background full build the
index documents are re-pointed at the live conversation objects, and edits made
during the build stay dirty and are applied incrementally, so one new recording or
synced conversation does not trigger another full rebuild. `search()` never builds
a whole index on the UI isolate for vaults above 1,000 conversations: it uses the
existing (possibly slightly stale) index, or, while none exists yet, a linear scan
(title, participant names and message text must contain every query word, newest
first, capped at 500) and `searchIndexPreparing` lets the page say that the index
is still being prepared. The linear scan folds accents in titles and names but
matches message text as typed.

Same machine and synthetic archive (10,524 conversations, 126,288 messages,
70 MB; Dart JIT, 12 cores, `--startup --background --background-store`; ranges
are three runs, noisy because the machine was not idle). These are not phone
measurements.

| Operation | Single blob (before) | Chunked v2 |
| --- | ---: | ---: |
| Derive vault key | 0.9-1.3 s | unchanged |
| Decrypt cached vault (+ jsonDecode) | 6.3-7.2 s | 1.4-2.5 s (43 chunks, 6 isolates, includes reading chunk records) |
| Restore conversation models | 0.5-0.6 s | 0.4-0.6 s |
| Prepare search (full build) | 3.3-5.4 s | unchanged for a full build; one new conversation is an incremental update |
| Full save: encrypt | 7.3-8.3 s | 1.7-3.2 s |
| Full save: database write | 1.6-1.7 s | 2.9-4.1 s (benchmark file also still holds the old blob) |
| Partial save (one dirty chunk + core) | 7.3-8.3 s encrypt + 1.6 s write | about 2.0-2.1 s in total |

With chunks stored in the database (browser layout) a partial save is dominated
by the explicit compaction, which rewrites the whole encrypted file. Chunk files
remove that cost on native platforms (one run, same machine; `--startup` prints
all of these):

| Operation | Chunks in the database | Chunk files |
| --- | ---: | ---: |
| Full save: write | 2.9-4.1 s | 0.34 s |
| Parallel load + decrypt (43 chunks) | 1.4-2.5 s | 1.3 s (files read inside the workers) |
| Partial save (one chunk + core, including encryption) | 2.0-2.1 s | 0.12 s |
| Core-only save (audio draft, session) | not measured separately | 2 ms (core database file only) |

Before this change every save, including an audio draft, re-encrypted
everything. File timings come from the page cache of a warm benchmark run; the
fsync-before-rename step is included.

On a cached unlock the UI no longer waits for the remote sync or the search build,
so the visible wait is key derivation, chunk decryption and model restoration
(roughly 3-4 s here, versus about 10 s of local work plus the remote sync and
search build before). That total is derived from the table above, not separately measured end to
end, and the first unlock on a device is unchanged.

```sh
cd app
dart run tool/vault_snapshot_benchmark.dart 126281
dart run tool/vault_snapshot_benchmark.dart 126281 --background --background-store
dart run tool/vault_snapshot_benchmark.dart 126281 --startup --background --background-store
```

`--startup` also measures key derivation, model restoration and search preparation,
plus the v2 chunked save, parallel load and one-chunk partial save.
Its model-restoration measurement intentionally uses the ordinary synchronous
model parser; the app yields during restoration to keep progress visible.
