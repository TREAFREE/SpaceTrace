# Glossary

| Term | Definition |
|---|---|
| Observation | A timestamped fact collected from a supported macOS data source without changing user data. |
| Baseline | A complete or bounded summary used as the comparison origin for later observations. |
| Calibration scan | A scheduled bounded scan that corrects drift or gaps in incremental event processing. |
| Delta | The observed size change between two comparable summaries using the same measurement basis. |
| Attribution | A reasoned association between an observed delta and a directory, snapshot, application family, or storage category. It is not process causality unless explicitly proven. |
| Classification | A deterministic mapping from evidence such as path patterns and bundle metadata to a known category. |
| Confidence | A visible level indicating how strongly available evidence supports an attribution. |
| Coverage | The set of paths and system sources SpaceTrace was allowed and able to observe during a time window. |
| Coverage gap | A path, time range, or data source that could not be observed or was invalidated. |
| Full Disk Access (FDA) | A macOS privacy permission that expands readable coverage. It does not authorize SpaceTrace to delete or modify data. |
| Logical size | File length visible to the file system; it may differ from physical allocated bytes. |
| Allocated size | Storage blocks physically allocated, subject to APFS sharing, compression, clones, and purgeable behavior. |
| Snapshot | An APFS or Time Machine point-in-time view that may retain storage not visible through ordinary directory traversal. |
| Source adapter | A versioned boundary that converts one macOS API or command output into SpaceTrace domain records. |
| Diagnostic bundle | A user-initiated export containing redacted system and observation metadata for support or bug reports. |
| Read-only core | The product rule that observation and explanation paths do not delete files, kill processes, or mutate protected system state. |
