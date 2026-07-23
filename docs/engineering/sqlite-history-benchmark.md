# SQLite History Benchmark

## Protocol

Run `make persistence-benchmark`. The Release executable creates a fresh schema-v8 database, writes deterministic synthetic daily history in transactions of 500 rows, executes the seven-day top-100 growth query 25 times, applies the 7/30-day retention transaction, truncates WAL, and reports JSON. Paths use only `/Benchmark/pNNNNNNN`; no user data is read.

The workload contains 35 daily samples per synthetic directory. Retention removes samples older than day 30. Reported database size includes the main database, WAL, and SHM after retention and checkpoint. `writeBatchP95Milliseconds` is the p95 of 500-row transaction times. This is a persistence benchmark, not a filesystem enumeration benchmark.

## 2026-07-23 result

Environment: Apple M5, 16 GiB RAM, macOS 26.5.2 (25F84), Xcode 26.1.1 (17B100), internal storage, AC power, Low Power Mode off, nominal thermal state.

| Rows | DB bytes | Peak RSS | 500-row write p95 | top-100 7-day p95 | Retention | Checkpoint |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500,000 | 111,063,040 | 104,775,680 | 5.40 ms | 103.07 ms | 424.08 ms | 0.29 ms |
| 1,000,000 | 222,142,464 | 108,707,840 | 5.61 ms | 207.00 ms | 992.09 ms | 0.28 ms |

Both datasets pass the current-host gates of database <250 MB, peak RSS <150 MiB, 500-row write p95 <100 ms, and seven-day top-100 p95 <500 ms. Incremental logical deltas written with each bucket avoid repeated endpoint joins in the top-growth query. These results do not qualify macOS 15.6 or minimum-reference hardware.
