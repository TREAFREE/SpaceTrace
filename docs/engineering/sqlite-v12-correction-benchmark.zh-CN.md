# SQLite v12/v13 更正物理证据

最后更新：2026-08-13

## 范围

这份证据冻结 ADR-008 选定的更正结构，以及 ADR-009 选定的更正 finding
失效记录扩展。生产仓库现在会把新库、v11 库和 v12 库迁移至
`PRAGMA user_version` 13。v12 结构在已发布的 v11 不可变观测账本上增加紧凑的校准
修订、已注册更正输入、线性更正投影 work/checkpoint、完整替换的
finding/rank/reason，以及 current-effective 查询索引。Schema v13 只增加用于区分
原始 finding 与更正 finding 身份的 append-only 更正 finding retraction。完整的成对校准现在会在
同一个事务里写入校准修订、当前真值、v11 frame、scan 完成状态、dirty
compare-and-delete 和旧物化缓存。它仍不表示状态/查询 UI、macOS 15.6 资格、
签名、公证或发布分发已经完成。

注册式同帧更正事务现已实现，并由封闭的源码注册表和 package 级应用层授权器
保护。授权器与 SQLite 都会重新读取不可变前驱和准确的完整 frame 对；SQLite
会重新运行选定实现，比较完整结果与规范摘要，并在一个原子事务中提交输入、
work、替换 finding/rank/reason 和 checkpoint。模拟 COMMIT 成功但 ACK 丢失后的
同 request ID 重试会返回原更正；字段变化、partial/unavailable 证据、语义 no-op、
生成器不一致和 checkpoint 故障均封闭失败。在具体更正算法及其规范输入 fixture
通过源码评审前，生产注册表有意不提供任何更正 tuple；运行时不能任意注册实现。

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
`915140cafec33596e7ddc9153a0c6b319f6348fd3f88aca8f317ed87c08cbc01`。

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
| 500,000 | 无更正 | 500,000 | 480,000 | 0 / 0 | 148,323,608 B | 109,744,128 B | 0.712 ms | 0.029 ms |
| 500,000 | 2% 更正负载 | 500,000 | 480,000 | 47 / 18,424 | 169,932,648 B | 118,046,720 B | 0.732 ms | 0.048 ms |
| 500,000 | v10→v13 共存 | 250,000 | 240,000 | 0 / 0 | 131,507,928 B | 106,188,800 B | 0.679 ms | 0.034 ms |
| 1,000,000 | 无更正 | 1,000,000 | 960,000 | 0 / 0 | 298,564,088 B | 220,430,336 B | 0.747 ms | 0.031 ms |
| 1,000,000 | 2% 更正负载 | 1,000,000 | 960,000 | 47 / 36,848 | 340,859,536 B | 237,035,520 B | 0.841 ms | 0.046 ms |
| 1,000,000 | v10→v13 共存 | 500,000 | 480,000 | 0 / 0 | 263,343,408 B | 212,602,880 B | 0.712 ms | 0.027 ms |

六个场景都得到 `integrity_check=ok`、零外键违规、`secure_delete=ON`，且
WAL 截断后为 0 字节。最大的最终场景为 237,035,520 字节，相对
250,000,000 字节的维护后门禁还剩 12,964,480 字节。维护前体积如实记录，
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
- 生产迁移使用原子迁移前备份，保留每一个 v11 值，不伪造任何修订/更正边，
  并在对外提供写入前校验完整 schema digest
  `04fba44ae486b4d2f54324bd2068838675162103846d58abfd89fbdebcd059cf`。
- 纯追加的 v12→v13 迁移保留每一条 v12 记录，不伪造 retraction，并在服务前校验
  完整 schema digest
  `cd10e239cc6067a77c4e51a0d862ad6942c406b24a2ca2962304bd77ffbc49a4`。
  Released v13 fixture、generator、语义摘要和 schema-object 摘要均由 fixture 门禁独立验证。
- 旧的 `directory_history_sample` 记录仍然是明确标记的有损旧基线；迁移不会
  把它们重新包装成不可变 v12 修订。
- 确定性 released v12 fixture 包含两组完整双指标观测、4 条修订、1 个已提交原始投影
  和 1 个已 checkpoint 的空结果更正投影。门禁会独立逐字节复核 generator、
  fixture、语义与 schema-object digest。
- 完整校准只会为 present 且完整测量的目录发布修订。同桶 successor 保留前驱；
  即使墙钟回拨，也以数据库派生顺序为准；ACK 丢失重试会返回原修订身份，不会
  重复分配。
- dirty revision 竞争失败，以及 superseded、partial、cancelled、failed、
  history-disabled 或已经过期的扫描都不会写入修订。保留事务会先原子删除整个
  同桶链及其 dependent correcting-projection 图，再删除 v11 节点。
- 注册式更正投影事务、版本化 current-effective/审计查询、耐久校准状态、恢复/保留、
  更正 finding 失效记录、诊断导出和概览展示均已实现，并通过严格并发的
  Application/SQLite/App 测试。当前主机 APFS 资格测试真实分配并刷盘 5 GiB 文件，
  注入 kernel-drop 连续性缺口，并在准确目标子树恢复至少 5 GiB 的 allocated 增长 finding。
  发布 KPI 仍要求文档规定的重复原型矩阵；macOS 15.6、无障碍、签名分发与公证是独立门禁。
