# 第一阶段实现状态

状态：**架构验证阶段；已具备目录权限与基线概览流程**

最近验证日期：2026-07-20

英文事实源：[implementation-status.md](implementation-status.md)。本文是便于中文阅读的对应译文；如两者存在差异，以英文文档为架构事实源，并应在同一次变更中修正译文。

本文记录第一阶段实现已经证明的内容，也同样明确尚未证明的内容。在 ADR-003 和 ADR-004 的完整验证计划完成并经过维护者评审之前，两份 ADR 仍保持 **Proposed（提议中）** 状态。

## 已实现的证据

| 领域 | 仓库中已有的证据 | 已证明的不变量 |
| --- | --- | --- |
| 领域观测模型 | 经过校验的字节数量、强类型标识、覆盖状态、可比较观测以及保持指标语义的差值 | 未知或部分覆盖的证据不能被展示成“完整且为零字节”的观测 |
| FSEvents 桥接层 | 按设备解析监控目标；持久化卷/日志标识；校验卷内相对路径；还原应用绝对路径；支持重启的完整历史回放；可注入故障的流构造；对被拒绝的历史回放和启动后意外终止执行带校准恢复；处理根目录变化哨兵；安全持有原生资源生命周期；有界单消费者适配器；无日志 UUID 卷使用仅实时的主机流降级方案 | 持久回放同时绑定卷 UUID 与 FSEvents 日志 UUID；绝不持久化临时的 `dev_t`；恢复必须先持久化连续性丢失再开始实时监控；非持久降级流只属于一个挂载 generation |
| 挂载生命周期 | 只读 Disk Arbitration 出现、消失、挂载路径变化观测；拥有所有权的回调快照；有界溢出信号；只匹配配置的精确挂载根；仅在已批准 scope 内补充 UUID；纯函数式 scope 挂载 generation 状态机；事务型持久化端口 | 枚举父卷不能激活外部卷 scope；重复回调复用同一个活跃 generation；每次观测到重新挂载都会创建新 generation；相同挂载路径上的不同 UUID 不能继承历史；迟到的卸载只能关闭其对应 generation |
| 非 UI 监控组合 | actor 隔离的 Disk Arbitration 消费；有界挂载就绪重试；事务型激活/关闭；每个 scope 只拥有一个 FSEvents 消费任务；按 generation 条件停止/重启；带指数退避和熔断的启动后恢复；应用层拥有的生命周期状态与有界最新状态流；溢出后重建事件源 | 原生回调顺序不能悄悄重排并发 generation 工作；短暂故障只在固定上限内重试；卸载/替换会取消所属恢复任务；生命周期消费者无需轮询适配器即可获得当前 inactive/active/recovering/failed 状态；回调精度丢失时必须在重新枚举前关闭相关事件流 |
| 权限与 catalog 生命周期 | 非 UI 的只读 bookmark 获取；opaque 应用层记录；精确 root/volume 恢复；重新派生 mount path；隐私安全的部分失败报告；外置卷缺席重试；配对 access lease | stale、路径移动、替换卷、符号链接、非目录和拒绝访问都不能悄悄扩大 scope 或自动刷新；只有暂时缺席会重试 |
| 应用进程生命周期 | AppKit 启动/退出桥接；Application Support 组合；catalog 恢复；唯一 runtime 任务；唯一扫描调度 monitor；异步退出协调；runtime 关闭后释放 lease | 关闭窗口不会停止监控；退出应用会先移除电源/睡眠观察器，再取消并等待基线与原生工作，最后释放权限能力；没有配置授权时保持 idle |
| 目录授权 UI | 用户主动触发的 `NSOpenPanel`；与路径无关的稳定 ID；按顺序投影多个 scope 的 MainActor 状态；可独立操作的已授权/不可用/需重新授权条目；拒绝完全重复根目录；有界新增；逐 scope 更换/移除；混合健康度概况与批量基线入口 | UI 不会从文本路径重建授权；stale 与身份变化必须再次使用系统选择器；变更失败会保留上一次可信投影；移除只释放选中的授权，不删除用户文件或测量历史 |
| 失效映射 | 从适配器语义映射到应用层；词法 scope 校验；文件事件投影到父目录；过滤重放重叠；事件 ID generation 作废；祖先路径合并 | 路径含糊或连续性中断时，牺牲精度并退化为 scope 校准；事件 ID 回绕会作废旧 checkpoint，并让整个摄取批次不携带游标 |
| 元数据校准扫描器 | 基于 Foundation/Darwin 的纯元数据遍历；显式限制条目数、深度、时长与批次；协作式取消；强制同卷；不跟随符号链接；硬链接分配量去重；强类型覆盖缺口 | 永不打开文件内容；叶子路径不会越过目录聚合边界；预算耗尽、权限丢失、挂载边界和取消都不能伪装成完整证据 |
| 校准流水线 | actor 隔离的摄取与有界协调；通过应用层 scanner 端口执行扫描；使用结构化异步 staging | 部分完成或被取消的扫描会丢弃 staging 并保留 dirty work；扫描期间数据若变旧，完成的旧扫描不能发布数据或清除已经更新的工作 |
| 已授权目录基线应用流程 | 精确解析已授权 scope/活跃 stream 上下文；actor 持有可取消批次任务；类型化的准备/暂停/恢复/扫描/发布/完成状态；权限切换时取消；聚合进度与逐根覆盖结果投影 | UI 字节结果只能来自按 revision 校验并原子发布后重新读回的完整根目录聚合；部分覆盖、取消、被取代及被调度器中断的尝试绝不能成为完整事实；路径可能重叠时不伪造聚合字节总量 |
| 扫描调度 | 应用层拥有的电源/温度/活动快照；固定的休眠 → 温度 → 低电量优先级；可回放决策门；结构化取消并重试当前根；提交前准入门；基于公开原生 API 的信号 monitor | 用户主动扫描在普通电池供电时仍可运行；休眠、严重/危急温度和低电量模式会安全暂停；条件恢复后重扫当前根目录，不声称从内存中点续扫 |
| 事件日志端口 | 应用层拥有的持久事件流标识、连续性分类、游标、dirty region、行 revision、原因、批次及条件清理契约 | checkpoint 只有在同一批次中已有持久 dirty work 时才能写入；卷 UUID 或日志 UUID 任一变化都会选择不同的持久事件流 generation |
| SQLite 原型 | actor 持有的 SQLite3 连接；WAL；schema v7；有界 opaque security-scoped bookmark；大端 `UInt64` 游标和 revision；持久 scope 挂载 generation；扫描运行与目录 staging 表；当前/已删除目录聚合；已提交多根基线快照；原子发布；无游标校准标记；checkpoint generation 作废；类型化磁盘写满/损坏/迁移错误；有界 retention | 游标推进与 dirty region 持久化保持原子性且不能倒退；写满失败保留已提交状态；损坏输入不被静默替换；迁移失败会回滚 schema 与版本账本；retention 只删除过期且可替代的行，并保留当前事实、未解决工作和每个 scope 的最新基线 |
| 构建集成 | 本地 `SpaceTraceKit` 已链接到 macOS 应用 target；显式声明只读 app-scoped bookmark entitlement；应用保持薄组合根 | 应用 target 能够恢复授权并持有模块化非 UI runtime 生命周期，无需复制源码或让 UI 拥有任务 |

## 验证证据

以下门禁截至 2026-07-20 已使用 Swift 6.2.1 与 Xcode 26.1.1 通过：

- `swift test --package-path Packages/SpaceTraceKit`：185 个测试、28 个 suite（会改变测试环境的资格测试保持 opt-in，常规运行中显示为 skipped）；
- 同一套 package 测试在完整严格并发诊断以及“编译器警告视为错误”条件下通过；
- 一条从适配器到应用层再到真实 SQLite 的集成测试，校准 scanner 使用注入实现；
- 四条串行的按设备 FSEvents 集成测试，在受保护的一次性 APFS 目录上覆盖持久标识解析、实时事件、单订阅失败、取消清理、显式停止、重启、经 `HistoryDone` 完成的历史回放以及真实回调缓冲区溢出标记；
- 异步溢出断言加固后，按设备集成测试连续运行 100 次未出现间歇性失败；测试使用原生同步 flush 作为观测边界，不依赖定时 sleep；
- 确定性的 Disk Arbitration 回调解析、溢出、单订阅、停止与原生 session 生命周期测试，以及挂载状态机和 SQLite v3 到 v4 迁移测试；
- 一项 opt-in 受控资格测试使用两个同名 64 MiB APFS 镜像，覆盖正常卸载、同卷重新挂载、相同挂载点上的不同 UUID 替换、不同 generation/stream ID，以及首个卷与替换卷上的实时 FSEvents dirty 证据；通过运行耗时 3.924 秒；
- 通过可注入 client 与 resolver 的确定性测试，证明原生流创建失败和启动失败都会作废存量回放 checkpoint、持久化 scope 级校准工作、只尝试一次 `sinceNow` 恢复，并在该恢复同样失败时保持非活跃状态；
- 通过确定性的启动后生命周期测试，证明自动实时恢复、连续性作废持久化、启动失败和重复终止的有界熔断、退避期间取消、拒绝未知/替换卷身份以及恢复策略参数校验；测试不依赖定时 sleep；
- 通过确定性的生命周期状态观测测试，证明当前状态回放、`inactive → active → recovering → active`、终态 `failed`、按 generation 停止后的清理，以及缓冲区正数校验；
- 通过确定性的 bookmark/catalog 测试，证明有效/stale 部分恢复、外置卷缺席后重试、stale 不自动刷新、授权获取持久化、完全重复根目录拒绝、lease 恰好释放一次，以及真实原生无 UI bookmark round-trip；同时覆盖 SQLite 到 v7 的迁移与进程生命周期取消/清理；
- 固定 GRDB 7.10.0 版本的 Release SPM spike 证明当前主机编译、`DatabasePool`/`DatabaseMigrator` 执行、默认 product 链接和系统 SQLite 链接；同时完成官方许可/manifest 证据评审，并明确第一阶段继续使用原生 SQLite；
- 确定性的真实 `SQLITE_FULL`、损坏主文件保留、提交前迁移回滚、retention 边界和固定时钟 retention 测试，覆盖过期 deleted node、可替代基线与无引用 scan run；
- 确定性的授权移除失败顺序、授权协调器重启/回退，以及覆盖选择、取消、stale 重新授权、撤权和外置卷返回的 MainActor ViewModel 测试；
- 确定性的应用外壳测试证明只暴露已实现的概览/权限目的地，并且 unavailable、stale 或 failed 授权绝不会在概览中显示为已就绪；
- 确定性的已授权目录基线测试证明类型化阶段顺序、取消完成、部分覆盖/被取代结果不发布、权限切换前取消，以及从真实 SQLite 读回完整根目录聚合；同时 12 个应用单元测试通过，覆盖 MainActor 多 scope 投影和批量命令转发；
- 确定性的扫描调度测试证明策略优先级、普通电池供电可运行、当前决策回放/去重、初始暂停时 scanner 调用次数为零、扫描途中取消、恢复后重试同一根目录，以及 Foundation/IOKit 原生值映射；
- 多 scope 权限 UI 测试 target 已完成无签名 `build-for-testing` 编译；当前主机执行 `security find-identity -v -p codesigning` 未找到有效 Apple 签名身份，因此不声明交互式 UI 测试已经通过；
- 对当前主机 ad-hoc 签名 smoke App 完成严格签名校验，确认含 App Sandbox、用户选择只读、app-scoped bookmark 以及 `LSMinimumSystemVersion = 15.6`；该结果不是分发签名或 macOS 15.6 运行证据；
- 当前主机签名沙盒 smoke 已证明精确 Powerbox 选择、正常退出后同一 bundle 无选择器恢复、App 内 bookmark 移除不删除夹具、一次性 APFS 镜像缺席时显示不可用，以及同一 Volume UUID 返回后自动恢复授权；
- 已在当前主机检查普通单窗口外壳、概览准备状态、侧栏导航和嵌入式权限旅程的视觉布局与可访问性树；公开 SwiftUI `MenuBarExtra` 已编译进同一进程，其最终状态项点击矩阵仍属于签名 UI 资格验证；
- 穷举运行两个持久卷身份与三个运行时磁盘身份组成的全部 2,401 条四信号应用状态序列，并为用户态丢失、内核丢失、事件 ID 回绕和回调溢出提供参数化的端到端持久化/校准证据；
- 权限丢失、符号链接、挂载边界、硬链接、预算和取消的确定性元数据 fixture，以及仅作用于一次性临时目录的生产适配器测试；
- `make verify`，其中包括架构检查、package 测试、Xcode scheme 发现、Debug 构建、应用单元测试和 Release 构建；
- Xcode 以 `arm64-apple-macos15.6` 为目标完成编译与链接，本地 package 从当前仓库解析。

严格并发运行用于审计本次新增的 package 代码。根据 ADR-001，应用 target 仍使用 Swift 5 语言模式；全仓库 Swift 6 迁移仍是独立的决策与验证任务。

## 明确不作出的声明

- 面向用户的多目录权限列表、批量基线、启动数据卷容量采样、版本/Schema 元数据、重启恢复以及感知电源/温度/睡眠的暂停与重试均已实现。真正从枚举器内存中点续扫、历史、增长解释、菜单栏 24 小时指标和导出尚未实现。
- 用户主动基线调度会响应休眠、低电量模式、严重/危急温度，并观察当前供电来源。后台速率预算、系统负载调度以及架构中的 token bucket 尚未实现。硬链接去重受条目预算限制，但每次扫描运行期间仍保存在内存中。
- 真实 sandbox Powerbox 展示以及 stale/身份失败的重新授权 UI 已实现；当前主机上的持久选择、同一 bundle 重启、明确 App 内移除和同镜像外置卷返回已经通过。真实 stale 证据、UI 流程中的不同 UUID 换卷子项、Apple 身份签名以及 macOS 15.6 运行矩阵仍未完成，或受到当前环境阻塞。
- 不会依据 FSEvents 推断精确字节差值或进程归因。
- 原生资格测试已经在开发主机上覆盖受控卸载、重挂和同名卷替换；但最老支持系统的真实运行、守护进程真实 `UserDropped`/`KernelDropped`、事件 ID 回绕、睡眠/唤醒以及权限撤销仍未完成资格验证；允许采用的证据边界记录在 [FSEvents 连续性丢失资格验证](fsevents-continuity-qualification.zh-CN.md) 中。
- 启动后自动恢复已经有界且经过测试，但守护进程真实 drop/wrap 条件以及最老支持 macOS 上的恢复行为仍未完成资格验证。
- GRDB 与原生 SQLite 的证据评审已经完成，第一阶段继续使用原生 SQLite。当前表的磁盘写满、明显主文件损坏、v6 到 v7 迁移回滚接缝和一部分有界 retention 已有测试。细粒度主库/WAL 损坏矩阵、迁移备份与全部已发布 fixture、完整小时/日历史及老化 dirty path 隐私行为、只读恢复 UI、benchmark、GRDB 行为等价、公证和最低系统运行证据仍未完成。
- 尚未完成 macOS 15.6 真实运行资格验证；在较新主机上按 deployment target 编译不等于运行证据。
- Full Disk Access、App Sandbox 移除、Developer ID 签名、公证、分发及更新行为均未改变，继续由相应的 Proposed 决策约束。

## 下一批验收门禁

1. 使用签名 sandbox App，在 macOS 15.6 与当前稳定版 macOS 上完成真实睡眠/唤醒、交流电/电池、低电量模式和安全可控温度转换的生产信号资格验证；只有具备 benchmark 证据后才增加后台 token bucket/速率策略。
2. 只有在符合连续性丢失资格规程且能够安全复现时，才采集真实守护进程 drop/wrap 证据，并在最低支持 macOS 运行时验证恢复行为。
3. 增加原子迁移备份与只读恢复组合；扩展 golden fixture 矩阵和主库/WAL 损坏场景，且不得静默重建。
4. 实现 ADR-004 剩余历史表和第 30 天老化 dirty path 转换，然后运行 50 万/100 万行的体积、延迟、checkpoint、retention benchmark 与最低系统资格验证。
5. 使用稳定 Apple 身份在 Apple Silicon macOS 15.6 上重跑签名沙盒协议，并覆盖真实 stale 证据、UI 的不同 UUID 换卷子项和系统菜单栏交互矩阵；不得以已完成的当前主机 ad-hoc smoke 代替该门禁。
6. 在签名沙盒矩阵中验证活跃扫描期间撤权和多目录列表变更。
7. 在把当前已经用户可见的基线切片视为 Beta 就绪或具备发布资格之前，完成 ADR-003 与 ADR-004 的维护者评审。
