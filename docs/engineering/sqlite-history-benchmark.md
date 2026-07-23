# SQLite History Benchmark

## Protocol

Run `make persistence-benchmark`. The Release executable creates a fresh schema-v8 database, writes deterministic synthetic daily history in transactions of 500 rows, executes the root-bounded seven-day top-100 growth query 25 times, applies the 7/30-day retention transaction, truncates WAL, and reports JSON. The query root is `/Benchmark`; paths use only `/Benchmark/pNNNNNNN`; no user data is read.

The workload contains 35 daily samples per synthetic directory. Retention removes samples older than day 30. Reported database size includes the main database, WAL, and SHM after retention and checkpoint. `writeBatchP95Milliseconds` is the p95 of 500-row transaction times. This is a persistence benchmark, not a filesystem enumeration benchmark.

## 2026-07-24 result

Environment: Apple M5, 16 GiB RAM, macOS 26.5.2 (25F84), Xcode 26.1.1 (17B100), internal storage, AC power, Low Power Mode off, nominal thermal state.

| Rows | DB bytes | Peak RSS | 500-row write p95 | top-100 7-day p95 | Retention | Checkpoint |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500,000 | 111,063,040 | 106,315,776 | 5.62 ms | 118.20 ms | 430.76 ms | 0.31 ms |
| 1,000,000 | 222,142,464 | 108,920,832 | 5.76 ms | 256.98 ms | 966.59 ms | 0.30 ms |

Both datasets pass the current-host gates of database <250 MB, peak RSS <150 MiB, 500-row write p95 <100 ms, and seven-day top-100 p95 <500 ms. Incremental logical deltas written with each bucket avoid repeated endpoint joins in the top-growth query. The measured query includes the production equality/prefix root constraint and interval coverage fields used by the application read port. These results do not qualify macOS 15.6 or minimum-reference hardware.
