# Native million-conversation search, 2026-10-28

The native implementation uses encrypted SQLite pages, bounded query buffers and
lazy transcript bodies. Search returns at most 100 results from the whole archive.
Pages are allocated separately for consumed media, scans/documents, email, chats
and other sources; ranking and document frequencies remain global.

## Results

**Passed at 1,000,000 conversations averaging 200 words, with at most 100 search
results, under a hard 2 GB memory cap and no swap.** Peak process RSS was
1,564,905,472 bytes (1.565 GB). The whole cgroup, including filesystem cache,
reached its kernel-rounded limit of 1,999,998,976 bytes. It recorded memory
pressure/reclaim events, with zero OOM events or kills. This demonstrates bounded
operation at the cap, rather than unused cgroup memory headroom.

The encrypted search sidecar, including lazy full-body copies, occupied
2,442,194,944 bytes (2.44 GB) on disk. This excludes original vault chunks,
server sync history and media. Opening the index and hydrating all one million
summaries took 34.93 seconds, before the subsequent checksum verification.
Updating 100 records and verifying their new searchable term took 2.319 seconds.
Deletion, reinsertion and another full-body reopen also passed.

| Query | Observed latency | Results |
| --- | ---: | ---: |
| `insurance renewal` (100 matches) | 3.09–3.72 s | 100 |
| Typo/prefix `insuranc alice` | 3.10–3.37 s | 100 |
| German `MÜLLER` | 1.95–2.26 s | 100 |
| Missing-term intersection | 1.58–1.68 s | 0 |
| `archive` (all million match) | 139.60–194.47 s | 100 |
| Cached recent results | 5.23–6.22 ms | 100 |

Each ordinary query ran twice before and twice after reopen; these ranges are
samples, not p95 estimates. The first recent-item query needed 15.94 seconds to
build its frontier. Broad text searches remain slow because exact ranking still
scores every matching page. The result cap bounds retained results and memory;
it does not bound scoring work. Cancellation keeps obsolete queries from holding
up new ones. This change establishes capacity, not instant broad search.

| Source partition | Conversations | Broad `archive` query after reopen |
| --- | ---: | ---: |
| Consumed media | 98,432 | 16.04 s |
| Scans/documents | 98,432 | 15.40 s |
| Email | 98,432 | 16.09 s |
| Chat | 98,432 | 15.21 s |
| Other | 606,272 | 87.01 s |

Filters check the full partition and return its best 100. The fixture is uneven:
its first 507,904 records are manual notes, then sources alternate in 128-record
runs. Global and filtered searches passed membership and cap assertions before
and after reopening; repeated global queries also verified deterministic order.

The final capped invocation exited successfully after 32 minutes 47.62 seconds.
It resumed 724,480 committed records; its 840.386-second build phase includes
catalog hydration and appending the remaining 275,520. Neither duration is a
fresh million-item build measurement. An earlier attempt used RAM-backed `/tmp`
and was OOM-killed because the database itself consumed the cap; the fixture was
verified and moved to ext4, and the tool now rejects tmpfs/ramfs. A subsequent
ext4 build was intentionally stopped for transaction tuning, not a capacity
failure. These attempts are preserved alongside the successful result.

See [the assertion-checked report and independent exit evidence](benchmarks/million-search-2026-10-28.json).

## Measurement scope

The benchmark is an AOT Dart process running the production native search engine
with the actual one-million-object summary catalog retained through build, search,
updates and reopen. Every conversation has 200 words in ten segments, UUID IDs,
participant references, dates and a 180-character preview. The filler vocabulary
has 1,723 words from repository documentation, plus distinct numeric titles.
This is synthetic data, not a natural language relevance evaluation.

A systemd cgroup enforces 2,000,000,000 bytes of memory and disables swap. This
includes the worker isolate and charged filesystem cache. The SQLite database
is on ext4. The test rejects a RAM-backed database or an uncapped million-item
run. Its result is written only after every assertion passes.

The measurement covers the engine and real catalog, rather than the entire
Flutter/GTK application. Native app integration is covered separately by tests
and release builds. Browser search retains the existing in-memory path; the
million-item memory claim does not apply to the browser. Phone hardware, WAN
latency and a million-item end-to-end sync have not been measured.

## Sync measurements with the new native index

The real app state, encryption, SQLite worker and fsynced chunk files were tested
with a local HTTP mock providing 500-envelope download pages. Synthetic device
keys exclude passphrase derivation. These runs overlapped other work on the
shared development machine and are not network or S3 benchmarks.

| Starting conversations | Initial sync | 101 remote updates | Upload 601 and pull echo | Cached offline unlock |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 2.93 s | 1.00 s | 3.24 s | 0.035 s |
| 10,000 | 97.63 s | 10.55 s | 17.11 s | 0.120 s |

Both runs verified searches, all 200 transcript words after offline restore,
cursors and empty outboxes. Uploads split into `[100,100,100,100,100,100,1]`;
100 edits to one participant coalesced into one envelope and respected the
20-second automatic upload window. No-op sync uploaded nothing. At 10,000 the
initial run performed two full builds and 18 incremental updates, compared with
19 full builds in the earlier baseline. Persistence remains expensive: changed
canonical hash chunks can require many encrypted body-page reads. These results
do not establish million-item sync speed.

See [raw native sync measurements](benchmarks/native-sync-2026-10-28.json) and
[the earlier search/sync baseline](LOAD_TESTS.md).

A 2026-10-29 rerun with the v6 numeric index, summary-only result tiles and
managed gzip passed both sizes again. These shared-machine measurements
overlapped the full test suite and small index probes:

| Starting conversations | Initial sync | 101 remote updates | Upload 601 and pull echo | Cached offline unlock |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 2.66 s | 0.98 s | 3.09 s | 0.056 s |
| 10,000 | 110.99 s | 10.14 s | 22.07 s | 0.197 s |

Uploads again split into six batches of 100 plus one; cursors, empty outboxes,
participant-edit coalescing and updated 200-word bodies all passed. The
`indexing` progress stage dominated at 10,000, but also includes subsequent
cache/save work. A participant rename still triggered a full index refresh;
these runs identify remaining persistence and metadata-update costs. Maximum
sampled RSS was 410 MB including the test harness and synthetic server, rather
than a peak or a capped capacity measurement. See the
[managed-gzip raw results and measurement scope](benchmarks/native-sync-managed-2026-10-29.json).
The [earlier native-gzip rerun](benchmarks/native-sync-v6-2026-10-29.json) is
preserved separately; different shared workloads limit timing comparisons.

## Build tuning

A controlled append probe at about 725,000 stored rows added 2,048 conversations
with unchanged durability settings. With a 16 MiB SQLite cache, 128-record
transactions took 25.04 seconds; 1,024-record transactions took 5.08 seconds.
Increasing the cache to 128 MiB gave little additional benefit after warming.
The implementation keeps the 16 MiB cache and batches new records by 1,024;
requests containing existing records use 128-record transactions to bound
randomly decrypted pages. Physical document pages still contain 128 records.
See [probe method and raw measurements](benchmarks/native-index-batching-2026-10-28.json).

## Repeat

From `app/`, using an installed Dart/Flutter SDK and a real disk directory:

```sh
dart build cli --target=tool/million_search_benchmark.dart --output=build/million-cli
python3 tool/run_million_search_benchmark.py \
  --executable build/million-cli/bundle/bin/million_search_benchmark \
  --directory build/benchmarks/million-search \
  --unit lifenizer-search-million
```

The supervisor waits for actual process exit and writes `completion.json`.
`result.json` is the benchmark's assertion-checked report. Use `--resume` only
with the same synthetic fixture to reuse committed rows after an interruption.

```sh
SYNC_LOAD_SIZES=1000,10000 SYNC_LOAD_OUTPUT=/tmp/native-sync.json \
  flutter test test/sync_load_benchmark_test.dart --reporter expanded
```

## Verification

Flutter analysis passed. The full suite passed 775 tests with two opt-in load
tests skipped; the two explicit native sync load tests then passed separately.
After the final save-race and lock-retry fixes, all 17 native integration tests
and 22 focused engine, identity, lock, source and UI regressions passed. Linux
and web release builds passed on the final implementation. Native coverage
includes corrupted cache recovery, interrupted chunk growth/cleanup, unsent
edits, lazy partial-thread merging, cancellation and participant redirects.
