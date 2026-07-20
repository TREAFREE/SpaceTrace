# 已授权目录基线与概览页接入

状态：**应用切片已实现；FR-002 仍只完成一部分**

最近更新：2026-07-20

英文事实源：[authorized-baseline-overview.md](authorized-baseline-overview.md)。本文是便于中文阅读的对应译文；如两者存在差异，以英文文档为工程事实源，并应在同一次变更中修正译文。

## 目的与范围

本次实现把已经恢复的用户自选目录接入可取消的元数据基线扫描，并让概览页只展示可验证的结果。已提交记录包含启动数据卷容量快照，并能在 App 重启后恢复。应用层现在已经支持有界多根目录请求；当前权限 UI 仍只展示一个主目录，后续会在独立的展示层变更中接入批量入口。FR-002 **尚未**实现真正的扫描中点续扫、温度与电源调度，以及历史比较点。

## 所有权与数据流

```text
概览页按钮
    -> BaselineScanViewModel（@MainActor 展示状态）
    -> AuthorizedBaselineScanCoordinator（actor，拥有任务和状态）
    -> NativeAuthorizedBaselineScanContextProvider
         -> 已恢复的 WatchedScope catalog
         -> 当前活跃 FSEvents stream generation
    -> EventJournalAuthorizedBaselineCalibrationRunner
         -> 持久化根目录 requiresCalibration 标记
         -> 有界元数据扫描器
         -> SQLite staging
         -> 按 revision 校验的原子发布
    -> 启动数据卷容量快照
    -> SQLite v6 已授权基线快照事务
         -> App/Schema 版本
         -> 卷总容量/当前可用/重要用途可用估计
         -> 有序根目录摘要
    -> 新结果、重启恢复的已提交结果，或类型化的“未发布”结果
    -> 概览页
```

上下文提供器只接受已经活跃的 `WatchedScopeID`，返回精确恢复的根目录以及当前挂载 generation 的 stream ID。UI 绝不会根据路径文本构造权限能力或 stream 身份。一次请求只能包含 1–64 个互不重复的 scope ID，开始工作前会按稳定 ID 排序。

在更换或撤销目录能力之前，授权协调器会取消并等待正在运行的基线扫描。应用退出同样先走完取消流程，再释放 security-scoped lease。

## 类型化生命周期

应用层状态只能是以下之一：

- `idle`：空闲；
- `preparing`：解析已授权 scope 和活跃监控 generation；
- `scanning`：正在执行有界元数据枚举；
- `publishing`：已经得到完整报告，但 revision 校验事务尚未提交；
- `completed`：包含已经持久提交的完整基线快照，并区分“刚刚扫描完成”或“重启后恢复”；
- `incomplete`：包含部分覆盖证据，或“revision 已被新事件取代”的原因；
- `cancelled`：所属任务已经退出，staging 已丢弃；
- `failed`：包含稳定且不泄露隐私的失败码。

扫描器在枚举前并不知道最终条目数，因此概览页使用不确定进度指示器，而不是伪造百分比。界面会显示已用时间和根目录计数；条目数与目录摘要数只在扫描器确实产生这些数据后显示。

## 多根目录调度策略

- 协调器 actor 只拥有一个批次任务，按照稳定 scope ID 顺序逐个扫描根目录。这样不会通过并行递归枚举成倍增加磁盘压力。
- 进度携带当前根目录上下文，以及 `completedRootCount`、`totalRootCount` 和不可读根目录证据。只有进入下一个根目录，才能证明上一个根已经成功发布。
- 只有所有请求根目录都获得完整覆盖，才会且只会写入一次完整基线快照。任一根为部分覆盖或被新 revision 取代，批次立即停止，不提交快照；之前已经安全发布到 `node_current` 的目录聚合仍然可以保留。
- 取消会取消并等待当前根目录 runner 真正退出。取消状态会记录全部请求 scope 和已经完成的根目录数，但不会把部分批次重新标成已提交基线。
- 64 个根目录上限、每根扫描预算和顺序执行共同形成明确上界。它是安全限制，不代表 UI 应鼓励用户添加 64 个目录。

## 发布与覆盖规则

1. 开始基线时，会写入一个不携带游标、位于 scope 根目录的 `requiresCalibration` dirty region；已有后代 dirty region 会被保守地合并到根目录。
2. 扫描器输出流式写入 SQLite staging 表；任何 staging 行都不是当前事实。
3. 部分覆盖报告会被丢弃并保留 dirty work。UI 可以展示真实的条目数、目录数和缺口数，但不会展示暂存字节总量。
4. 完整报告才进入原子发布。如果扫描期间的新事件推进了 dirty revision，本次运行会成为 `superseded`，staging 被丢弃，dirty work 继续保留。
5. 目录发布成功后，应用才从 `node_current` 读回根目录聚合。随后协调器对 SpaceTrace Application Support 所在卷取样，并用独立事务写入 v6 基线快照。
6. 只有快照事务成功，UI 才进入 `completed`。如果在目录发布与快照提交之间崩溃或写入失败，重启后只会恢复上一个已提交快照（或没有快照），不会制造“已经持久化”的假象。
7. 已发布结果会明确区分逻辑大小与可观察分配大小；后者不等同于 APFS 唯一物理占用，也不等于可回收空间。
8. 取消操作会丢弃 staging，绝不会把部分工作重新标记成完整结果。

这些规则继续保证架构不变量：**未知不等于零**。

## 持久元数据与重启策略

Schema v6 新增 `authorized_baseline_snapshot` 和 `authorized_baseline_root`。每个已提交快照记录扫描开始/提交时间、App 版本、Schema 版本、完整覆盖状态、卷采样时间，以及可选的容量值。根目录直接使用多根调度器生成的有序、scope 唯一集合保存。

SQLite 启动时会执行一个有界恢复事务。所有仍为 `running` 的校准行都属于已经结束的旧进程：删除其 staging、标记为失败，但保留 durable dirty work。SpaceTrace 不会声称可以从只存在于内存中的任意文件枚举中点继续扫描。目录授权恢复后，协调器只读取包含该 scope 的最近已提交基线，并在 UI 中标为“从本机记录恢复”。

启动数据卷提供器查询 Application Support 目录实际所在的卷，不硬编码 APFS 挂载路径。`total`、当前 `available` 和 `availableForImportantUsage` 是三个彼此独立的可选值。“重要用途可用”可能包含 macOS 能够释放的空间，不会被标成当前空闲块；API 未提供的值继续保持“未知”。

## 用户可见行为

当目录授权和监控代次均已就绪时，概览页会提供“开始基线扫描”。扫描期间会展示当前类型化阶段、已用时间、根目录计数、已经可获得的扫描计数，以及取消按钮。

成功卡片会展示：

- 精确的已授权根目录；
- 完整覆盖状态；
- 使用二进制单位的逻辑大小与可观察分配大小；
- 后代条目数和已扫描条目数；
- 启动数据卷总容量与当前可用容量；
- 单独列出的 macOS“重要用途可用”估计；
- 发布时间；
- App/Schema 版本，以及结果是否从本机已提交状态恢复；
- 重新扫描入口。

部分覆盖、revision 被取代、取消和失败都有各自独立的说明和重试入口；这些状态都不会展示未发布的字节总量。

## 验证边界

确定性的 package 测试覆盖完整发布、部分覆盖不发布、revision 被取代、取消、类型化阶段顺序、上下文失败、容量采样、多根目录确定性顺序、单快照提交、后续根部分失败、后续根取消、请求边界、快照往返、重启恢复、中断 staging 清理，以及 dirty work 保留。应用测试覆盖 MainActor 状态投影、单根/多根命令转发和恢复命令。完整仓库门禁会构建 Debug/Release App，并运行 package 与应用单元测试。

原生 security-scoped 选择和挂载生命周期继续由已有的签名沙盒与 APFS 镜像规程覆盖。本次实现不声明完整 FR-002 旅程已经在 macOS 15.6 上通过；在更新主机上按 deployment target 编译不等于真实运行资格验证。
