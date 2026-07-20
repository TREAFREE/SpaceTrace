# 已授权目录基线与概览页接入

状态：**应用切片已实现；FR-002 仍只完成一部分**

最近更新：2026-07-20

英文事实源：[authorized-baseline-overview.md](authorized-baseline-overview.md)。本文是便于中文阅读的对应译文；如两者存在差异，以英文文档为工程事实源，并应在同一次变更中修正译文。

## 目的与范围

本次实现把一个已经恢复的用户自选目录接入可取消的元数据基线扫描，并让概览页只展示可验证的结果。它完成了 FR-002 中“已授权目录根”的部分，但**尚未**实现启动数据卷的容量/可用空间采样、多根目录汇总、可恢复续扫、温度与电源调度，以及历史比较点。

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
    -> 已发布根目录聚合，或类型化的“未发布”结果
    -> 概览页
```

上下文提供器只接受已经活跃的 `WatchedScopeID`，返回精确恢复的根目录以及当前挂载 generation 的 stream ID。UI 绝不会根据路径文本构造权限能力或 stream 身份。

在更换或撤销目录能力之前，授权协调器会取消并等待正在运行的基线扫描。应用退出同样先走完取消流程，再释放 security-scoped lease。

## 类型化生命周期

应用层状态只能是以下之一：

- `idle`：空闲；
- `preparing`：解析已授权 scope 和活跃监控 generation；
- `scanning`：正在执行有界元数据枚举；
- `publishing`：已经得到完整报告，但 revision 校验事务尚未提交；
- `completed`：包含已经发布的完整根目录聚合与扫描报告；
- `incomplete`：包含部分覆盖证据，或“revision 已被新事件取代”的原因；
- `cancelled`：所属任务已经退出，staging 已丢弃；
- `failed`：包含稳定且不泄露隐私的失败码。

扫描器在枚举前并不知道最终条目数，因此概览页使用不确定进度指示器，而不是伪造百分比。界面会显示已用时间和根目录计数；条目数与目录摘要数只在扫描器确实产生这些数据后显示。

## 发布与覆盖规则

1. 开始基线时，会写入一个不携带游标、位于 scope 根目录的 `requiresCalibration` dirty region；已有后代 dirty region 会被保守地合并到根目录。
2. 扫描器输出流式写入 SQLite staging 表；任何 staging 行都不是当前事实。
3. 部分覆盖报告会被丢弃并保留 dirty work。UI 可以展示真实的条目数、目录数和缺口数，但不会展示暂存字节总量。
4. 完整报告才进入原子发布。如果扫描期间的新事件推进了 dirty revision，本次运行会成为 `superseded`，staging 被丢弃，dirty work 继续保留。
5. 只有发布事务成功后，应用才从 `node_current` 读回根目录聚合并展示字节结果。
6. 已发布结果会明确区分逻辑大小与可观察分配大小；后者不等同于 APFS 唯一物理占用，也不等于可回收空间。
7. 取消操作会丢弃 staging，绝不会把部分工作重新标记成完整结果。

这些规则继续保证架构不变量：**未知不等于零**。

## 用户可见行为

当目录授权和监控代次均已就绪时，概览页会提供“开始基线扫描”。扫描期间会展示当前类型化阶段、已用时间、根目录计数、已经可获得的扫描计数，以及取消按钮。

成功卡片会展示：

- 精确的已授权根目录；
- 完整覆盖状态；
- 使用二进制单位的逻辑大小与可观察分配大小；
- 后代条目数和已扫描条目数；
- 发布时间；
- 重新扫描入口。

部分覆盖、revision 被取代、取消和失败都有各自独立的说明和重试入口；这些状态都不会展示未发布的字节总量。

## 验证边界

确定性的 package 测试覆盖完整发布、部分覆盖不发布、revision 被取代、取消、类型化阶段顺序、上下文失败以及真实 SQLite 读回。应用测试覆盖 MainActor 状态投影和命令转发。完整仓库门禁会构建 Debug/Release App，并运行 package 与应用单元测试。

原生 security-scoped 选择和挂载生命周期继续由已有的签名沙盒与 APFS 镜像规程覆盖。本次实现不声明完整 FR-002 旅程已经在 macOS 15.6 上通过；在更新主机上按 deployment target 编译不等于真实运行资格验证。
