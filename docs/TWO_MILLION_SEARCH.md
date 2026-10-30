The actual 2,000,000-conversation search gate completed on 2026-10-29, but the original 500 ms p95 target remains unmet. All 120 query cases and 32 authored relevance judgments completed. On 2026-10-29, the user accepted the later eight-worker pilot’s approximately 583 ms warm p95 for now, so the strict 500 ms target no longer blocks delivery. That acceptance applies to the measured pilot; the full default-production gate below reports its own measurements.

Each conversation has 200 words and 10 segments. The gate used frozen executable `1dce43b6…`, five query families with 24 cases each, and a fresh prepared worker per case. Preparation is reported separately in the [complete raw proof](benchmarks/two-million-dense-query-2026-10-29.json). The OS page cache was uncontrolled.

| Query family | Prepared-first p95 (ms) | Warm p95 (ms) |
| --- | ---: | ---: |
| Ordinary | 1711.371 | 910.127 |
| Names | 835.461 | 482.346 |
| Prefix | 635.072 | 239.000 |
| Fuzzy | 453.754 | 365.377 |
| Broad | 2189.926 | 1750.934 |

The query gate retained the actual 2M summary catalog. Peak process RSS was 1,827,323,904 bytes; cgroup memory reached its 1,999,998,976-byte cap, with no OOM events and zero swap. The gate completed in 419.661 seconds and exited with `latency-target-missed` after finishing all correctness checks.

The preceding [2M build](benchmarks/two-million-native-build-2026-10-29.json) resumed 1,604,608 committed conversations and added 395,392. It passed catalog, representative full-body reopen, 100-conversation update, three-conversation deletion/restoration, and persistence checks. The update and its verification took 7,985 ms; build peak RSS was 1,865,588,736 bytes, with no OOM events or swap.

All 120 latency cases returned 100 results. The 32 authored judgments passed, their 20 original full conversation bodies were restored, and the final 2M catalog checksum matched its initial checksum. The recorded ranking evidence contains only the first 10 IDs per latency case; this run does not establish independent golden ordering for all 100 results. The immutable archive and all 160 frozen source hashes are identified in the raw proof. A later harness change to record all 100 IDs does not apply to this run.

These measurements cover the native search engine and real summary catalog. Whole Flutter/GTK memory and actual 2M wire synchronization remain unmeasured.

The word index is already stored on disk. Finding a posting is only the first part of this search: the engine authenticates encrypted pages, expands prefixes and typos, intersects matches, and ranks candidates using term frequencies, positions, dates and source weights. A broad query can still score over a million matches to prove which 100 rank highest. The result limit bounds retained results; it does not limit that work. In the later packed-catalog pilot, the eight-worker warm samples read only 0.53 MiB from storage in total, so faster disk access alone would not remove their CPU cost.

A subsequent [read-only parallel pilot](benchmarks/two-million-parallel-readonly-pilot-2026-10-29.json) retained the actual 2M catalog. Four workers completed 60 ordered-result and IEEE-score comparisons against the single-worker baseline. Across 40 warm samples, p95 fell from 2637.247 to 1025.241 ms; aggregate wall time fell 63.4% while CPU time rose 19.3%. Process peak RSS reached 1,944,383,488 bytes. The eight-worker stage hit the 2 GB cgroup limit before completing a query; twelve workers were not started. Kernel evidence shows anonymous-memory pressure, but cannot distinguish Dart heap/GC from native allocations. Read-only handles and unchanged source file metadata were verified. This 20-criterion pilot does not replace the full acceptance gate or meet its 500 ms target.

The [packed-catalog/native-batch follow-up](benchmarks/two-million-packed-native-batch-parallel-pilot-2026-10-29.json) completed all four stages with no OOM or swap. All 2M summaries used the packed representation, and their all-fields checksum matched the previous uncompressed catalog. All 240 samples returned 100 results; the 180 parallel samples matched the single-worker baseline's ordered IDs and IEEE scores. Peak process RSS was 1,807,736,832 bytes; cgroup usage reached its 1,999,998,976-byte cap.

| Workers | Warm p95 (ms) | Timed warm-query CPU (s) | Warm physical reads (MiB) |
| ---: | ---: | ---: | ---: |
| 1 | 1748.658 | 35.14 | 0.14 |
| 4 | 786.762 | 50.60 | 1.95 |
| 8 | 583.116 | 68.84 | 0.53 |
| 12 | 614.489 | 85.20 | 27.98 |

Each row covers 40 warm samples after 20 warmup queries, with the same worker pool reused. CPU values exclude catalog hashing, preparation, and other work outside query timers. Stages ran sequentially with a fixed query clock of 2026-10-28; the OS page cache was uncontrolled. Eight workers had the best p95 in this pilot. Twelve reduced aggregate warm wall time only 1.3% further, while using 23.8% more query CPU. This 20-criterion prototype pilot does not replace the full 120-case/32-judgment gate.

Production now automatically selects up to eight readers from 250,000 conversations, capped by the available CPU count. A later query-only native inflater preserves the existing managed ingestion and storage format. The full default-path gate below now measures their combined latency and memory use; the earlier pilot remains a separate workload.

The delivery review also fixed repeated body fallback after cache corruption and the reopened 999-to-1,000 conversation transition. Both regressions failed without their fixes; the corrected tree passed all 879 tests (two opt-in load tests skipped), clean analysis, eight supervisor tests, and the 1,000-item backend sync fixture. The [validation record](benchmarks/default-production-search-validation-2026-10-29.json) preserves the earlier build evidence and the follow-up checks separately.


## Full default-production gate

The recovered gate completed on 2026-10-29 using the frozen default production executable, with automatic eight-reader selection and no worker override. All 120 latency cases returned 100 results, all 32 authored relevance judgments passed, and all 20 temporary original bodies were restored. The retained catalog checksum was unchanged. The [complete result](benchmarks/two-million-default-production-query-2026-10-29.json) preserves every latency case’s 100 result IDs and its invocation-bound completion.

| Query family | Prepared-first p95 (ms) | Warm p95 (ms) |
| --- | ---: | ---: |
| Ordinary | 533.820 | 375.861 |
| Names | 296.808 | 463.692 |
| Prefix | 566.965 | 139.173 |
| Fuzzy | 627.901 | 438.004 |
| Broad | 619.934 | 691.590 |

The run took 418.830 seconds. Peak process RSS was 1,905,676,288 bytes; cgroup memory reached its 1,999,998,976-byte cap, with no OOM events or swap. First-query timings exclude initialization; preparation p95 ranged from 878 to 1,025 ms by family. The OS page cache was uncontrolled. Native AES and posting inflation were active, and the mapped zlib 1.3.2 library was captured and hashed.

The strict 500 ms gate correctly exited with `latency-target-missed`. The accepted 583 ms pilot result remains valid for that earlier pilot; this full gate’s broad warm p95 is higher at 692 ms. Correctness and relevance passed, while neither the original 500 ms target nor a universal 583 ms limit is established by this full run. Whole Flutter/GTK memory and actual 2M wire synchronization remain unmeasured. The executable preceded the two app-state recovery fixes, which have separate 879-test follow-up evidence above.


## Query-local scratch reuse

Commit `ed1681a` reuses bounded numeric-page scratch buffers within each query, clearing them between pages. All 58 focused tests, clean analysis and the compiled 1,000-item smoke passed. The [full 2M comparison](benchmarks/two-million-scratch-reuse-query-2026-10-29.json) retained the same ordered 100 IDs for all 120 latency cases and the same ordered results for all 32 authored relevance judgments. The catalog checksum and all restored bodies were preserved.

| Query family | Prepared-first p95 (ms) | Warm p95 (ms) |
| --- | ---: | ---: |
| Ordinary | 882.206 | 536.495 |
| Names | 1046.931 | 426.723 |
| Prefix | 795.732 | 803.048 |
| Fuzzy | 285.598 | 214.807 |
| Broad | 407.400 | 545.356 |

Broad warm p95 fell from 691.590 to 545.356 ms in this comparison, while ordinary/name/prefix tails regressed. These single before/after runs use a shared machine with uncontrolled OS page cache, so they do not isolate the change from other timing variation. The strict 500 ms gate remains unmet, and the run does not establish a universal 583 ms limit. Cgroup peak was 1,973,964,800 bytes, with zero `memory.max` events, OOMs and swap; the run took 494.737 seconds. The earlier 583 ms pilot acceptance remains a separate measurement.


## Reader-only numeric preparation

Commit `6d7ecff` keeps writer migrations and metadata preparation, but avoids hydrating the writer’s numeric cache immediately before discarding it for parallel readers. Serial preparation still hydrates normally. All 74 focused checks, clean analysis and the compiled smoke passed. The [full 2M comparison](benchmarks/two-million-writer-prepare-query-2026-10-30.json) preserved all 120 ordered top-100 lists and all 32 authored relevance results against the scratch-only run; the catalog and restored bodies were preserved.

| Query family | Preparation p95 (ms) | Prepared-first p95 (ms) | Warm p95 (ms) |
| --- | ---: | ---: | ---: |
| Ordinary | 645.878 | 332.076 | 545.194 |
| Names | 594.682 | 214.833 | 165.470 |
| Prefix | 619.948 | 190.858 | 142.441 |
| Fuzzy | 579.791 | 202.757 | 449.264 |
| Broad | 433.386 | 680.921 | 624.723 |

Preparation p95 roughly halved across all families, and total run time fell from 494.737 to 316.773 seconds. Cgroup peak fell from 1,973,964,800 to 1,908,953,088 bytes, with no limit events, OOMs or swap. Broad query tails were worse than the scratch-only run, and the strict 500 ms query gate still failed. The before/after runs do not isolate shared-machine timing variation; preparation improvements must not be presented as proof of the query-latency target.
