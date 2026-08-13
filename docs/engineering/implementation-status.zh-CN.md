# 第一阶段实现状态

状态：**架构验证阶段；已具备目录权限、基线与历史概览流程**

最近验证日期：2026-08-13

英文事实源：[implementation-status.md](implementation-status.md)。本文是便于中文阅读的对应译文；如两者存在差异，以英文文档为架构事实源，并应在同一次变更中修正译文。

本文记录第一阶段实现已经证明的内容，也同样明确尚未证明的内容。在 ADR-003、ADR-004 和 ADR-006 的完整验证计划完成并经过维护者评审之前，三份 ADR 仍保持 **Proposed（提议中）** 状态。

## 已实现的证据

| 领域 | 仓库中已有的证据 | 已证明的不变量 |
| --- | --- | --- |
| 领域观测模型 | 经过校验的字节数量、强类型标识、覆盖状态、可比较观测以及保持指标语义的差值 | 未知或部分覆盖的证据不能被展示成“完整且为零字节”的观测 |
| 确定性分类 | 不依赖 Foundation 的持久归因值；纯词法路径特征；明确卷上下文；经过校验的版本化 catalog；固定 priority/具体度顺序；跨类别歧义降级；8 类首版 P0 规则族；无路径证据代码；版本化 precision/recall/Unknown fixture | 分类器不访问文件系统/内容/进程/网络；通用缓存规则不能压过已审阅具体规则；仅凭快照名称不能分类；Unknown 不能持久化成成功类别 |
| 不可变历史发现投影 | 二进制稳定端点身份；精确的 `present`/显式 `absent`/`unknown` 契约；规范目录帧；冻结的版本化分类决策；覆盖感知的增长/减少/出现/消失；四父级稳定身份移动证明；继承移动折叠；受检排他贡献；确定性正增长 Top N；严格 v1 Codable 重验 | 缺失、不完整或未知证据绝不会成为零或消失；重命名启发式不能成为移动；父子流量不会重复计算；墙上时间回拨、输入顺序、Unicode 规范等价和 SQLite 行顺序不能改变排名 |
| FSEvents 桥接层 | 按设备解析监控目标；持久化卷/日志标识；校验卷内相对路径；还原应用绝对路径；支持重启的完整历史回放；可注入故障的流构造；对被拒绝的历史回放和启动后意外终止执行带校准恢复；处理根目录变化哨兵；安全持有原生资源生命周期；有界单消费者适配器；无日志 UUID 卷使用仅实时的主机流降级方案 | 持久回放同时绑定卷 UUID 与 FSEvents 日志 UUID；绝不持久化临时的 `dev_t`；恢复必须先持久化连续性丢失再开始实时监控；非持久降级流只属于一个挂载 generation |
| 挂载生命周期 | 只读 Disk Arbitration 出现、消失、挂载路径变化观测；拥有所有权的回调快照；有界溢出信号；只匹配配置的精确挂载根；仅在已批准 scope 内补充 UUID；纯函数式 scope 挂载 generation 状态机；事务型持久化端口 | 枚举父卷不能激活外部卷 scope；重复回调复用同一个活跃 generation；每次观测到重新挂载都会创建新 generation；相同挂载路径上的不同 UUID 不能继承历史；迟到的卸载只能关闭其对应 generation |
| 非 UI 监控组合 | actor 隔离的 Disk Arbitration 消费；有界挂载就绪重试；事务型激活/关闭；每个 scope 只拥有一个 FSEvents 消费任务；按 generation 条件停止/重启；带指数退避和熔断的启动后恢复；应用层拥有的生命周期状态与有界最新状态流；溢出后重建事件源 | 原生回调顺序不能悄悄重排并发 generation 工作；短暂故障只在固定上限内重试；卸载/替换会取消所属恢复任务；生命周期消费者无需轮询适配器即可获得当前 inactive/active/recovering/failed 状态；回调精度丢失时必须在重新枚举前关闭相关事件流 |
| 权限与 catalog 生命周期 | 非 UI 的只读 bookmark 获取；opaque 应用层记录；精确 root/volume 恢复；重新派生 mount path；隐私安全的部分失败报告；外置卷缺席重试；配对 access lease | stale、路径移动、替换卷、符号链接、非目录和拒绝访问都不能悄悄扩大 scope 或自动刷新；只有暂时缺席会重试 |
| 应用进程生命周期 | AppKit 启动/退出桥接；Application Support 组合；catalog 恢复；唯一 runtime 任务；唯一扫描调度 monitor；一个由应用层持有的后台容量/retention 协调器；异步退出协调；runtime 关闭后释放 lease | 关闭窗口不会停止监控；退出时会先停止原生生产者，再排空所属监控、调度、扫描、容量与 retention 工作，之后才释放权限能力；卷容量采样不依赖目录授权 |
| 目录授权 UI | 用户主动触发的 `NSOpenPanel`；与路径无关的稳定 ID；按顺序投影多个 scope 的 MainActor 状态；可独立操作的已授权/不可用/需重新授权条目；拒绝完全重复根目录；有界新增；逐 scope 更换/移除；混合健康度概况与批量基线入口 | UI 不会从文本路径重建授权；stale 与身份变化必须再次使用系统选择器；变更失败会保留上一次可信投影；移除只释放选中的授权，不删除用户文件或测量历史 |
| 视觉基础层 | 共用的系统语义字体、自适应证据蓝主题色、感知增强对比度的材质面板、统一页面/卡片/指标 Token、优化后的主窗口与菜单栏布局，以及完整原创 16–1024 px macOS 图标矩阵 | 视觉层级不改变证据语义；状态不只依靠颜色表达；不引入第三方字体或仅 macOS 26 可用的视觉 API，不抬高 macOS 15.6 最低版本 |
| 失效映射 | 从适配器语义映射到应用层；词法 scope 校验；文件事件投影到父目录；过滤重放重叠；事件 ID generation 作废；祖先路径合并 | 路径含糊或连续性中断时，牺牲精度并退化为 scope 校准；事件 ID 回绕会作废旧 checkpoint，并让整个摄取批次不携带游标 |
| 元数据校准扫描器 | 基于 Foundation/Darwin 的纯元数据遍历；显式限制条目数、深度、时长与批次；协作式取消；强制同卷；不跟随符号链接；硬链接分配量去重；强类型覆盖缺口 | 永不打开文件内容；叶子路径不会越过目录聚合边界；预算耗尽、权限丢失、挂载边界和取消都不能伪装成完整证据 |
| 校准流水线 | actor 隔离的摄取与有界协调；通过应用层 scanner 端口执行扫描；使用结构化异步 staging | 部分完成或被取消的扫描会丢弃 staging 并保留 dirty work；扫描期间数据若变旧，完成的旧扫描不能发布数据或清除已经更新的工作 |
| 已授权目录基线应用流程 | 精确解析已授权 scope/活跃 stream 上下文；actor 持有可取消批次任务；类型化的准备/暂停/恢复/扫描/发布/完成状态；权限切换时取消；聚合进度与逐根覆盖结果投影 | UI 字节结果只能来自按 revision 校验并原子发布后重新读回的完整根目录聚合；部分覆盖、取消、被取代及被调度器中断的尝试绝不能成为完整事实；路径可能重叠时不伪造聚合字节总量 |
| 目录历史应用层与 UI | 应用层拥有的历史端口和读取模型；根目录受限的 SQLite 适配器；24 小时/7 天/30 天查询用例；明确缺失时间桶；逐根 Swift Charts 曲线；正增长 Top 10；MainActor 加载/空/失败状态；文字与程序化覆盖标记 | UI 不导入 SQLite 模型、不查询未授权根、不把缺口补成零或插值，也不会把重叠根目录或父子目录聚合相加成虚假总量 |
| 历史 finding 概览 UI | 基于 current-effective 与不可变审计读取的有界应用层查询；available/history-disabled/baseline-unavailable 类型化状态；当前增长/移动/消失行；独立折叠的证据失效审计；冻结的分类/置信度/规则/目录/证据码；基线到比较的时间段；准确 metric 与完整证据措辞；显式破坏性 History Off 确认 | UI 不重新分类历史证据、不把失效记录展示成当前记录、不把证据缺失展示成空历史，也不把 finding 描述成清理、删除、归属、APFS 唯一字节或可回收空间 |
| 诊断导出 | 用户主动的栏目/数量预览；默认每次导出独立的路径 token；每次完整路径单独确认；有界 finding 选择；精确冻结规则证据；不含文件内容且无上传的 schema-v1 JSON；私有同步暂存；保存面板目标原子提交；取消与重启清理 | 监控 bookmark 仍显式只读；较宽的用户选择位置写权限只到达精确保存面板目标；取消/失败不会留下用户可见半成品，也不会复用完整路径同意 |
| 启动卷历史与空间归因 | 启动后立即/按小时以及基线原子提交的容量观测；单调序号；24 小时/7 天/30 天卷曲线；持久化根目录卷身份；最上层根 allocated-size 净增长对比；“减少/已解释/无法归因”三步展示 | 卷被替换时会中断比较；外置、嵌套和卷身份未知的根不能获得归因额度；目录证据缺失保持未知；解释量绝不会超过观测到的启动卷减少量 |
| 后台空间生命周期与菜单栏 | 启动/系统时间变化后立即采样；持久化睡眠/唤醒容量边界；睡眠感知延后；系统每天提供机会且 single-flight 的 retention；有界后台健康状态；按提交序号判断 24 小时资格；`MenuBarExtra` 展示当前容量、最近采样/校准和类型化的不完整状态 | 采样与 retention 不会重叠；只有严格相邻且已持久化的睡眠→唤醒边界允许长缺口；醒着漏采、边界缺失/单侧、App 退出、过期端点、时间回拨、换卷、有界查询截断或指标不可用都会取消差值；刷新失败时不能继续把旧结果当作当前结果 |
| 后台 soak 诊断 | 明确开启的应用层 recorder；无路径生命周期/资源 Schema；每次启动随机 session ID；最长 7 天/最多 10 MiB 且受保护的两段式 JSONL；原生 CPU/内存/数据库聚合探针；确定性 24 小时分析器；有界五切片 Activity Monitor/thermal 采集；脱离会话自动最终化；菜单栏可见记录提示 | 默认运行不写资格日志；诊断结构无法表达路径、卷身份、容量具体值或 bookmark；每次成功 wake 最多贡献一次恢复测量；睡眠中的 retention 不请求系统快速重试；日志失败不影响监控；smoke 策略不能生成默认 24 小时通过结论 |
| 扫描调度 | 应用层拥有的电源/温度/活动快照；固定的休眠 → 温度 → 低电量优先级；可回放决策门；结构化取消并重试当前根；提交前准入门；基于公开原生 API 的信号 monitor | 用户主动扫描在普通电池供电时仍可运行；休眠、严重/危急温度和低电量模式会安全暂停；条件恢复后重扫当前根目录，不声称从内存中点续扫 |
| 事件日志端口 | 应用层拥有的持久事件流标识、连续性分类、游标、dirty region、行 revision、原因、批次及条件清理契约 | checkpoint 只有在同一批次中已有持久 dirty work 时才能写入；卷 UUID 或日志 UUID 任一变化都会选择不同的持久事件流 generation |
| SQLite 持久化 | actor 持有的 SQLite3 连接；WAL；schema v13；有界 bookmark/游标/当前状态与 v10 历史；不可变观测帧/端点；append-only 校准修订；注册式线性更正投影；版本化原始/更正 finding 身份与独立失效记录；持久化 History Off；有序图保留；v10–v13 已发布 fixture；类型化磁盘写满/损坏/迁移恢复；当前主机 50 万/100 万行 repository benchmark | 事务/commit marker 阻止部分或跨帧证据；ACK-loss 重试幂等；缺失行绝不成为 absence；终态 current-effective 查询不会回退到前驱并排除目标专属 retraction，审计读取保留所有版本；History Off 阻止新路径历史并保留已授权当前运行；当前主机尺寸/RSS/写入/查询门槛通过 |
| 构建集成 | 本地 `SpaceTraceKit` 已链接到 macOS 应用 target；监控 bookmark 显式只读，用户选择位置读写能力在代码中只到达诊断保存目标；应用保持薄组合根 | 应用 target 能够恢复授权并持有模块化非 UI runtime 生命周期，无需复制源码或让 UI 拥有任务 |

## 验证证据

以下门禁截至 2026-08-13 已使用 Swift 6.2.1 与 Xcode 26.1.1 通过：

- `swift test --package-path Packages/SpaceTraceKit`：611 个测试、80 个 suite（会改变测试环境的资格测试保持 opt-in，常规运行中显示为 skipped）；
- 同一套 package 测试在完整严格并发诊断以及“编译器警告视为错误”条件下通过；
- 分类模块的 7 个 suite、41 个聚焦测试已通过，覆盖词法路径校验、精确组件匹配、priority/具体度顺序、同类别稳定并列、跨类别歧义、明确快照上下文、严格耐久决策、8 个首版 P0 类别、v2 语料的 64 个已知 fixture（每类 8 个）与 32 个 Unknown 近似反例、准确规则 ID/版本/置信度/证据契约，以及相互独立的 precision/recall/Unknown 分母检查；
- 不可变 finding 的 4 个 suite、70 个聚焦测试已通过，覆盖观测帧/模型准入、显式缺失、移动证明与根目录抑制、父子排他贡献、Unicode/序列/scope 平局顺序、严格 v1 Codable 对抗载荷，以及确定性的 2,000 节点移动依赖预算；
- schema v11 迁移、不可变账本 finalization、投影、撤回、History Off/保留与恢复 fixture 套件已通过；最终当前主机 repository 矩阵的十个 50 万/100 万场景全部通过，最坏指标为 231,653,376 字节数据库、114,032,640 字节峰值 RSS、46.69 ms 端点写入 P95、20.48 ms finding 写入 P95、142.02 ms effective Top-10 P95 和 75.75 ms 旧历史七日 Top-100 P95；完整证据见 [SQLite v11 历史账本](sqlite-v11-historical-ledger.zh-CN.md)；
- 一条从适配器到应用层再到真实 SQLite 的集成测试，校准 scanner 使用注入实现；
- 四条串行的按设备 FSEvents 集成测试，在受保护的一次性 APFS 目录上覆盖持久标识解析、实时事件、单订阅失败、取消清理、显式停止、重启、经 `HistoryDone` 完成的历史回放以及真实回调缓冲区溢出标记；
- 异步溢出断言加固后，按设备集成测试连续运行 100 次未出现间歇性失败；测试使用原生同步 flush 作为观测边界，不依赖定时 sleep；
- 确定性的 Disk Arbitration 回调解析、溢出、单订阅、停止与原生 session 生命周期测试，以及挂载状态机和 SQLite v3 到 v4 迁移测试；
- 一项 opt-in 受控资格测试使用两个同名 64 MiB APFS 镜像，覆盖正常卸载、同卷重新挂载、相同挂载点上的不同 UUID 替换、不同 generation/stream ID，以及首个卷与替换卷上的实时 FSEvents dirty 证据；通过运行耗时 3.924 秒；
- 一项 opt-in 当前主机 APFS FR-004 资格测试在一次性监控子树中真实分配并刷盘 5 GiB 文件，持久化无游标的 kernel-drop 连续性缺口，执行有界生产校准，并把准确子树恢复为至少 5 GiB 的 allocated 增长 finding 与正排名贡献；通过运行耗时 1.434 秒，随后删除夹具；
- 通过可注入 client 与 resolver 的确定性测试，证明原生流创建失败和启动失败都会作废存量回放 checkpoint、持久化 scope 级校准工作、只尝试一次 `sinceNow` 恢复，并在该恢复同样失败时保持非活跃状态；
- 通过确定性的启动后生命周期测试，证明自动实时恢复、连续性作废持久化、启动失败和重复终止的有界熔断、退避期间取消、拒绝未知/替换卷身份以及恢复策略参数校验；测试不依赖定时 sleep；
- 通过确定性的生命周期状态观测测试，证明当前状态回放、`inactive → active → recovering → active`、终态 `failed`、按 generation 停止后的清理，以及缓冲区正数校验；
- 通过确定性的 bookmark/catalog 测试，证明有效/stale 部分恢复、外置卷缺席后重试、stale 不自动刷新、授权获取持久化、完全重复根目录拒绝、lease 恰好释放一次，以及真实原生无 UI bookmark round-trip；同时覆盖 SQLite 到 v7 的迁移与进程生命周期取消/清理；
- 固定 GRDB 7.10.0 版本的 Release SPM spike 证明当前主机编译、`DatabasePool`/`DatabaseMigrator` 执行、默认 product 链接和系统 SQLite 链接；同时完成官方许可/manifest 证据评审，并明确第一阶段继续使用原生 SQLite；
- 确定性的真实 `SQLITE_FULL`、损坏主文件保留、提交前迁移回滚、retention 边界和固定时钟 retention 测试，覆盖过期 deleted node、可替代基线与无引用 scan run；
- 确定性的授权移除失败顺序、授权协调器重启/回退，以及覆盖选择、取消、stale 重新授权、撤权和外置卷返回的 MainActor ViewModel 测试；
- 确定性的应用外壳测试证明只暴露已实现的概览/权限目的地，并且 unavailable、stale 或 failed 授权绝不会在概览中显示为已就绪；
- 确定性的已授权目录基线、目录历史与不可变 finding 概览测试证明类型化阶段顺序、取消完成、部分覆盖/被取代结果不发布、权限切换前取消、从真实 SQLite 读回完整根目录聚合、独立历史曲线、明确缺口、根目录受限增长、跨 scope 拒绝、current-effective/审计分离以及类型化 History Off/baseline-unavailable 状态；同时 29 个应用单元测试通过，覆盖 MainActor 多 scope 投影、批量命令转发、恢复后的历史上下文、窗口切换、失败/取消状态、不可用时间桶处的图表断线、菜单栏证据投影、策略失败时保留可信结果以及明确的资格记录可见性；
- 确定性的扫描调度测试证明策略优先级、普通电池供电可运行、当前决策回放/去重、初始暂停时 scanner 调用次数为零、扫描途中取消、恢复后重试同一根目录，以及 Foundation/IOKit 原生值映射；
- 确定性的后台生命周期测试证明睡眠延后、唤醒/时间变化后立即采样、采样与 retention 失败恢复、原生通知适配、30 个虚拟日的有界串行运行、全部 24 小时资格失败边界，以及真实 SQLite 25 条样本查询路径；MainActor 菜单栏测试同时证明合格结果投影、状态优先级和刷新失败时 fail closed；
- 确定性的后台 soak 测试证明无路径编码、序号/资源/retention 的 fail closed 分析、睡眠包围缺口处理、受保护的有界轮转与过期、原生聚合资源探针，以及菜单栏明确记录提示；recorder、writer、probe 与分析器同时通过严格并发编译；
- 当前主机使用独立 bundle identity 的 ad-hoc 签名 Release/App Sandbox 诊断 smoke：7 条记录 / 241.636 秒、正常退出、3,585 字节受保护无路径日志、分析器 smoke 通过、平均/p95 CPU 占比 0.0344%/0.0907%、最大常驻内存 135,495,680 字节、数据库聚合大小 263,496 字节；它明确不属于 24 小时、能耗、Apple 身份或 macOS 15.6 运行证据；
- 当前主机 ad-hoc 签名 Release/App Sandbox 真实长跑采集到单一 session、1,693 条无路径记录、成功 retention、约 900 KiB 受保护诊断，以及五段无采集失败的完整 Activity Monitor/thermal 切片；默认分析器因长睡眠后缺少 24 小时容量端点以及重复计算的虚假 wake 恢复指标而失败，因此该运行只保留为失败/诊断证据，不报告为 qualified。合计 25 分钟的有界 Instruments 证据为：CPU 0.493001 秒、Idle Wake Ups 1,180 次、写入/读取 2,023,424/155,648 字节、最大物理内存 footprint 53,068,760 字节、未阻止睡眠、Thermal State 均为 Nominal。wake 指标和睡眠 retention 重试缺陷现已加入确定性回归，脱离会话自动最终化也通过 60 秒签名沙盒 smoke；
- 2026-07-29 的 schema-v10 当前主机重跑通过签名沙盒预检和首段 Activity Monitor attach，但在 212.012 秒后收到外部正常 `exit(0)`；它只保留为中断证据，不属于 24 小时结果。主机后来还在计划窗口内关机并重启。本次中断暴露了 runner 的 zsh EXIT-trap 作用域以及 launchd 推断 KeepAlive 两项缺陷；
- 两轮相互独立的签名沙盒 smoke 证明加固后的 runner：受控提前退出会生成受保护、带类型原因的 `FAILED` 证据并移除 supervisor；不受干扰的 60 秒运行则生成 `PASSED`，采集失败为 0、隐私扫描为空、分析器状态为 0、单一 session 的 4 条记录覆盖 59,737 ms，且 launchd job 无残留；
- 修正后的 2026-07-30 当前主机 ad-hoc Release/App Sandbox 长跑自动生成 `PASSED`：单一 session 的 794 条无路径记录覆盖 90,529,656 ms，retention 成功且最终容量为 qualified；最大清醒间隔 62,097 ms、最大唤醒恢复 1 ms、最大 RSS 139,984,896 字节、最大数据库 613,696 字节、平均 CPU 0.011710%、p95 CPU 0.039200%。五段 Activity Monitor/thermal 导出全部完成且采集失败为 0；确定性后分析得到采集区间 CPU 0.401045252 秒、Idle Wake Ups 959 次、写入/读取 811,008/352,256 字节、最大 footprint 99,271,664 字节、未阻止睡眠、温度状态均为 Nominal。受保护的 Instruments 汇总不含路径并固定 SHA-256；这只关闭当前主机 ad-hoc 24 小时门禁。2026-08-10 又以独立 bundle identity 完成 60 秒 smoke，新的双分析器最终化在采集失败为 0、两个分析器退出码为 0、报告受保护以及 App/launchd 无残留的条件下通过；
- 2026-07-31 使用独立 bundle identity 的临时签名 App，在 1080 × 720 下完成概览层级和图表布局的视觉检查；16–1024 px 图标资产完成 Alpha 校验；App 单元测试及 `make verify` 通过。同日 UI runner 无法初始化，因此该次尝试继续保留为历史阻塞证据，不报告为通过；
- 使用本机测试签名运行真实 Xcode macOS UI runner：2026-08-10 在 macOS 26.5.2 上通过 8 个受控权限/不伪造历史场景，2026-08-13 又在 macOS 26.6.1 上通过 15 个授权/历史/finding/导出场景。测试会断言主要/更换/移除操作具有稳定名称且可点击，原始/更正 current 与证据失效 finding 分离，冻结分类/时间证据可见，History Off/baseline-unavailable 保持类型化，破坏性操作需要确认，并确认“只读、不删除文件”隐私边界进入可访问性树。签名沙盒诊断场景会操作真实 `NSSavePanel`、从磁盘读取脱敏 JSON，并额外连续聚焦运行 3 次通过。每次启动都会明确忽略 macOS 持久化窗口状态，确保测试拥有可见的全新窗口。这些确定性 fixture 不覆盖真实 bookmark 替换连续性，人工 VoiceOver/键盘/显示辅助检查也仍未完成；
- 已实现 fail-closed 的 ad-hoc Release Candidate 打包器：要求明确 SemVer 与干净 commit provenance，检查 arm64/15.6/Bundle ID、精确三项沙盒 entitlement，以 Hardened Runtime 重签，固定六项产物契约，生成只读压缩 DMG、带 checksum 的 JSON 事实 manifest、确定性 SPDX 2.3 与 notices，并覆盖参数缺失/非法、脏源码和已有输出的反向测试。entitlement 契约把用户选择位置读写能力只用于精确 `NSSavePanel` 诊断目标，而监控 bookmark 仍显式只读。保留的 `0.1.0-rc.5` 包和来自已推送 commit `a6ba750` 的独立替换构建通过了打包与进程替换启动资格；精确临时容器清理仍被 macOS 隐私保护阻止。项目许可证在所有者批准前保持 `NOASSERTION`；
- 早期当前主机 ad-hoc 签名 smoke App 的严格签名校验确认了旧的用户选择只读 entitlement 与 `LSMinimumSystemVersion = 15.6`；该证据只作为历史记录保留。新的“读写仅用于保存” entitlement 需要重新完成签名沙盒与 macOS 15.6 资格验证；
- 当前主机签名沙盒 smoke 已证明精确 Powerbox 选择、正常退出后同一 bundle 无选择器恢复、App 内 bookmark 移除不删除夹具、一次性 APFS 镜像缺席时显示不可用，以及同一 Volume UUID 返回后自动恢复授权；
- 已在当前主机检查普通单窗口外壳、概览准备状态、侧栏导航和嵌入式权限旅程的视觉布局与可访问性树；公开 SwiftUI `MenuBarExtra` 已编译进同一进程，其最终状态项点击矩阵仍属于签名 UI 资格验证；
- 穷举运行两个持久卷身份与三个运行时磁盘身份组成的全部 2,401 条四信号应用状态序列，并为用户态丢失、内核丢失、事件 ID 回绕和回调溢出提供参数化的端到端持久化/校准证据；
- 权限丢失、符号链接、挂载边界、硬链接、预算和取消的确定性元数据 fixture，以及仅作用于一次性临时目录的生产适配器测试；
- `make verify`，其中包括架构检查、package 测试、Xcode scheme 发现、Debug 构建、应用单元测试和 Release 构建；
- Xcode 以 `arm64-apple-macos15.6` 为目标完成编译与链接，本地 package 从当前仓库解析。

严格并发运行用于审计本次新增的 package 代码。根据 ADR-001，应用 target 仍使用 Swift 5 语言模式；全仓库 Swift 6 迁移仍是独立的决策与验证任务。

## 明确不作出的声明

- 面向用户的多目录权限列表、批量基线、启动卷容量历史、版本/Schema 元数据、重启恢复、电源/温度/睡眠感知、schema v10 概览/菜单栏历史、不可变 finding 概览、schema v13 持久化、完整扫描 paired finalization、完整父级消失对账、合格 APFS 稳定移动、有界即时/启动投影、FR-007/KPI-03 仓库语料门禁，以及用户控制的脱敏诊断导出均已实现。生产扫描会在同一次遍历中冻结仅目录 logical/allocated 证据、直接子级覆盖、分类与 APFS 对象/复用证据；真实 Foundation 增长/重命名/删除与受控 APFS 镜像测试均已通过。概览直接读取终态版本化 current-effective 与失效审计记录，不重新分类，展示耐久校准状态与类型化 History Off/baseline-unavailable 状态。中断基线会安全丢弃未完成 staging，并重新扫描受影响的持久 dirty root，因此在不声称内存枚举偏移续跑的前提下满足 FR-002；真正中点续跑保留为非 P0 性能增强。Schema v12 修订/更正与纯追加 schema v13 更正 finding 失效记录现在覆盖 current-effective/审计查询、耐久状态、恢复/保留、诊断、UI 和一次真实 5 GiB 当前主机资格。文档规定的 19/20 原型 KPI 矩阵仍是发布资格，而不是实现声明。未经证明的缺失行和不受支持的文件系统仍会被抑制。APFS 唯一块核算也仍未完成。导出 entitlement 与真实签名沙盒保存流程已通过当前主机资格；人工辅助技术、干净账户 Gatekeeper 例外、打包 bookmark 连续性和 macOS 15.6 资格仍未完成。
- 修正后的当前主机运行关闭了提交 `ed0d660` 的 ad-hoc 24 小时进程/耐久门禁。Activity Monitor 的 CPU、唤醒、内存、I/O 与 thermal 区间仍只是能耗相关证据，不是直接瓦特/焦耳测量；该结果也不能证明普遍的系统调度到达保证、签名状态项交互矩阵、Apple 身份分发、Release Candidate 替换或 macOS 15.6 运行资格。
- 用户主动基线调度会响应休眠、低电量模式、严重/危急温度，并观察当前供电来源。后台速率预算、系统负载调度以及架构中的 token bucket 尚未实现。硬链接去重受条目预算限制，但每次扫描运行期间仍保存在内存中。
- 真实 sandbox Powerbox 展示以及 stale/身份失败的重新授权 UI 已实现；当前主机上的持久选择、同一 bundle 重启、明确 App 内移除和同镜像外置卷返回已经通过。真实 stale 证据、UI 流程中的不同 UUID 换卷子项、Apple 身份签名以及 macOS 15.6 运行矩阵仍未完成，或受到当前环境阻塞。
- 当前主机的受控 UI fixture 已 15/15 通过，并检查关键辅助功能名称、value 与可点击性，包括原始/更正 finding、History Off 和真实保存面板导出流程；这不是人工辅助技术资格验证，不能证明 VoiceOver 发音、Full Keyboard Access 顺序，或增强对比度、减少动态效果和更大系统文字下的布局。
- ad-hoc RC 打包只适合人数较少、明确互相信任的测试者；它没有 Developer ID 签名或公证，在用户授予单 App 例外前应被 Gatekeeper 拒绝，也不能证明 bookmark 跨替换连续、真实拒绝/stale 授权、外置卷替换、干净 Mac quarantine 启动、自动更新、回滚或完整容器移除。
- 不会依据 FSEvents 推断精确字节差值或进程归因。
- 原生资格测试已经在开发主机上覆盖受控卸载、重挂和同名卷替换；但最老支持系统的真实运行、守护进程真实 `UserDropped`/`KernelDropped`、事件 ID 回绕、睡眠/唤醒以及权限撤销仍未完成资格验证；允许采用的证据边界记录在 [FSEvents 连续性丢失资格验证](fsevents-continuity-qualification.zh-CN.md) 中。
- 启动后自动恢复已经有界且经过测试，但守护进程真实 drop/wrap 条件以及最老支持 macOS 上的恢复行为仍未完成资格验证。
- 原生 SQLite 适配器现已覆盖 schema v13 迁移/digest、原子备份/只读恢复、v10–v13 canary fixture、图保留/History Off、原始与更正 finding 的 retraction/effective/audit 查询、可复现的 50 万/100 万行当前主机 repository benchmark、生产 paired finalization/校准，以及提交后处理新 work 并在启动时恢复持久化 work 的有界应用 projector。GRDB 等价、额外生产 artifact 恢复资格、公证及最低系统运行/性能仍未完成。
- 尚未完成 macOS 15.6 真实运行资格验证；在较新主机上按 deployment target 编译不等于运行证据。
- Full Disk Access、App Sandbox 移除、Developer ID 签名、公证、分发及更新行为均未改变，继续由相应的 Proposed 决策约束。

## 下一批验收门禁

1. 使用 Apple 身份签名 sandbox App 在 macOS 15.6 上完成同一套真实 24 小时运行、睡眠/唤醒、时间/时区变化、交流电/电池、低电量模式和安全可控温度转换的生产信号资格验证；并在当前稳定版 macOS 上以 Release Candidate 重跑，验证 retention 到达、菜单栏资格/降级、能耗相关进程证据、内存和数据库增长。只有具备 benchmark 证据后才增加后台 token bucket/速率策略。
2. 只有在符合连续性丢失资格规程且能够安全复现时，才采集真实守护进程 drop/wrap 证据，并在最低支持 macOS 运行时验证恢复行为。
3. 扩展页级主库/WAL 损坏场景和已发布 fixture，且不得静默重建。
4. 在接受 ADR-004 前，于最低参考 macOS 15.6 机器上复跑 50 万/100 万行 benchmark。
5. 使用稳定 Apple 身份在 Apple Silicon macOS 15.6 上重跑签名沙盒协议，并覆盖真实 stale 证据、UI 的不同 UUID 换卷子项和系统菜单栏交互矩阵；不得以已完成的当前主机 ad-hoc smoke 代替该门禁。
6. 在签名沙盒矩阵中验证活跃扫描期间撤权和多目录列表变更。
7. 在把相应界面视为 Beta 就绪或具备发布资格之前，为用户可见的基线/历史切片完成 ADR-003 与 ADR-004 维护者评审，并为不可变 finding 完成 ADR-006 维护者评审。
8. 在 macOS 15.6 与当前稳定版 macOS 上，为已实现的 finding 概览完成人工键盘、VoiceOver、对比度、大字体和不确定性措辞复核。不受支持的文件系统与未经证明的缺失行必须继续被抑制。v12 更正链与 v13 目标专属失效记录已经实现，但产品措辞仍需该人工复核。
9. 在签名沙盒与打包 DMG 中验证已实现的用户控制导出：覆盖保存面板写入、默认/token 脱敏、每次完整路径同意、取消/重启恢复和辅助技术行为，并且绝不自动上传。

## 发布决策（继续维持 NO-GO；证据更新于 2026-08-13）

- **本地工程 RC 生成：CONDITIONAL GO（有条件继续）。** 可以使用 fail-closed ad-hoc 打包器，为明确互相信任的维护者/测试者生成带 provenance 的受控测试产物。
- **GitHub Release 与 Public Beta：NO-GO（暂不发布）。** 本次没有创建 tag、Release 或上传产物。
- 阻塞门禁包括：重复 FR-004 原型 KPI 矩阵；macOS 15.6 运行；人工辅助功能/可用性和真实 bookmark/权限/换卷矩阵；ADR-003/004/006/008/009 接受；Developer ID/公证，或明确接受未签名风险并完成干净账户 Gatekeeper 例外启动；打包升级/回滚；以及仓库所有者批准项目许可证。确定性 SBOM/notices 生成、自动化 finding/History-Off/校准概览、FR-007 语料和 FR-014 实现/当前主机真实签名沙盒导出门禁已经关闭，但打包/人工辅助技术与最低系统资格验证尚未完成。
- 逐行门禁表和未发布的测试者说明见[产品路线图](../product/product-roadmap.md)与 [Changelog](../../CHANGELOG.md)。
