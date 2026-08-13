# SpaceTrace Quality Strategy

Status: **Baseline**

Owners: Maintainers

Last reviewed: 2026-07-18

SpaceTrace 观察用户磁盘元数据并长期运行。质量的核心不是 UI 截图数量，而是：结果可解释、扫描不会拖慢 Mac、权限不足不会伪造完整结果、升级不会损坏历史记录、任何操作默认不触碰用户文件内容。

关键词 **MUST**、**SHOULD**、**MAY** 的含义与 [Development Process](./development-process.md) 一致。

当前 Xcode 工程的所有 Project/App/Unit Tests/UI Tests 配置均以 macOS 15.6 为最低部署版本，首发正式支持 Apple Silicon；Swift language setting 仍为 5.0。最低版本决定见 ADR-001。CI 上使用较新 macOS 完成编译不能代替 macOS 15.6 运行时验证；Public Beta 前必须在物理机或虚拟机上完成最低系统的 P0 smoke matrix。

## 1. Quality attributes and budgets

以下是发布门槛，不是愿景指标。基准机在仓库 `docs/engineering/benchmark-environment.md` 建立前，使用 Apple Silicon 8 GB、内部 APFS SSD、接通电源、关闭 Low Power Mode 的最小支持系统机器；每次结果 **MUST** 记录芯片、内存、系统版本、温度状态和数据规模。

| Attribute | Release budget |
|---|---|
| Correctness | 相同 fixture、相同配置重复 3 次，聚合结果完全一致；未知/不可访问项不得归类为可安全删除 |
| Idle overhead | 无扫描时 30 分钟窗口平均 CPU < 0.5%、p95 CPU < 2%；30 天基准数据下 p95 resident memory < 150 MB、数据库 < 250 MB；磁盘写入 < 1 MB/小时（正常历史 checkpoint 除外） |
| Incremental processing | 10,000 个合成文件事件处理 p95 < 2 秒，队列最终清空，无事件风暴死循环 |
| Initial scan | Prototype 必须实测 500,000 与 1,000,000 节点并在 Alpha 前设定正式预算；在此之前 100,000 节点 > 30 秒或 1,000,000 节点 > 8 分钟触发调查而非对外性能承诺；取消响应 < 1 秒 |
| UI responsiveness | warm launch 到菜单栏可交互 p95 < 2 秒；7 日 top-100 查询 p95 < 500 ms；主线程连续阻塞不得超过 100 ms |
| Energy | 后台无用户操作时不得持有 idle-sleep assertion；常规增量监控不得持续使用 > 2% 单核 CPU 超过 60 秒 |
| Reliability | 24 小时 stress run 无 crash、无未界定内存增长；数据库中断恢复不得丢失最后一个已提交 checkpoint 之前的数据 |
| Package quality | Release 构建零 compiler warning、零 SwiftLint warning、零已知 Critical/High 可利用依赖漏洞 |

如果功能合理地突破预算，必须先有 RFC，量化用户收益、设备范围和新预算；不得仅以“真实环境会更快”为由豁免。

## 2. Test pyramid and ownership

测试与代码在同一 PR 交付。修改生产逻辑的作者负责对应测试；模块 code owner 对 fixture 语义和 release gate 负责。

### 2.1 Unit tests

单元测试 **MUST** 覆盖：

- 路径规范化、Unicode、大小计算和单位转换；
- 分类规则的 precedence、unknown 和 confidence；
- snapshot diff、事件去重、checkpoint、取消与重试；
- retention、redaction 和诊断包选择逻辑；
- 数据库 repository 与迁移的错误路径；
- 时间、文件系统、卷信息和权限 provider 的 fake 实现。

测试不得依赖真实 `$HOME`、时区、语言、网络、当前日期或目录枚举顺序。时间、UUID、调度器和文件系统边界 **MUST** 可注入。

Coverage 门槛：

- 新增/修改可执行行 changed-line coverage **MUST** >= 85%；
- 扫描、diff、分类、retention、redaction、迁移模块 line coverage **MUST** >= 90%，branch coverage >= 80%；
- 全仓 line coverage **MUST** 不低于 80%，且不得比 `main` 下降超过 0.5 个百分点；
- 纯 SwiftUI layout、生成代码和无法稳定触发的 OS glue 可排除，但排除规则必须在配置中注明原因。

Coverage 不能替代场景测试。为达到数字而断言实现细节或大量 snapshot 空值测试 **SHOULD NOT** 合并。

### 2.2 Integration tests

集成测试 **MUST** 使用临时 APFS 目录或可控文件系统 adapter，覆盖：

- 首次扫描 -> snapshot -> 增量事件 -> diff 查询完整链路；
- 文件创建、删除、重命名、硬链接、符号链接环、不可读目录、挂载点变化；
- 稀疏文件、package、超长路径、组合/分解 Unicode、同名不同大小写；
- 事件丢失/overflow 后触发受控 rescan，而不是静默继续；
- FSEvents 启动后意外终止必须先持久化连续性丢失，再按 generation 有界恢复；连续失败触发熔断，卸载/替换必须取消退避任务；
- 生命周期观测必须发布有界的 `inactive`、`active`、`recovering`、`failed` 应用状态；消费者压力可以合并中间快照，但不得丢失当前最终状态；
- 真实守护进程 drop/wrap 只能按 [FSEvents 连续性丢失资格验证](./fsevents-continuity-qualification.zh-CN.md) 记录；注入标志与应用缓冲区溢出不得冒充系统守护进程证据；
- 用户取消、系统睡眠/唤醒、应用终止后恢复 checkpoint；
- 后台容量采样在睡眠期间不得写入，唤醒、系统时间或时区变化后必须立即请求采样；retention 必须 single-flight、可延后，并且失败后能够在后续机会恢复；
- 菜单栏 24 小时结果必须由单调提交序号、同卷身份、新鲜端点和不超过 90 分钟的连续采样共同证明；缺口、回拨、换卷和不可用值必须降级为“证据不足”；
- SQLite busy、磁盘空间不足、数据库损坏副本和只读文件系统；
- 诊断包默认不包含原始路径、文件名或文件内容。

CI 集成测试禁止扫描 runner 的真实主目录。任何测试 helper 若接收到 `/`、`$HOME` 或未解析的空路径 **MUST** fail closed。

真实挂载生命周期使用显式 opt-in 的 `make package-apfs-image-qualification`。夹具只能在 UUID 命名的临时目录创建小型镜像，设备标识必须匹配受控 attach 响应和 `/dev/disk…` 白名单；正常路径使用普通 detach，强制 detach 仅可作为该临时设备的失败清理兜底。此测试不得进入通用并行 CI，也不得接触现有卷。

FR-004 的 19/20 发布 KPI 使用显式 opt-in 的 `make package-apfs-reconciliation-matrix-qualification`。入口必须先确认唯一 SwiftPM 测试标识，再在 APFS 临时卷上顺序运行恰好 20 次生产校准链；同一时刻只允许一个 5 GiB 夹具，开始每轮前可用空间不得低于 8 GiB。19 次成功是最低门槛，失败轮次不能被自动重试或从分母移除。结果只保存 commit、主机/工具链/thermal 概况、每轮结果与有界耗时，不得保存测试路径或原始 Swift 输出；报告以 `0600` 创建并且不得覆盖已有证据。`make verify` 只验证这个 runner 的计数、阈值和 fail-closed 契约，不执行真实 100 GiB 累计分配工作。

### 2.3 UI and accessibility tests

UI 测试聚焦关键旅程：首次启动、权限拒绝、部分覆盖、首次扫描、查看增长来源、暂停/恢复、清除历史、导出诊断。每个旅程至少有一条 automated smoke test 和一条 release 手测记录。

- VoiceOver label、键盘导航、Dynamic Type/系统字体缩放、Reduce Motion、Increase Contrast **MUST** 在每个 minor release 手测。
- 截图 golden 只用于稳定组件；系统字体或系统控件变化不得通过降低像素容差掩盖真实回归。
- 错误、权限缺失和置信度不得只用颜色表达。

### 2.4 Performance and endurance tests

Performance suite **MUST** 对 100k、1M 节点 fixture 记录 wall time、CPU time、peak RSS、数据库大小和写入量。结果与最近 10 次 `main` 中位数比较：

- 任一 release budget 超限：阻塞；
- p95 回归 > 10% 且绝对变化 > 100 ms：阻塞，除非有获批 RFC；
- 5%–10% 回归：PR 必须解释并由 maintainer 接受；
- 单次噪声不得直接更新基线，基线更新需要至少 5 次稳定样本和独立 PR。

Nightly **MUST** 运行 24 小时事件风暴/空闲交替测试；内存线性增长、未关闭文件描述符或数据库持续膨胀均阻塞发布。

提交前可以用 `make package-background-lifecycle-qualification` 执行 30 个虚拟日的确定性生命周期测试。它证明状态有界、操作串行以及睡眠/唤醒/时间变化/retention 分支，但不得替代 Nightly 的真实 24 小时进程、能耗、内存和系统调度证据。

### 2.5 Upgrade and migration tests

每次 schema 或 retention 变化 **MUST**：

- 保留最近两个已发布 schema（N-1、N-2）的只读 golden database；
- 从 N-1/N-2 升级到当前版本并验证计数、大小、时间、分类和用户设置；
- 在迁移每个写入阶段注入终止/磁盘满，验证原数据库仍可恢复；
- 重复执行迁移，验证幂等或明确拒绝；
- 验证新版本数据库被旧版本打开时安全拒绝，不做降级写入；
- 迁移前创建原子备份，成功 checkpoint 后才清理，并记录保留策略。

删除 fixture 只有在对应支持版本退出至少一个 minor release 后才允许，并须在 PR 解释。

### 2.6 Permission degradation tests

至少覆盖 Full Disk Access：未请求、拒绝、部分可读、授权、运行中撤销、重新授权六种状态。每种状态 **MUST** 验证：

- 不 crash、不无限重试、不反复弹系统设置；
- UI 明确标示覆盖范围与最后成功时间；
- 不把 `permissionDenied` 计作 0 bytes 或“无增长”；
- 已采集数据不会因暂时失权被错误删除；
- 恢复权限后只执行必要 rescan；
- 日志不泄露被拒绝路径。

SpaceTrace 首版不需要 root、Accessibility、Screen Recording、Contacts 或网络数据权限。新增任一权限必须通过 RFC、威胁模型与对应拒绝测试。

## 3. Fixtures and golden data

### 3.1 Fixture principles

- Fixture **MUST** 是合成数据或经过书面确认的公开数据；禁止提交开发者真实目录、用户名、卷 UUID、应用数据库和诊断包。
- 每组 fixture 包含 `manifest`：schema version、seed、预期节点/字节数、语义说明、生成器版本和 SHA-256。
- 大 fixture **SHOULD** 由确定性 seed 生成，仓库只存 manifest 和小型 golden；避免提交数 GB 二进制。
- OS 特有元数据无法在普通 fixture 表达时，使用专用 integration fixture，并标记所需 filesystem/OS。

### 3.2 Required canonical cases

仓库至少维护：

1. 普通目录增长/缩小；
2. Xcode Simulator、Docker/VM、AI model/cache 的可解释目录样例；
3. unknown category 与同等置信度冲突；
4. package、symlink cycle、hard link、sparse file、clone-like accounting；
5. iCloud/Files-on-Demand 占位语义的 provider stub；
6. 权限拒绝和扫描中途挂载点消失；
7. N-1/N-2 数据库；
8. 恶意文件名：换行、控制字符、RTL、emoji、超长 Unicode；
9. 事件 overflow 与全量 rescan；
10. 经过默认脱敏的诊断包 golden。

Golden 更新必须由语义变更驱动。PR **MUST** 同时给出 human-readable diff；禁止用“全部重新生成”替代审查。

## 4. Static analysis and code health

- SwiftFormat 配置是唯一格式标准；CI 执行 check，不自动改写 PR。
- SwiftLint 使用 `--strict`；全局 disable 规则需要配置注释和 issue，行级 disable 必须有原因。
- 强制并发检查使用项目可用的最严格 Swift concurrency mode；新增 `@unchecked Sendable` **MUST** 有不变量说明和并发测试。
- Release 构建 warning 视为错误；禁止新增 force unwrap、`try!` 和未解释的 `fatalError` 于用户可达路径。
- 依赖方向和模块循环由架构检查约束；核心扫描/分类模块不得依赖 SwiftUI、Sparkle 或具体 OS 日志实现。
- TODO/FIXME **MUST** 关联 issue；临时 suppressions 必须有 owner 与到期日期。

本地与 CI **MUST** 暴露同一入口 `make verify`；`Makefile` 是验证命令真相源，CI 只调用该入口。维护者不得让 README 与 CI 使用不同 flags。

仓库和 CI 的完整验证入口是：

```bash
make verify
```

`make verify` 包含 `make package-concurrency-audit`，对 local-package 代码启用完整并发诊断并将 compiler warning 视为错误。该 package-only 审计不表示应用 target 已完成 ADR-001 所述的全仓 Swift 6 迁移。

CI **MUST** 先执行 `xcodebuild -list -project SpaceTrace.xcodeproj` 验证 shared scheme 可发现，并使用独立 DerivedData 目录；测试结果和 coverage 以 `.xcresult` 归档，不解析易变化的控制台文本作为唯一证据。

## 5. CI topology

### 5.1 Pull request checks

每个 PR 在最低支持 macOS + 最新稳定 Xcode 的编译组合上验证，并在最新稳定 macOS runner 运行测试。若 CI provider 无最低系统 runner，release 前必须在真实/虚拟最低系统完成 smoke test并附证据。

Required jobs：

- `hygiene`：secret scan、generated/fixture integrity、Markdown links；
- `style`：SwiftFormat、SwiftLint strict；
- `build-debug` 与 `build-release`；
- `test-unit` + coverage；
- `test-integration`；
- `test-permission-degradation`；
- `dependency-review`。

路径过滤只允许跳过与变更确实无关的昂贵 job；`hygiene` 始终运行。测试 job 超时上限 20 分钟，超时视为失败。

### 5.2 Nightly and release checks

Nightly：1M fixture、性能趋势、24h stress（可拆为定期专机）、完整依赖/许可扫描、数据库 integrity。连续 2 次 nightly 失败 **MUST** 建 P1 issue，并在修复前禁止稳定 release。

Release：N-1/N-2 升级、最低/最新 OS 手测、签名、公证、所选更新机制（采用 Sparkle 时包含 appcast 正常/无效签名）、DMG 安装、离线运行、SBOM、产物哈希和 clean-machine smoke test。

### 5.3 Flaky-test policy

- CI 不得通过自动 retry 把失败显示为绿色；可以重跑一次用于诊断，但原失败仍记录。
- 确认为 flaky 后 24 小时内创建 owner/根因/截止日期 issue；关键安全、迁移、redaction 测试不得 quarantine。
- quarantine 最长 7 天；全仓 quarantine 比例不得超过测试数的 2%。超过即阻塞 feature merge。
- 修复必须证明至少连续运行 100 次或覆盖原随机 seed 无失败。

## 6. Manual release test matrix

每个 stable release 至少记录以下组合：

| Area | Required scenario |
|---|---|
| Installation | clean install、覆盖安装、从上一 stable 通过已选更新机制升级；若采用 Sparkle 则验证 Sparkle 更新 |
| OS | 最低支持版本、最新 stable；beta OS 只做 best effort |
| Permission | 拒绝、授权、撤销、恢复 Full Disk Access |
| Storage | 小磁盘空间、外置卷消失、sleep/wake、事件积压 |
| History | 空数据库、N-1、N-2、清除历史、retention 运行 |
| Network | 离线启动、更新服务器不可用、无效 appcast 签名 |
| Accessibility | VoiceOver、keyboard-only、Reduce Motion、Increase Contrast |
| Privacy | 日志/诊断包抽查，默认无路径和文件名 |

证据包括版本、设备、步骤、结果、失败 issue 和执行人；“本地试过”不是有效证据。

## 7. Defect escape and quality review

- 每个 P0/P1 生产缺陷 **MUST** 在 5 个工作日内完成 blameless incident review：触发条件、为何未被测试/门禁捕获、纠正与预防措施、owner/期限。
- 同类缺陷 90 天内重复出现时，必须提高对应自动化门禁，而不仅增加一条手测说明。
- 每月审查 crash、用户报告、性能趋势、flaky rate、权限失败和升级失败；无遥测时明确标注样本偏差。
- 每季度重新验证预算是否仍代表受支持的最低设备，不因新机器更快而放宽后台开销。
