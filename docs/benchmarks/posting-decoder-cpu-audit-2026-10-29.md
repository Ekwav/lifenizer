# Posting decoder CPU audit — 2026-10-29

The unapplied proposal reduces decoder work without changing scoring, cache format, callback order, or validation. It replaces the posting visitor’s generator with ascending set-bit iteration, adds a one-byte varint fast path, and uses gzip ISIZE only as an initial allocation hint clamped to 64–65,536 bytes. CRC, truncation, actual decoded size, and excluded-document position validation remain enabled.

AOT measurements used 1,666 actual posting rows from `archive import` on the 100,000-document fixture, with three warmups and 30 measured rounds. These are in-memory CPU measurements; they exclude SQLite and encryption and do not prove the two-million-document latency target.

| Work | Baseline median | Proposed variant median |
| --- | ---: | ---: |
| Posting score parsing | 16.84 ms | 8.24 ms |
| Posting position-list parsing | 20.36 ms | 11.62 ms |
| Gzip decoding with bounded output-capacity hint | 44.52 ms | 39.03 ms |

The allocation-hint timing used a 32 KiB upper bound; the proposed 64 KiB bound is covered by correctness checks, but has not been separately timed. All 52 native-search, authored-relevance, and posting-codec tests passed against the private proposed implementation. Another 2,000 actual-stream mutation comparisons preserved positions, score callbacks, rejection, and callback order; 1,428 gzip comparisons preserved outcomes for valid, truncated, corrupted, concatenated, and large streams.

A separate gzip level-0 experiment decoded tails in 4.89 ms versus 44.52 ms, but increased full clear posting payload bytes by 1.64× for these rows. **Level 0 is not in the proposal**; copied-database disk growth and complete-query I/O measurements are still required. Interval headers and extra scoring prepasses are also excluded after weak or negative pruning results.

- [Unapplied patch](../../app/build/benchmarks/phrase-bounds-audit-20261029/proposal/decoder-proposal.patch), SHA-256 `5cdac3f0cb08bfacd4d0c8790bab60ea972bce933fa16c4f2eea6c245671250b`.
- [Exact base/proposed hashes and validation manifest](../../app/build/benchmarks/phrase-bounds-audit-20261029/proposal/manifest.json).
- [Raw CPU audit and source hashes](../../app/build/benchmarks/phrase-bounds-audit-20261029/cpu-audit.json), [raw timing samples](../../app/build/benchmarks/phrase-bounds-audit-20261029/posting-rows.json.popbits.json), [focused test log](../../app/build/benchmarks/phrase-bounds-audit-20261029/proposal/focused-tests.log).
- [Bounds and prepass audit](../../app/build/benchmarks/phrase-bounds-audit-20261029/audit.json).

Raw scratch artifacts are local and gitignored. Benchmark processes used a 2,000,000,000-byte memory cap with swap disabled; peak measured RSS was about 256 MiB. No production engine or source fixture was modified for this proposal.
