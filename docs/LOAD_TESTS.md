# Conversation load tests, 2026-10-28

These are baseline measurements before the
[encrypted native disk index](SEARCH.md#encrypted-native-disk-index) was added.
They remain recorded to explain the original bottlenecks.

Search returned correct results at **100,000 conversations averaging 200 words**.
Initial client sync became slow well before that size. Upload batching and
incremental downloads worked, but saving and indexing each download page adds
substantial client work. These measurements establish tested sizes, not a fixed
maximum conversation count.

All inputs were synthetic. The machine was an AMD Ryzen 5 3600XT (6 cores,
12 threads), Linux x86_64, Dart 3.12.2 JIT. Some runs overlapped on this shared
development machine; timings are approximate desktop measurements. Android,
browser, WAN and remote S3 latency were not measured. See the
[complete measurements](benchmarks/conversation-load-2026-10-28.json).

The search fixture has ten 20-word segments per conversation. It samples 1,723
words from public repository documentation, includes distinct numeric titles,
and reserves topic/person terms for exactly 1% of conversations. This tests word
count and growing vocabulary, rather than natural conversation distribution.
Each query has one warm-up and 20 timed samples, returning up to 51 results.
Assertions check match counts, result membership and stable ordering. The full
run repeats checks after encrypted snapshot restoration and 100 batched index
updates, including a new searchable term.

| Conversations | Index build | Topic query p95 | Broad query p95 | Full snapshot round trip |
| ---: | ---: | ---: | ---: | --- |
| 1,000 | 0.46 s | 6.8 ms | 11.2 ms | Passed |
| 10,000 | 3.38 s | 21.6 ms | 37.2 ms | Passed |
| 50,000 | 16.58 s | 115.1 ms | 255.8 ms | Passed |
| 100,000 | 39.95 s | 201.9 ms | 456.7 ms | Exceeded the 4 GiB benchmark heap budget |
| 200,000 | Exceeded the 4 GiB heap budget during index construction | Not reached | Not reached | Not reached |

This table uses freshly built indexes, `insurance renewal` as the selective
topic query and `archive` as the broad query. Restored-index broad-query p95 was
353 ms at 50,000. Typo, Unicode participant, missing-term and recent-item queries
also passed. At 100,000, even the missing-term query took 169 ms p95: query
expansion scans the vocabulary. Broad queries additionally score the whole
archive synchronously, so correct results can still cause visible pauses.

The full snapshot benchmark succeeded through 50,000, peaking at 3.80 GiB RSS;
its encrypted index occupied 170.8 MiB, versus 144.1 MiB for serialized original
conversations. At 100,000 the full run passed in-memory searches, then ran out of
heap during `jsonEncode(index.toJson())`, requesting another 493 MB allocation.
A separate search-only run passed at 100,000 with 2.91 GiB peak RSS. The full
benchmark retains the original corpus and intermediate copies and uses the
older monolithic index snapshot path. That allocation failure does **not** show
that the app's current sharded, lazy search cache fails at 100,000.

The client sync fixture uses the real app state, encryption, native SQLite
worker and fsynced chunk files, with an in-process HTTP mock implementing the
backend's 500-envelope paging and cursor behavior. Its conversations have eight
25-word segments using a smaller repeated vocabulary. A synthetic device key
excludes passphrase derivation from timings. Assertions verify counts, cursors,
updated titles, searches and offline restoration.

| Initial conversations | Initial client sync | Download requests | Initial local vault size |
| ---: | ---: | ---: | ---: |
| 1,000 | 1.49–1.57 s | 3 | 4.58 MiB |
| 10,000 | 52.50–68.95 s | 21 | 46.53 MiB |
| 50,000 | Incomplete at the ten-minute test timeout | Not captured | 190.24 MiB partial |

The 50,000-conversation run timed out during initial sync. Inspecting its
encrypted SQLite core with the synthetic fixture key confirmed 41,000
conversations and 328,000 messages had been durably committed at cursor 41,000,
with no pending chunk rewrite. The ten-minute test budget includes fixture
generation. The test process exited and its temporary vault was removed after
capturing this evidence; 50,000 was not a successful complete client sync.

At 10,000 conversations, 101 remote updates took 2.35–4.45 s and one download
request. Creating 601 additional conversations and uploading them worked:
uploads split into **[100, 100, 100, 100, 100, 100, 1]**, and the echoed changes
arrived in two download pages. Upload plus echoed download/persistence took
6.07–9.63 s, excluding the 6.33–13.13 s spent creating and queuing those items.
One hundred edits to the same participant coalesced to one envelope. Automatic
sync held it before the 20-second window and uploaded it afterward. Manual sync
sent the 601 changes immediately. No-op sync sent no upload. Offline reload and
a targeted search passed after these updates; cached unlock itself took
0.19–0.38 s at 10,601 conversations, excluding key derivation and the later lazy
search reads.

The real backend was tested separately through ASP.NET TestServer, actual
SQLite and local object files. This checks endpoint/storage work without
client-side processing or real socket/WAN/S3 costs. A local synthetic Premium
grant allowed the large fixture to exceed the Free storage quota.

| Conversations | Generate, encrypt and upload | Initial download | Download response size | Charged object storage |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.53–0.80 s | 0.09–0.13 s | 4.26 MiB | 4.00 MiB |
| 10,000 | 4.24–6.43 s | 0.65–0.77 s | 42.81 MiB | 40.15 MiB |
| 100,000 | 17.19–29.15 s | 2.93–3.79 s | 430.18 MiB | 403.32 MiB |

The 100,000 run used 1,000 upload batches and 201 download requests, checking
every returned envelope ID and ciphertext. Updating 601 existing conversations
used seven uploads and two incremental download pages; the latter took
14–34 ms at 100,000. These backend timings must not be read as end-to-end app
sync timings. The client and backend fixtures also have slightly different
serialized metadata and ciphertext sizes.

The current Free quota is 50 MiB, including sync objects. At this fixture's
roughly 4.2 KB of charged storage per uploaded revision, an otherwise empty Free
vault would hold approximately **12,000 first revisions**, an extrapolation
rather than an exact tested quota boundary. Media and subsequent revisions
reduce that count. The backend is append-only: the 601 updates left 100,601
envelopes and increased charged storage from 403.32 to 405.72 MiB. Fresh devices
download old revisions too; uploaded history is not compacted to one current
version per conversation. Coalescing only reduces changes still in the outbox.

Inspection and instrumentation identify concrete optimization targets:

- Each 500-envelope download page calls `_persistLocal`, which prepares search.
  The 10,000 initial download performed 19 full index builds and one incremental
  update. Approximate progress-stage accounting attributed 59.4 of 68.9 seconds
  to the indexing stage, which also includes subsequent cache/save work.
- Each changed search revision serializes and encrypts the entire catalog,
  postings and detail cache. The 500 changed conversations also spread across
  most local chunks. Repeating this per download page multiplies work.
- Applying conversations scans the conversation list for the old ID and removes
  the previous object. Building a large archive therefore includes quadratic
  list work.
- `batchVaultChanges` batches persistence, but each `addManualText` still calls
  `_run`'s search preparation. Creating the 601-item batch performed 601
  incremental search updates.

These baseline runs changed only benchmarks and documentation; the native disk
index was implemented afterward. Baseline verification passed: 62 focused sync/search regression
tests, seven search UI rendering/pagination tests, six existing backend sync
reliability tests, both completed client benchmark sizes and all three backend
benchmark sizes. Analysis of the changed Dart files and a ten-conversation full
snapshot smoke run passed. The memory failures and large-sync timeout above are
recorded load-test outcomes, not successful capacity claims.

To repeat the tests from the repository root:

```sh
cd app
dart run tool/search_benchmark.dart 10000 200 51
# Isolate search from the memory-heavy full snapshot benchmark:
dart --old_gen_heap_size=4096 run tool/search_benchmark.dart 100000 200 51 --search-only
SYNC_LOAD_SIZES=1000,10000 SYNC_LOAD_OUTPUT=/tmp/client-sync.json \
  flutter test test/sync_load_benchmark_test.dart --reporter expanded
cd ../backend
SYNC_BACKEND_SIZES=1000,10000,100000 SYNC_BACKEND_OUTPUT=/tmp/backend-sync.json \
  dotnet test Lifenizer.Tests --filter SyncLoadBenchmarkTests
```

The sync load tests skip unless their size environment variable is set.
Completed runs remove their temporary vaults; a test timeout can leave a fixture
to remove after the runner exits. Optional JSON output contains only synthetic
measurements.
