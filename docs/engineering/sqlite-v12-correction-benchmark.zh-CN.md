# SQLite v12 更正物理原型证据

最后更新：2026-08-13

## 范围

这份证据在任何生产迁移把 `PRAGMA user_version` 提升到 12 之前，冻结
ADR-008 的暂定物理结构。它在已发布的 v11 不可变观测账本上增加紧凑的校准
修订、已注册更正输入、线性更正投影 work/checkpoint、完整替换的
finding/rank/reason，以及 current-effective 查询索引。它不表示迁移、仓库事务、
恢复、保留策略、UI 接入、macOS 15.6 资格、签名、公证或发布分发已经完成。

原型复用 v11 不可变观测节点及其两种度量端点。一条紧凑记录同时表示一次完整
节点观测的小时与日修订；不同的公开修订 ID 由数据库分配的 node ID 加桶判别码
确定性派生。更正负载会为 2% 的保留节点添加真实的同小时/同日替换扫描，并把
每个 successor 连接到准确的旧节点；同时加入同帧完整更正投影，包括合法空结果。

## 复现

```bash
swift test --package-path Packages/SpaceTraceKit \
  --filter SQLiteHistoricalCorrectionPhysicalDesignTests
swift run --package-path Packages/SpaceTraceKit \
  SpaceTracePersistenceBenchmark --historical-corrections
```

benchmark 每次只运行一个临时 SQLite 数据库，场景结束后立即删除。结果写到
`FileManager.default.temporaryDirectory` 下的
`SpaceTrace-v12-historical-corrections.json`；本次报告 SHA-256 为
`f235ace99c9352c1cb053f978781f97c2e53b582b8ce71cf7fabbd9f0640a706`。

## 固定负载

- 请求保留 500,000 和 1,000,000 个目录样本。
- 先写入五天过期数据，删除后保留 25 天。
- 每个共享节点都有 logical 与 allocated 两个 v11 端点。
- 覆盖无更正、2% 同桶校准与更正投影负载、50/50 v10 历史/v11 节点共存。
- 继承冻结 v11 负载的稳定身份、分类、路径/ID 字节分布、帧提交、
  work/checkpoint、finding、WAL checkpoint、secure delete、integrity/FK、
  `dbstat` 与 query plan 证据。
- 更正负载在 500k/1M 下分别保留 47 个完整更正投影和 18,424/36,848 个
  替换 finding。

## 当前主机结果

主机：MacBook Air、Apple M5、16 GB 内存、macOS 26.6.1 (25G76)、内部
APFS 存储。这些是当前主机的持久化结果，不是最低 macOS 或最低参考硬件资格。

| 请求样本 | 场景 | 保留 v11 节点 | v12 修订行 | 更正投影 / finding | 维护前 main+WAL+SHM | 最终 main+WAL+SHM | 修订 P95 | 投影 P95 |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 500,000 | 无更正 | 500,000 | 480,000 | 0 / 0 | 149,007,600 B | 109,731,840 B | 0.799 ms | 0.053 ms |
| 500,000 | 2% 更正负载 | 500,000 | 480,000 | 47 / 18,424 | 170,616,640 B | 118,034,432 B | 0.860 ms | 0.044 ms |
| 500,000 | v10→v12 共存 | 250,000 | 240,000 | 0 / 0 | 132,191,920 B | 106,176,512 B | 0.671 ms | 0.030 ms |
| 1,000,000 | 无更正 | 1,000,000 | 960,000 | 0 / 0 | 299,248,080 B | 220,418,048 B | 0.703 ms | 0.029 ms |
| 1,000,000 | 2% 更正负载 | 1,000,000 | 960,000 | 47 / 36,848 | 341,543,528 B | 237,023,232 B | 0.756 ms | 0.050 ms |
| 1,000,000 | v10→v12 共存 | 500,000 | 480,000 | 0 / 0 | 264,027,400 B | 212,590,592 B | 0.691 ms | 0.024 ms |

六个场景都得到 `integrity_check=ok`、零外键违规、`secure_delete=ON`，且
WAL 截断后为 0 字节。最大的最终场景为 237,023,232 字节，相对
250,000,000 字节的维护后门禁还剩 12,976,768 字节。维护前体积如实记录，
但不受长期存储门禁约束。

## 冻结边界

- v12 对象清单含 8 张表、7 个索引和 15 个具名验证/不可变触发器；更正对象
  digest 为 `e3fcbb2d62f319f3dde2e1deb184a30c0acd5a13691a2ae8e0d903eef1796b25`。
- 修订写入要求完整且已提交的节点、小时/日链上准确同 key 的终态前驱、耐久的
  32 字节 payload digest，以及有界派生身份。
- 更正投影要求一个已提交 v11 根投影、一份冻结注册输入、准确前驱 digest、线性
  链归属、共同 frame/expiry 权威，以及 finding ordinal、rank ordinal、reason
  数量均完整的原子 checkpoint。
- 未知 code、跨帧 finding、陈旧 digest、分支、自链接、不完整 checkpoint 图和
  checkpoint 后追加子记录都会封闭失败。
- schema v12 迁移必须使用这些准确 SQL 对象和 digest，否则必须先重新评审本证据。
  在独立迁移与 released fixture 任务通过前，当前生产 schema 仍保持 v11。
