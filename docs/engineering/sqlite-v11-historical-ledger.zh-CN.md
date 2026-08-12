# SQLite v11 历史账本

## 状态

schema v11 持久化切片与生产完整扫描接入已在当前开发主机上实现并通过验证。本文覆盖的 schema、迁移、repository 事务、paired logical/allocated finalization、完整父级 disappearance 对账、合格 APFS 稳定 move 证据、生产环境创建 projector work、有界即时/启动投影、撤回、保留、恢复夹具和当前主机规模基准由此收口。但这**不代表** SpaceTrace 已具备发布资格：finding UI、最低系统资格、辅助功能/可用性证据以及分发信任仍未完成。

ADR-004 与 ADR-006 继续保持**提议中（Proposed）**。实现门禁通过只是供评审使用的证据，不等于维护者已经接受 ADR。

## 权威边界与数据模型

V11 在既有当前状态和 v10 历史表旁增加一套不可变本地账本：

- 单一 store generation、不透明的 scope/subject/location 字典，以及冻结的分类决策；
- 观测批次、帧、共享目录节点、按 logical/allocated 指标拆分的端点、稳定身份凭据和连续提交标记；
- 待处理投影工作、不可变投影/finding/排名/原因计数、投影检查点，以及独立的 `evidence_invalidated` 撤回；
- 持久化的 `off | days(1...30)` 历史策略、无路径缺口状态、已提交基线、终态校准 receipt，以及独立无路径的停用 receipt。

数据库根据 store generation、已提交节点键和指标派生端点身份。事务内部可以派生并比较临时身份，但在 `COMMIT` 成功之前不得逃离 actor 或返回调用者。回滚不会暴露任何已提交端点或帧。

每条 finding 都通过 SQLite 原生复合外键指向准确的基线和对比指标端点。帧提交 trigger 是权威边界：它会拒绝不完整的 logical/allocated 配对、端点状态不一致、根节点不唯一或 subject 错误、父级成员关系错误、稳定身份缺失以及提交后扩展图。缺失行永远不会变成 absence 证据。

## 事务状态机

### 成对 finalization

1. 校验正在运行的扫描、staging 行、调用方 candidate、策略、stream、revision 和当前 dirty-work 所有权。
2. 若 History Off 已启用，只发布当前事实，阻止 v10/v11 路径历史写入，删除历史基线，并提交一个保留七天、无路径的停用 receipt。
3. 否则，在同一个 writer 事务中写入批次、logical/allocated 两帧、共享节点、指标端点、稳定身份凭据和两个帧提交标记。
4. 在同一事务中重新读取两帧，并与 Application candidate 逐字节比较。事务内身份在 commit 成功前不得对外暴露。
5. 发布当前状态、注册确定性的投影工作、消费匹配的 dirty work，并提交一个不可变终态 receipt。
6. 若 commit 后响应丢失，通过 receipt 和精确请求摘要恢复。完全相同的重试返回已提交结果；不可变字段发生变化则以 immutable conflict 失败。

每个指标的首对已提交帧只是描述性基线。后续连续帧对才创建投影工作。不支持的版本、陈旧工作、跨帧身份、过期证据以及非权威 Application 结果，都必须在 finding 图持久化之前失败。

### 投影与撤回

待处理工作按 comparison sequence 和 work ID 确定性选择。repository 重新加载权威帧，重新生成 version-1 结果，与传入结果精确比较，再原子提交投影、finding、排名、原因计数和检查点。检查点之前失败会回滚整个投影，并保留 pending work。

公开 history repository 不暴露撤回 mutation。只有 Application 完整性授权器能构造不可 `Codable`、非公开的证据失效命令；Persistence 通过 package-scoped 端口接收命令，并在事务中再次校验已存 finding 与 canonical draft digest。撤回会从 current-effective 查询隐藏 finding，但审计读取仍保留原始 finding 与撤回记录。V11 没有 successor/replacement 列，也不声称实现 supersession。

## 保留、History Off 与隐私

硬性证据过期时间锚定到图中最早观测，最长 30 天；更短的持久策略使用更早边界。保留过程是一个有序事务：依次清除撤回与 finding 依赖行、投影/检查点/work、终态 receipt 与基线、帧提交、稳定身份/端点、按子节点优先的节点、帧/批次、孤儿字典，最后清除无引用 scan run。任何注入失败或真实 `SQLITE_FULL` 都会回滚策略变化和全部删除。

History Off 与 Clear History 不同。History Off 会跨重启保持，删除带路径的历史图和基线，阻止新的 v10/v11 路径历史写入，同时保留 watched authorization、当前状态、监控、dirty operational truth 和允许保留的无路径容量历史。读取会暴露类型化的 `historyDisabled`；重新启用后，在新基线提交前暴露 `baselineUnavailable`。Clear History 仍是 ADR-004 与隐私基线中单独确认的完整本地重置。

敏感字段包括原始路径、显示名、scope/subject/location 字节、稳定对象 token 与 birth time、分类决策、观测时间、bookmark、dirty path，以及由这些内容派生的摘要。它们只能为限定目的存在于受保护的本地存储中，不得进入 Release 诊断、日志、测试输出、fixture manifest 或导出。累计隐私检查器会扫描 v11 计划边界以来每个已提交文件，以及 index、工作树和未跟踪视图；SQLite released fixture 只有在确定性生成器、manifest、摘要、完整性与语义校验全部通过时才被允许。

## 迁移、失败与恢复

迁移 11 只向前执行，并记录完整 schema 的 canonical digest；它不会用 v10 历史伪造不可变证据。迁移前 repository 会创建原子 online backup；失败时保留源库并进入类型化只读恢复，不会静默重建。

已发布的 v10/v11 golden database 由确定性脚本生成。V10 用于验证升级到 v11 时不会制造证据；V11 canary 包含已提交端点、投影、finding、撤回和内嵌过期元数据。恢复验证会检查 schema digest、完整性、外键、不可变形状、投影/finding 引用、过期边界和敏感 artifact inventory。

脱离 WAL 单独复制的 main database 一律视为 incomplete，因为陈旧 main 文件无法证明已提交 WAL 页面是否丢失。完整 online backup 或完整 main/WAL bundle 只有通过校验后才可判定 complete。WAL checkpoint 测试同时覆盖成功截断和真实 busy reader；后者保持类型化 incomplete，绝不谎称备份干净。

## 当前主机规模证据

最终 repository benchmark 在 `SpaceTracePersistence` 内部持有 SQLite 连接和 SQL，命令行可执行程序只得到指标。它在当前应用数据库上使用 released v11 schema，每次查询重复都验证准确结果数量，记录 query plan 和完整 `dbstat`，并在任一硬门槛越界时令命令失败。

30 天矩阵会先写入五个已过期日，再原子保留 25 天。矩阵覆盖：无变化、100 个 scope/高帧数、100% 稳定身份、每天 2% 移动，以及 v10/v11 各占一半的重叠场景。端点写入 P95 按每个最多 500 节点/双指标的事务内分块计时；finding P95 按最多 500 条 finding 的分块计时。查询 P95 重复 25 次，并逐次验证结果行数。峰值 RSS 是整个矩阵进程的高水位，因此属于保守值。

环境：Apple M5、16 GB RAM、macOS 26.6.1 (25G76)、Xcode 26.1.1 (17B100)、内置存储。未记录电源、温度和低电量模式，因此总插入时间只作诊断。JSON SHA-256：500k 为 `aa7935f83fb07262119108a78dc666a4fefd522e4989b4ee19795dd3e71a941d`，1M 为 `871713e9768b75436222d337d9fa17409762bf46c38997f7890f072d649259e5`。

| 样本数 | 最坏 DB+WAL+SHM | 最坏峰值 RSS | 端点写入 P95 | Finding 写入 P95 | Pending work P95 | Effective Top 10 P95 | 旧历史七日 Top 100 P95 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500,000 | 114,712,576 B | 86,933,504 B | 31.25 ms | 10.61 ms | 0.11 ms | 38.63 ms | 21.22 ms |
| 1,000,000 | 231,653,376 B | 114,032,640 B | 46.69 ms | 20.48 ms | 0.15 ms | 142.02 ms | 75.75 ms |

十个场景全部报告 `integrity_check=ok`、外键违规为 0、`secure_delete=ON`，并在截断后得到 0 字节 WAL。1M 全稳定场景最大，为 231,653,376 字节。1M 重叠场景保留 500,000 个 v11 节点与 500,000 行 v10 历史，占用 214,601,728 字节，峰值 RSS 为 114,032,640 字节。增长查询使用二进制根范围并明确选择 `directory_history_growth`；看起来像通配符的路径文本仍按普通字符处理。

当前主机门槛全部通过：完整数据库低于 250,000,000 字节，峰值 RSS 低于 150,000,000 字节，500 节点/finding 写入 P95 不超过 100 ms，v11 和旧历史查询均不超过 500 ms。这些只是当前主机 persistence 门禁，不是 macOS 15.6 或最低参考硬件资格。

## 准确的不声明与剩余发布门禁

这一接入切片仍不声称：

- APFS 目录 link-set 唯一性与顶层完整父级 disappearance 现已由真实 Foundation 和受控磁盘镜像测试证明；不受支持的文件系统、已移动/不完整父级、被替换对象占用的位置以及其他所有未证明缺失行仍会被抑制；
- 每个 legacy 调用方都使用 paired v11 finalization：运行中的已授权卷和 FSEvents 校准路径只在持久卷/挂载上下文及富 scanner/repository 能力可用时采用它；明确不支持的上下文继续只发布当前状态，不会虚构历史；
- 已有 replacement/supersession；v11 只支持证据失效；
- 概览或菜单栏已经展示 finding、不确定性、撤回、History Off 或 baseline-unavailable 状态；
- 当前 24 known/8 Unknown 分类语料已经满足独立 60 案例门禁；
- 已完成用户控制的脱敏导出、macOS 15.6 运行、Apple 身份签名/公证、干净 quarantine 安装、升级/回滚、人工辅助功能/可用性、许可/notices/SBOM 或公开分发资格。

在这些门禁关闭且 ADR-004/ADR-006 被接受之前，产品发布决策继续为 **NO-GO**。本地生成的 ad-hoc DMG 仍只是受控工程产物，不是公开 Release。
