# ADR-009：版本化 finding 身份与更正 finding 失效记录

## 状态

提议中

日期：2026-08-13

英文事实源：[ADR-009-corrected-finding-identity-and-invalidation.md](ADR-009-corrected-finding-identity-and-invalidation.md)。本文是其中文伴随翻译。

相关需求：FR-004、FR-006、FR-013、NFR-003、NFR-006

获批后修订：[ADR-006](ADR-006-immutable-observations-and-findings.zh-CN.md) 与 [ADR-008](ADR-008-append-only-reconciliation-corrections.zh-CN.md)

## 背景

Schema v12 把注册式更正投影保存在独立的
`historical_corrected_finding` 表中，其数据库 ID 与 schema v11
`historical_finding` ID 有意属于两个不同命名空间。现有
`historical_finding_retraction` 只能引用原始 schema v11 finding。

ADR-008 要求 current-effective 视图隐藏终态投影中被独立失效的 finding，
但 v12 无法对更正后的终态 finding 兑现这一承诺：把 ID 强制塞入 v11
命名空间会与无关原始记录碰撞；把失效挂在前驱上会错误恢复旧数据；直接丢弃
更正 finding 又会失去审计原因。v12 已有冻结的 golden fixture 与迁移契约，
因此不能原地重写其 schema。

## 决策

### 1. 版本化内存身份

应用层读取模型使用显式 sum type：

- 投影身份为 `.original(HistoricalProjectionRecordID)` 或
  `.correcting(HistoricalCorrectingProjectionRecordID)`；
- finding 身份为 `.original(HistoricalFindingRecordID)` 或
  `.corrected(HistoricalCorrectedFindingRecordID)`。

不得用整数偏移、符号位、哈希、路径或展示文本连接两个命名空间。规范排序先比较
来源判别符，再比较正的数据库 ID。

### 2. Schema v13 更正 finding 失效记录

Schema v13 追加 `historical_corrected_finding_retraction`。每条记录冻结：

- 数据库分配的正 retraction sequence；
- 16 字节 request ID 与版本化规范 request digest；
- 一个唯一 corrected-finding ID；
- 存储中准确的 corrected draft SHA-256；
- 唯一已发布原因 `evidence_invalidated`；
- 提交时间与更正投影既有的过期边界。

目标必须属于完整 checkpoint 的更正投影，expected digest 必须等于不可变目标行。
失效记录仅追加，每个更正 finding 最多一条，且不能比目标投影活得更久。Schema
v11 的失效记录保持逐字节不变。

### 3. 授权与幂等

公开 repository 只暴露版本化 finding/审计读取。package 级、非 `Codable`
命令只能由现有类型化完整性对账授权器在重新读取准确审计记录后构造。UI、分类器、
清理流程和任意更正代码都不能自行选择 ID 或 digest。重试结果仍只有：新提交、
逐字节相同的已提交、不可变冲突。

### 4. Current-effective 与审计行为

Current-effective 查询先解析终态投影，校验其完整结果，只移除该终态投影内部被
失效的 finding，再重建规范顺序，最后才应用调用方 limit。即使终态替换为空或
全部失效，也绝不回退到前驱。

审计查询按前驱顺序返回原始投影、全部更正边、未修改 finding 与 digest、两类
retraction、注册语义身份和提交元数据。comparison-sequence limit 仍是观测时间
边界，不是“更正时间点快照”。

### 5. 迁移、保留与发布边界

v12→v13 迁移是纯追加的，不伪造任何失效记录。保留与 History Off 会先删除 v13
retraction，再删除 corrected finding，之后沿用已验证的 v12 依赖顺序。在 Task 7
查询接入可视为完成前，恢复、released fixture、隐私检查和百万节点容量门禁都必须
纳入 v13。

## 后果

- 更正 finding 与原始 finding 的 ID 不会在 UI 或审计缓存中碰撞。
- 注册式更正后发现的失效证据有诚实的仅追加目标。
- v12 字节与已有本地数据库保持可读且不可变。
- FR-004 关闭前需要增加一次迁移和一张表。

## 验证

1. 证明 raw ID 相同的两个来源仍是不同版本化值，并有稳定排序。
2. 证明 v12→v13 迁移创建空表且不修改任何 v12 行。
3. 证明授权、ACK 丢失重试、字段变化冲突、目标/digest 校验、回滚、过期、保留和
   History Off 行为。
4. 证明终态更正 finding 遵守自己的 retraction，且不会恢复前驱 finding。
5. 重跑严格并发、released fixture、隐私、容量、恢复、签名沙盒、macOS 15.6 与
   DMG 门禁。
