# SQLite History Benchmark

## Protocol

Run `make persistence-benchmark`. The legacy mode creates a fresh current-schema database, writes deterministic synthetic daily history in transactions of 500 rows, executes the root-bounded seven-day top-100 growth query 25 times, applies the 7/30-day retention transaction, truncates WAL, and writes JSON to the process temporary directory. The query root is `/Benchmark`; paths use only `/Benchmark/pNNNNNNN`; no user data is read.

The workload contains 35 daily samples per synthetic directory. Retention removes samples older than day 30. Reported database size includes the main database, WAL, and SHM after retention and checkpoint. `writeBatchP95Milliseconds` is the p95 of 500-row transaction times. This is a persistence benchmark, not a filesystem enumeration benchmark.

## 2026-07-24 result

Environment: Apple M5, 16 GiB RAM, macOS 26.5.2 (25F84), Xcode 26.1.1 (17B100), internal storage, AC power, Low Power Mode off, nominal thermal state.

| Rows | DB bytes | Peak RSS | 500-row write p95 | top-100 7-day p95 | Retention | Checkpoint |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500,000 | 111,075,328 | 106,397,696 | 8.01 ms | 156.78 ms | 551.98 ms | 0.38 ms |
| 1,000,000 | 222,154,752 | 108,953,600 | 7.10 ms | 377.66 ms | 1,173.45 ms | 0.38 ms |

Both datasets pass the current-host gates of database <250 MB, peak RSS <150 MiB, 500-row write p95 <100 ms, and seven-day top-100 p95 <500 ms. Incremental logical deltas written with each bucket avoid repeated endpoint joins in the top-growth query. The measured query uses an indexable equality/binary-range root constraint rather than `LIKE`; `%` and `_` in valid names do not broaden scope. An earlier schema-v9 run exposed 1000000-row p95 variability above the gate while the older `substr` root predicate was used. Replacing that predicate with the reviewed indexable range restored the complete benchmark to 377.66 ms; the correctness suite still proves that out-of-root paths are excluded. These results do not qualify macOS 15.6 or minimum-reference hardware.

## Earlier provisional SQLite v11 physical model — superseded 2026-08-12

This section preserves the pre-migration schema-selection evidence. Its numbers and `v11-prototype` command are historical and are superseded by the final repository-backed result below. The prototype created the complete proposed table/index/trigger set on top of a current-schema application database. Its shared directory node stored logical and allocated endpoint values separately, derived final endpoint IDs rather than storing them, enforced frame closure at the commit marker, and used `auto_vacuum=FULL`, an 8 MiB SQLite page-cache limit, `mmap_size=0`, `temp_store=FILE`, `secure_delete=ON`, and a truncated WAL.

The deterministic workload retains exactly 25 days and first inserts five older days that retention must remove. A retained directory sample therefore represents one shared node and two metric endpoints. The matrix covers the primary one-scope shape, 100-scope/high-frame-count shape, 100% stable evidence, 2% stable-object movement per daily transition, and a bounded 50/50 v10→v11 overlap. Complete per-object `dbstat` and query-plan evidence are present in the JSON result; each scenario database is removed before the next starts, so benchmark artifacts do not accumulate.

Commands:

```sh
swift run --package-path Packages/SpaceTraceKit -c release \
  SpaceTracePersistenceBenchmark --mode v11-prototype \
  --directory-samples 500000 --scenario matrix

swift run --package-path Packages/SpaceTraceKit -c release \
  SpaceTracePersistenceBenchmark --mode v11-prototype \
  --directory-samples 1000000 --scenario matrix
```

The results are written atomically as `SpaceTrace-v11-prototype-<count>.json` under `FileManager.default.temporaryDirectory`. The measured files had SHA-256 `4b80f0850124690e4b9e089434a0010fddf1375b7db6e22c863d4f9006aab0c0` (500k) and `bd1d9244d454fb4ae554b4795f22300488066114d44009a27c88782989f3f1f9` (1M).

Environment: Apple M5, 16 GiB RAM, macOS 26.6.1 (25G76), Xcode 26.1.1 (17B100), internal storage. Power, thermal, and Low Power Mode state were not captured, so insertion time is diagnostic rather than a release performance qualification.

| Retained samples | Scenario | Retained v11 / legacy | Findings | DB + WAL + SHM | Peak RSS | Insert | Retention |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 500,000 | no-change | 500k / 0 | 0 | 99,393,536 B | 52,658,176 B | 21.27 s | 447 ms |
| 500,000 | high-frame-count | 500k / 0 | 0 | 106,266,624 B | 55,443,456 B | 19.23 s | 524 ms |
| 500,000 | all-stable | 500k / 0 | 0 | 114,712,576 B | 57,475,072 B | 25.47 s | 556 ms |
| 500,000 | 2%-churn | 500k / 0 | 19,200 | 104,468,480 B | 57,475,072 B | 21.79 s | 566 ms |
| 500,000 | v10→v11 overlap | 250k / 250k | 0 | 106,778,624 B | 86,671,360 B | 8.55 s | 360 ms |
| 1,000,000 | no-change | 1M / 0 | 0 | 200,863,744 B | 93,159,424 B | 50.50 s | 928 ms |
| 1,000,000 | high-frame-count | 1M / 0 | 0 | 211,496,960 B | 93,552,640 B | 33.55 s | 912 ms |
| 1,000,000 | all-stable | 1M / 0 | 0 | 231,653,376 B | 99,188,736 B | 60.69 s | 1,134 ms |
| 1,000,000 | 2%-churn | 1M / 0 | 38,400 | 211,034,112 B | 99,188,736 B | 54.92 s | 1,198 ms |
| 1,000,000 | v10→v11 overlap | 500k / 500k | 0 | 214,056,960 B | 116,801,536 B | 23.93 s | 528 ms |

All ten cases reported `integrity_check=ok`, zero `foreign_key_check` rows, `secure_delete=ON`, and a zero-byte WAL after `wal_checkpoint(TRUNCATE)`. The 1M no-change database retained 1,000,000 nodes after removing 200,000 expired nodes; its three measured lookups used `historical_metric_endpoint_frame`, `historical_finding_baseline_endpoint`, and `historical_batch_scope`. Its largest objects were metric endpoints (44,032,000 B), shared nodes (29,700,096 B), the endpoint-frame index (26,341,376 B), the two node uniqueness indexes (15,118,336 B each), and the subject/location indexes (14,770,176 B each).

The provisional schema-freeze capacity gate passed. The codec, canonical schema digest, released fixtures, migration rollback, repository transactions, retention, recovery, and final benchmark have since passed their current-host persistence gates; see the final result below. Product release gates remain separate.

## Final repository-backed SQLite v11 result — 2026-08-12

The final operation runs inside the Persistence target with no SQL or SQLite handle exposed to the benchmark executable. It validates exact query cardinality, records pending-work, effective-finding and legacy query plans, and fails on integrity, foreign-key, size, RSS, write-p95, or query-p95 gate violations. The production v10 growth query now deliberately selects its reviewed root/path/time covering index, avoiding a large transient grouping allocation while preserving binary root bounds.

Commands:

```sh
swift run --package-path Packages/SpaceTraceKit -c release \
  SpaceTracePersistenceBenchmark --mode v11-repository \
  --directory-samples 500000 --scenario matrix

swift run --package-path Packages/SpaceTraceKit -c release \
  SpaceTracePersistenceBenchmark --mode v11-repository \
  --directory-samples 1000000 --scenario matrix
```

Output SHA-256: `aa7935f83fb07262119108a78dc666a4fefd522e4989b4ee19795dd3e71a941d` (500k) and `871713e9768b75436222d337d9fa17409762bf46c38997f7890f072d649259e5` (1M).

| Samples | Scenario | DB+WAL+SHM | Peak RSS | Endpoint p95 | Finding p95 | Pending p95 | Effective Top 10 p95 | Legacy 7-day Top 100 p95 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500,000 | no-change | 99,393,536 B | 54,476,800 B | 27.18 ms | — | 0.004 ms | 9.14 ms | — |
| 500,000 | high-frame-count | 106,266,624 B | 54,476,800 B | 6.23 ms | — | 0.114 ms | 0.12 ms | — |
| 500,000 | all-stable | 114,712,576 B | 58,359,808 B | 31.25 ms | — | 0.003 ms | 11.28 ms | — |
| 500,000 | 2%-churn | 104,390,656 B | 58,359,808 B | 28.00 ms | 10.61 ms | 0.004 ms | 38.63 ms | — |
| 500,000 | v10→v11 overlap | 107,061,248 B | 86,933,504 B | 24.38 ms | — | 0.004 ms | 6.40 ms | 21.22 ms |
| 1,000,000 | no-change | 200,863,744 B | 89,112,576 B | 31.33 ms | — | 0.003 ms | 22.28 ms | — |
| 1,000,000 | high-frame-count | 211,496,960 B | 89,112,576 B | 14.01 ms | — | 0.151 ms | 0.22 ms | — |
| 1,000,000 | all-stable | 231,653,376 B | 102,105,088 B | 39.52 ms | — | 0.004 ms | 26.96 ms | — |
| 1,000,000 | 2%-churn | 210,874,368 B | 102,105,088 B | 46.69 ms | 20.48 ms | 0.004 ms | 142.02 ms | — |
| 1,000,000 | v10→v11 overlap | 214,601,728 B | 114,032,640 B | 42.03 ms | — | 0.004 ms | 11.59 ms | 75.75 ms |

The current-host hard gates pass for every scenario: database below 250,000,000 bytes, peak RSS below 150,000,000 bytes, endpoint/finding chunks at or below 100 ms p95, and both query families at or below 500 ms p95. All cases reported `integrity_check=ok`, no foreign-key violations, `secure_delete=ON`, and zero WAL bytes after truncation. Full transaction, recovery, privacy, distribution, and non-claim details are in [SQLite v11 Historical Ledger](sqlite-v11-historical-ledger.md) and its [Chinese translation](sqlite-v11-historical-ledger.zh-CN.md).
