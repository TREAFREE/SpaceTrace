# 第一阶段实现状态

状态：**架构验证阶段；尚未形成用户可见的生产功能**

最近验证日期：2026-07-18

英文事实源：[implementation-status.md](implementation-status.md)。本文是便于中文阅读的对应译文；如两者存在差异，以英文文档为架构事实源，并应在同一次变更中修正译文。

本文记录第一阶段实现已经证明的内容，也同样明确尚未证明的内容。在 ADR-003 和 ADR-004 的完整验证计划完成并经过维护者评审之前，两份 ADR 仍保持 **Proposed（提议中）** 状态。

## 已实现的证据

| 领域 | 仓库中已有的证据 | 已证明的不变量 |
| --- | --- | --- |
| 领域观测模型 | 经过校验的字节数量、强类型标识、覆盖状态、可比较观测以及保持指标语义的差值 | 未知或部分覆盖的证据不能被展示成“完整且为零字节”的观测 |
| FSEvents 桥接层 | 按设备解析监控目标；持久化卷/日志标识；校验卷内相对路径；还原应用绝对路径；支持重启的完整历史回放；可注入故障的流构造；对被拒绝的历史回放和启动后意外终止执行带校准恢复；处理根目录变化哨兵；安全持有原生资源生命周期；有界单消费者适配器；无日志 UUID 卷使用仅实时的主机流降级方案 | 持久回放同时绑定卷 UUID 与 FSEvents 日志 UUID；绝不持久化临时的 `dev_t`；恢复必须先持久化连续性丢失再开始实时监控；非持久降级流只属于一个挂载 generation |
| 挂载生命周期 | 只读 Disk Arbitration 出现、消失、挂载路径变化观测；拥有所有权的回调快照；有界溢出信号；只匹配配置的精确挂载根；仅在已批准 scope 内补充 UUID；纯函数式 scope 挂载 generation 状态机；事务型持久化端口 | 枚举父卷不能激活外部卷 scope；重复回调复用同一个活跃 generation；每次观测到重新挂载都会创建新 generation；相同挂载路径上的不同 UUID 不能继承历史；迟到的卸载只能关闭其对应 generation |
| 非 UI 监控组合 | actor 隔离的 Disk Arbitration 消费；有界挂载就绪重试；事务型激活/关闭；每个 scope 只拥有一个 FSEvents 消费任务；按 generation 条件停止/重启；带指数退避和熔断的启动后恢复；恢复状态观测；溢出后重建事件源 | 原生回调顺序不能悄悄重排并发 generation 工作；短暂故障只在固定上限内重试；卸载/替换会取消所属恢复任务；回调精度丢失时必须在重新枚举前关闭相关事件流 |
| 失效映射 | 从适配器语义映射到应用层；词法 scope 校验；文件事件投影到父目录；过滤重放重叠；事件 ID generation 作废；祖先路径合并 | 路径含糊或连续性中断时，牺牲精度并退化为 scope 校准；事件 ID 回绕会作废旧 checkpoint，并让整个摄取批次不携带游标 |
| 元数据校准扫描器 | 基于 Foundation/Darwin 的纯元数据遍历；显式限制条目数、深度、时长与批次；协作式取消；强制同卷；不跟随符号链接；硬链接分配量去重；强类型覆盖缺口 | 永不打开文件内容；叶子路径不会越过目录聚合边界；预算耗尽、权限丢失、挂载边界和取消都不能伪装成完整证据 |
| 校准流水线 | actor 隔离的摄取与有界协调；通过应用层 scanner 端口执行扫描；使用结构化异步 staging | 部分完成或被取消的扫描会丢弃 staging 并保留 dirty work；扫描期间数据若变旧，完成的旧扫描不能发布数据或清除已经更新的工作 |
| 事件日志端口 | 应用层拥有的持久事件流标识、连续性分类、游标、dirty region、行 revision、原因、批次及条件清理契约 | checkpoint 只有在同一批次中已有持久 dirty work 时才能写入；卷 UUID 或日志 UUID 任一变化都会选择不同的持久事件流 generation |
| SQLite 原型 | actor 持有的 SQLite3 连接；WAL；schema v4；大端 `UInt64` 游标和 revision；持久 scope 挂载 generation；扫描运行与目录 staging 表；当前目录聚合；原子发布；无游标校准标记；checkpoint generation 作废；回滚故障接缝 | 游标推进与 dirty region 持久化保持原子性且不能倒退；挂载激活在一个写事务中完成分类和存储；generation 只能条件关闭；日志 generation 作废会原子清除 checkpoint 和所有待处理游标，并推进工作 revision |
| 构建集成 | 本地 `SpaceTraceKit` Swift Package 已链接到 macOS 应用 target | 应用组合根可以依赖模块化非 UI target，无需复制源码 |

## 验证证据

以下门禁已在 2026-07-18 使用 Swift 6.2.1 与 Xcode 26.1.1 通过：

- `swift test --package-path Packages/SpaceTraceKit`：131 个测试、20 个 suite（会改变测试环境的资格测试保持 opt-in，常规运行中显示为 skipped）；
- 同一套 package 测试在完整严格并发诊断以及“编译器警告视为错误”条件下通过；
- 一条从适配器到应用层再到真实 SQLite 的集成测试，校准 scanner 使用注入实现；
- 四条串行的按设备 FSEvents 集成测试，在受保护的一次性 APFS 目录上覆盖持久标识解析、实时事件、单订阅失败、取消清理、显式停止、重启、经 `HistoryDone` 完成的历史回放以及真实回调缓冲区溢出标记；
- 异步溢出断言加固后，按设备集成测试连续运行 100 次未出现间歇性失败；测试使用原生同步 flush 作为观测边界，不依赖定时 sleep；
- 确定性的 Disk Arbitration 回调解析、溢出、单订阅、停止与原生 session 生命周期测试，以及挂载状态机和 SQLite v3 到 v4 迁移测试；
- 一项 opt-in 受控资格测试使用两个同名 64 MiB APFS 镜像，覆盖正常卸载、同卷重新挂载、相同挂载点上的不同 UUID 替换、不同 generation/stream ID，以及首个卷与替换卷上的实时 FSEvents dirty 证据；通过运行耗时 3.924 秒；
- 通过可注入 client 与 resolver 的确定性测试，证明原生流创建失败和启动失败都会作废存量回放 checkpoint、持久化 scope 级校准工作、只尝试一次 `sinceNow` 恢复，并在该恢复同样失败时保持非活跃状态；
- 通过确定性的启动后生命周期测试，证明自动实时恢复、连续性作废持久化、启动失败和重复终止的有界熔断、退避期间取消、拒绝未知/替换卷身份以及恢复策略参数校验；测试不依赖定时 sleep；
- 权限丢失、符号链接、挂载边界、硬链接、预算和取消的确定性元数据 fixture，以及仅作用于一次性临时目录的生产适配器测试；
- `make verify`，其中包括架构检查、package 测试、Xcode scheme 发现、Debug 构建、应用单元测试和 Release 构建；
- Xcode 以 `arm64-apple-macos15.6` 为目标完成编译与链接，本地 package 从当前仓库解析。

严格并发运行用于审计本次新增的 package 代码。根据 ADR-001，应用 target 仍使用 Swift 5 语言模式；全仓库 Swift 6 迁移仍是独立的决策与验证任务。

## 明确不作出的声明

- 尚未实现面向用户的扫描、历史、解释、菜单栏、权限或导出工作流。
- 生产 scanner、schema v3 staging 路径、schema v4 挂载映射、Disk Arbitration 事件源和 FSEvents supervisor 已组合进非 UI package runtime，但尚未接入应用 target 或任何用户可见流程。
- 扫描调度尚未响应温度状态、电池状态或系统负载。硬链接去重受条目预算限制，但每次扫描运行期间仍保存在内存中。
- 尚未实现权限 scope 获取、安全作用域 bookmark 生命周期、云占位文件分类或 APFS snapshot 对账。
- 不会依据 FSEvents 推断精确字节差值或进程归因。
- 原生资格测试已经在开发主机上覆盖受控卸载、重挂和同名卷替换；但最老支持系统的真实运行、守护进程真实 `UserDropped`/`KernelDropped`、事件 ID 回绕、睡眠/唤醒以及权限撤销仍未完成资格验证。
- 启动后自动恢复已经有界且经过测试，但守护进程真实 drop/wrap 条件以及最老支持 macOS 上的恢复行为仍未完成资格验证。
- SQLite 适配器是不引入外部依赖的架构原型。ADR-004 中关于 GRDB、迁移 fixture、保留策略、磁盘写满、损坏和 benchmark 的决策仍未完成。
- 尚未完成 macOS 15.6 真实运行资格验证；在较新主机上按 deployment target 编译不等于运行证据。
- Full Disk Access、App Sandbox 移除、Developer ID 签名、公证、分发及更新行为均未改变，继续由相应的 Proposed 决策约束。

## 下一批验收门禁

1. 在可安全复现时验证真实守护进程 drop/wrap，并加入基于性质的挂载/事件状态序列测试。
2. 完成 ADR-004 的 GRDB 与原生 SQLite 评审，包括许可证、构建、迁移和公证证据。
3. 扩展 schema 迁移 fixture 矩阵，增加磁盘写满/损坏测试、保留行为与最老支持系统资格验证。
4. 实现用户选择的安全作用域 bookmark 获取与恢复，使 `WatchedScope.root` 和 `mountPath` 来自明确授权；随后在不扩大 scope 的前提下，把非 UI runtime 接入应用生命周期。
5. 增加温度、电源、睡眠/唤醒、权限撤销以及生产校准调度策略。
6. 在相应 ADR 被接受之前，继续保证所有架构验证代码都无法从用户可见流程触达。
