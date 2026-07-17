# SpaceTrace Privacy and Security Baseline

Status: **Baseline / living threat model**

Owners: Maintainers

Last reviewed: 2026-07-18

SpaceTrace 的价值来自读取磁盘元数据，这也意味着文件路径、目录结构、时间和应用痕迹可能暴露用户身份、客户名称或项目内容。本文件是架构和发布门禁，而不是市场声明。关键词 **MUST**、**SHOULD**、**MAY** 表示强制、默认应遵循、可选。

## 1. Product security promises

稳定版必须保持以下承诺；改变任一项需要 RFC、ADR、显著 release note 和隐私审查：

1. **Local-first:** 扫描、归因、历史和搜索在本机完成。
2. **No telemetry by default:** 不收集 analytics、crash report、设备标识、文件系统统计或使用事件。
3. **Metadata, not contents:** 不读取、索引或存储文件内容；只收集完成空间归因所需的最小文件系统元数据。
4. **Read-only toward user data:** 默认不删除、移动、压缩、上传或修改用户文件，不静默结束进程。
5. **Explicit export:** 诊断数据只有在用户预览并主动确认后才能导出；应用不自动上传。
6. **Graceful permission degradation:** 未授予 Full Disk Access 时显示真实覆盖范围，不声称结果完整。
7. **Network is optional:** Beta 默认无常规出站流量。只有更新机制经 PRD/ADR 明确批准后，才允许加入用户可关闭的签名更新检查；否则生产构建保持零常规出站流量。核心功能始终离线可用。

## 2. Scope and assets

需要保护的资产：

- 用户目录/文件名、路径层级、卷名称和挂载信息；
- 文件/目录大小、变化时间、分类、应用归属与扫描覆盖范围；
- 扫描历史、数据库、设置、security-scoped bookmark；
- 本地日志、crash data 和诊断包；
- 更新签名密钥、Apple Developer ID、CI token、release artifact；
- 产品完整性与用户对“只读、无遥测”的信任。

不在首版范围：云账号、团队共享、远程管理、自动清理、root helper、文件内容搜索。加入这些能力必须重新做 threat model。

## 3. Data classification and handling

| Class | Examples | Rules |
|---|---|---|
| Public | 源码、公开文档、版本号、公开分类规则 | 可进入仓库与普通日志 |
| Internal | 性能基准、非敏感构建信息、fixture seed | 可进入 CI；不得包含真实设备/用户数据 |
| Sensitive | 路径、文件名、目录层级、卷名/UUID、大小时间线、应用痕迹、bookmark | 仅本机、最小化、默认不导出；日志必须 private/redacted |
| Restricted | 文件内容、密码/token、签名私钥、真实用户诊断原件 | 产品不得采集文件内容/凭证；密钥仅在受控 secret store；用户诊断限授权人员和期限 |

未知字段按更高一级处理。任何新持久化字段 **MUST** 在 PR 中声明 class、purpose、retention、export behavior 和 deletion behavior。

## 4. Data minimization and lifecycle

### 4.1 Collection

扫描器仅可读取完成归因所需的 metadata：类型、逻辑/分配大小（系统可用时）、修改时间、父子关系、受控分类信号和权限错误。它 **MUST NOT**：

- 打开普通文件读取内容或计算内容 hash；
- 读取 extended attributes、Finder tags、Spotlight 文本、照片/邮件/浏览器数据库；
- 采集 owner、ACL、quarantine、下载来源等非当前需求字段；
- 为“以后可能有用”保留原始 FSEvents 流；
- 跟随 symlink 离开允许的扫描边界。

如果 OS API 在读取 size 时隐式触发云端下载，SpaceTrace **MUST** 跳过并标为 unavailable；不得为了计算大小下载 iCloud/Files-on-Demand 内容。

### 4.2 Persistence

- 原始逐文件事件只在内存中用于聚合，处理成功后 **MUST** 丢弃；持久化以目录聚合和解释所需的最小节点为主。
- 不需要在历史 UI 呈现的 leaf filename **MUST NOT** 持久化。确需展示的大文件/目录路径必须有产品需求，并沿用 Sensitive 保护。
- 详细 snapshot 默认保留 30 天；到期后只保留解释观测空档所需的最小无路径标记。用户可缩短或关闭历史；任何更长选项和上限须由 PRD 明确，延长默认值需要 RFC。
- SQLite、设置和 bookmark **MUST** 位于应用 container/Application Support，权限仅当前用户可读写；不得写入共享临时目录。
- 数据库不被视为匿名。首版不因引入第三方加密库增加攻击面；依赖 macOS 账户边界与 FileVault，并在文档明确建议。若引入同步或多用户共享，必须重新评估静态加密。

### 4.3 Deletion

用户执行“Clear History”时，应用 **MUST** 在操作前说明范围，在 5 秒内停止相关任务并删除数据库、checkpoint 和派生缓存；删除失败必须明确报告。删除不应触碰用户文件。

应用设置页和卸载文档 **MUST** 列出本地数据位置。保留的迁移备份不得超过一次成功启动或 7 天（取更早），除非用户处于恢复流程。

## 5. Permissions

- SpaceTrace **SHOULD** 在无 Full Disk Access 时先展示可工作的有限模式，再由用户主动选择是否扩大覆盖。
- 权限解释必须说明“读取哪些 metadata、为什么、没有权限时少了什么”；禁止用恐吓性文案或把授权包装为必然安全。
- 应用不得自动反复打开 System Settings。用户一次拒绝后，只有用户点击明确按钮才可再次引导。
- 首版 **MUST NOT** 请求 admin/root、Accessibility、Screen Recording、Automation、Contacts、Photos、Calendar 或 Location。
- security-scoped bookmark 只用于用户明确选择的目录/卷；stale bookmark 必须重新确认，不以更宽路径替代。
- 权限在运行时被撤销时，扫描停止受影响范围，保留已知数据并标记 stale；不得把拒绝当作目录变空。

## 6. Logging and diagnostics

### 6.1 Logging rules

- 统一使用结构化 logger；路径、文件名、卷名、用户名、bookmark、错误 payload 默认标记 private。
- Release 日志 **MUST NOT** 包含绝对路径、目录 basename、环境变量、command line、用户 ID 或 database row dump。
- 需要关联事件时使用每次启动随机 correlation ID；禁止稳定设备 ID。若需在单次扫描中关联路径，使用进程内临时 ID，退出即失效。
- 本地文件日志默认关闭。用户开启诊断模式时最多保留 7 天/10 MB（先达到者先轮换），并在 UI 持续显示状态。
- `print`、未审查的 `dump`、把 `Error.localizedDescription` 直接作为 public 字段均不得进入 Release 路径。

### 6.2 Diagnostic package consent

导出流程 **MUST** 满足：

1. 用户主动点击 Export Diagnostics；
2. 生成前展示将包含/排除的类别；
3. 默认做路径脱敏：home 替换为 `~`，其余 path components/文件名以会话随机 token 替换；默认不包含观察数据库；
4. 若用户选择包含原始路径，必须使用独立、默认关闭的 checkbox，并再次提示可能泄露项目/客户名称；
5. 生成本地 archive 和 human-readable manifest，用户选择保存位置；应用不上传、不复制到剪贴板；
6. archive 生成失败或取消时清除临时文件。

诊断包 **MUST NOT** 包含文件内容、bookmark、密钥、Apple ID、网络凭据、完整环境变量或未脱敏 crash memory。导出代码必须有 golden redaction test。

维护者收到诊断包时视为 Restricted：通过私密渠道接收，最少人员访问，issue 中只发布脱敏摘要；问题关闭后 30 天内删除，除非用户另行同意更长保留。公开 issue 模板必须提醒不要上传原始数据库或路径日志。

## 7. Threat model

### 7.1 Trust boundaries

主要边界：

- 不可信文件系统 metadata -> scanner/classifier；
- privileged OS information/Full Disk Access -> application process；
- application -> local SQLite/log/diagnostic archive；
- application -> 可选的 Sparkle/appcast/update artifact（仅在更新机制获批并落地后存在）；
- source/dependencies/CI -> signed release；
- user action -> destructive local history deletion或敏感导出。

文件名、目录结构、卷、FSEvents、数据库和更新响应都必须按不可信输入处理。

### 7.2 Threats and required controls

| Threat | Example impact | Required controls |
|---|---|---|
| Path traversal / symlink escape | 扫描越过用户选择范围、循环或信息暴露 | descriptor/URL-based canonicalization、禁止跨边界跟随、visited identity、深度/节点上限 |
| Malicious metadata | 超长/控制字符名称使 UI、日志或导出注入 | 长度边界、Unicode 安全渲染、结构化序列化、CSV formula/HTML escaping、fuzz tests |
| TOCTOU | 扫描期间文件被替换导致错误或访问越界 | 接受 metadata stale、错误隔离、不基于路径执行修改、关键读取重新验证 identity |
| Resource exhaustion | 数百万事件导致 CPU/内存/DB 爆炸 | bounded queue、backpressure、coalescing、checkpoint、可取消、磁盘/内存上限、overflow 后受控 rescan |
| SQL/database corruption | 历史损坏、启动循环 | 参数化查询、WAL/integrity checks、原子迁移、保留原件、恶意 fixture |
| Privacy leak via logs/export | 项目/用户名泄露 | private logging、默认 redaction、显式 consent、golden scan、无自动上传 |
| Malicious update/MITM | 任意代码执行 | HTTPS + 更新框架签名（采用 Sparkle 时为 EdDSA）、版本单调、稳定版 Developer ID/hardened runtime/notarization、fail closed |
| Compromised dependency/CI | 注入 release | 最少依赖、exact pins、SBOM、review dependency diff、受保护环境、artifact attestation、双人或高风险例外 |
| Local unprivileged user | 读取另一账户历史 | per-user container/0600、禁止共享 tmp、临时文件原子创建和及时删除 |
| Misleading attribution | 用户误删重要数据 | confidence/evidence、unknown 优先、禁止“safe to delete”无依据、默认无删除能力 |

### 7.3 Out of scope assumptions

首版不保证防御已完全控制当前 macOS 用户账号、root、内核或已解锁磁盘的攻击者。即使如此，应用不得扩大攻击者能力，例如把敏感数据库复制到 world-readable 位置或泄露签名密钥。

## 8. Secure coding requirements

- 所有 SQLite 查询参数化；数据库 schema、decoder 和 migration 对异常长度/类型 fail safely。
- 扫描器必须限制并发、队列、递归深度和单批事务；禁止递归调用依赖目录深度。
- Swift 并发边界显式；新增 `unsafe`、`@unchecked Sendable` 或 C pointer 必须安全 review 和专门测试。
- 临时文件使用系统安全 API 创建，权限仅当前用户；成功、失败、取消后均清理。
- 外部进程默认禁止。确需调用系统工具时，必须使用固定 executable URL、参数数组、清理环境、超时和输出上限；禁止 shell 拼接。
- UI、HTML/CSV/JSON 导出对不可信名称做上下文相关 escaping；CSV 单元格以 `= + - @` 开头时必须中和公式执行。
- 错误信息区分用户可见摘要与 private debug context；不得把底层路径直接透传到公共日志。

## 9. Dependencies and supply chain

### 9.1 Admission

新增运行时依赖需要 RFC，必须说明：不用平台 API/自有实现的原因、维护活跃度、license、transitive dependencies、网络/脚本行为、binary artifact 和退出方案。

- SwiftPM 依赖 **MUST** 精确锁定并提交 `Package.resolved`；禁止未固定 branch dependency。
- 默认只接受 OSI-approved permissive licenses。GPL/AGPL、source-available、自定义 license 或闭源 binary 需要 maintainer/legal 明确批准并记录兼容性。
- binary dependency 必须验证发布者签名和 checksum；能从源码构建时 SHOULD 不接收预编译二进制。
- package plugin/build script 视为构建时代码执行，变更必须人工审查。

### 9.2 Continuous controls

- 每周自动依赖检查；每个 dependency PR 必须展示 lockfile/transitive diff、release notes、license 和测试结果。
- 每个 release 生成 CycloneDX 或 SPDX SBOM、SHA-256 和可验证构建 provenance/attestation。
- GitHub Actions 固定到完整 commit SHA；第三方 action 最小权限，pull request from fork 不得接触 release secrets。
- CI `GITHUB_TOKEN` 默认 read-only；签名、公证、发布使用受保护 environment 和手动批准。
- release signing key、notary credential 和更新框架私钥必须分离；采用 Sparkle 时 EdDSA 私钥同样独立。轮换/吊销流程每年至少演练一次。

漏洞响应 SLA 从确认可利用性开始：Critical 24 小时内给出缓解/暂停发布并在 7 天内修复；High 3 天内缓解、14 天内修复；Medium 90 天；Low 进入正常 backlog。无法达标必须记录风险接受、补偿控制和到期日。

## 10. Vulnerability reporting and incident response

安全问题 **MUST NOT** 先公开提交普通 issue。仓库启用 GitHub Private Vulnerability Reporting/Security Advisory，并在 `SECURITY.md` 公布支持版本和入口。

维护者响应目标：

- 2 个工作日内确认收到；
- 5 个工作日内完成初始严重性和复现判断；
- 与报告者协调修复、CVE（适用时）和披露日期；
- 发布安全修复时更新 `CHANGELOG` Security、签名版本和 advisory；
- 不要求报告者提供无关个人信息或公开 PoC。

疑似泄露/恶意更新/P0 数据风险发生时：暂停 appcast/release、保存最小必要证据、轮换相关凭据、从可信 commit 重建、验证签名链并通知受影响用户。事件后 5 个工作日内完成无责复盘并形成可验证 action items。

## 11. Security verification gates

以下在相关 PR 或 release 中为阻塞项：

- path/Unicode/symlink/event-flood fuzz 或 property tests；
- permission denied/revoked tests；
- SQL migration corruption/interrupt tests；
- logging/diagnostic golden redaction tests；
- secret scan、SCA、license review、SBOM；
- hardened runtime entitlement diff；新增 entitlement 必须 RFC；
- 稳定版 Developer ID、notarization、staple，以及所选更新机制的签名/无效签名 failure test；采用 Sparkle 时验证 EdDSA；
- clean machine 网络抓取检查：关闭更新后不得有非用户触发出站流量。

已知 Critical/High 漏洞、诊断包默认泄露路径、无效更新签名仍可安装、或扫描会修改用户数据时，任何人不得通过例外批准稳定发布。

## 12. Review cadence

本威胁模型在以下时间 **MUST** 更新：新增权限/网络/导出字段/依赖/文件操作时；每个 minor release 前；任何安全或隐私事件后；至少每 6 个月一次。评审结果必须链接 issue、负责人和截止日期。
