# Conversation search

Search runs on the decrypted vault on the device. It indexes conversation titles,
message text, sources, tags, participant display names, aliases, linked provider
identifiers, and relation evidence. Merging people keeps their earlier names and
identifiers searchable across the linked conversations.
The server receives encrypted sync envelopes; searching never sends the query or
plaintext search index to the server. Locking clears the in-memory vault and its
index. Unlocking rebuilds the index from the restored encrypted snapshot.

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

```sh
cd app
dart run tool/vault_snapshot_benchmark.dart 126281
dart run tool/vault_snapshot_benchmark.dart 126281 --background --background-store
dart run tool/vault_snapshot_benchmark.dart 126281 --startup --background --background-store
```

`--startup` also measures key derivation, model restoration and search preparation.
Its model-restoration measurement intentionally uses the ordinary synchronous
model parser; the app yields during restoration to keep progress visible.
