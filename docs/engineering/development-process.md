# SpaceTrace Development Process

Status: **Baseline**

Owners: Maintainers

Last reviewed: 2026-07-18

本文件定义 SpaceTrace 从问题发现到发布的最小、可审计工程流程。关键词 **MUST**、**SHOULD**、**MAY** 分别表示强制、默认应遵循、可选。流程服务于一个小型开源团队：降低错误和隐私风险，但不以会议或文档数量衡量质量。

## 1. Working model

SpaceTrace 采用 trunk-based development：

- `main` **MUST** 始终可构建、可测试、可发布，并启用分支保护；禁止直接 push 和 force-push。
- 普通工作分支 **SHOULD** 在 2 个工作日内合并，命名为 `<type>/<issue>-<slug>`，例如 `feat/42-growth-timeline`。
- PR **SHOULD** 不超过 400 行非生成代码变更或 15 个文件；生成文件、快照和依赖锁文件单独统计。超过任一门槛时，作者 **MUST** 在 PR 中解释不可拆分原因并提供 review map。
- 功能必须通过 feature flag、接口替身或不可达 UI 保持 `main` 可发布；禁止长期功能分支。
- 大型迁移可使用 `integration/<topic>` 分支，但 **MUST** 有获批 RFC、明确 owner、每日同步 `main`，且存活不超过 10 个工作日。

提交信息采用 Conventional Commits：`feat`、`fix`、`perf`、`refactor`、`test`、`docs`、`build`、`ci`、`chore`。破坏性变更 **MUST** 使用 `!` 或 `BREAKING CHANGE:`，即使当前版本低于 1.0。

## 2. Work item lifecycle

默认流程是：

`Issue -> Ready -> Design -> Implementation -> Review -> Merge -> Release -> Observe`

### 2.1 Issue and triage

任何超过 30 分钟的用户可见改动、数据模型变更或行为修复 **MUST** 先有关联 issue。拼写、注释和纯机械维护可直接提交 PR。

Maintainer 至少每周一次完成 triage，并标注：

- 类型：`bug`、`feature`、`performance`、`security`、`maintenance`；
- 优先级：P0 数据丢失/安全事件，P1 核心功能不可用，P2 显著体验问题，P3 一般改进；
- 风险：Low、Medium、High，按第 5 节判断；
- 状态：`needs-info`、`ready`、`blocked` 或 `declined`；
- owner 与目标 milestone（若已承诺）。

P0 **MUST** 立即停止常规发布并进入私密安全或 hotfix 流程；P1 应在 1 个工作日内完成首次判断。普通社区 issue 的首次回应目标是 5 个工作日，不是发布承诺。

### 2.2 Definition of Ready (DoR)

进入实现前，issue **MUST** 至少具备：

- 一句话问题陈述、目标用户与可观察影响；
- 可验证的 acceptance criteria，包括失败和权限拒绝场景；
- non-goals，防止功能无边界扩张；
- 风险等级及对隐私、权限、数据保留、性能的初步判断；
- 测试方案或明确说明为何只需文档测试；
- 外部依赖、阻塞项和发布/回滚方式。

对于可稳定复现的 P0/P1 修复，允许先实现后补齐 DoR；PR **MUST** 记录跳过原因，并在合并后 2 个工作日内补齐根因和回归测试。

### 2.3 Design

满足 DoR 后，按第 3 节判断是否需要 RFC 或 ADR。设计评审关注边界、失败模式和证据，不要求为低风险小改动制作独立文档。

### 2.4 Implementation

- 作者 **MUST** 先写或更新能够失败的测试，再完成关键路径实现；探索性 spike 可例外，但 spike 代码不可直接进入产品路径。
- 新增用户可见行为 **MUST** 同步更新 PRD/帮助文档、可访问性文案和本地化 key。
- 新增数据采集、网络访问、权限或持久化字段 **MUST** 更新隐私威胁模型。
- 数据库 schema 变更 **MUST** 提供前向迁移、N-1/N-2 fixture 和失败回滚行为；禁止在启动时执行不可恢复删除。

### 2.5 Review and merge

所有 PR **MUST**：

1. 关联 issue 或说明为何无需 issue；
2. 完整填写 PR 模板；
3. 通过第 6 节 required checks；
4. 解决全部 blocking comment；
5. 使用 squash merge，保持 `main` 单一意图提交；安全修复可用 maintainer merge 以保留必要提交结构。

作者不得批准自己的 PR。常规情况下需要 1 名 code owner 批准；High-risk 改动按第 5.3 节执行。

### 2.6 Release and observe

合并只表示代码进入 `main`，不表示已经向稳定用户开放。用户可见功能 **MUST** 有发布说明和可观察的成功/失败信号。由于项目默认无遥测，观察证据来自本地结构化日志、预发布手测清单、用户主动反馈和显式导出的诊断包。

## 3. RFC and ADR rules

### 3.1 RFC is required when

出现任一条件，实施前 **MUST** 提交 RFC：

- 新增系统权限、后台常驻能力、launch agent、helper 或网络端点；
- 改变隐私承诺、默认数据保留期或诊断导出内容；
- 修改核心扫描/归因模型、持久化 schema 或公开数据格式；
- 引入运行时代码依赖、自动更新框架或新的发布渠道；
- 预计改变空闲 CPU/内存预算超过 10%，或初始扫描耗时超过 15%；
- 用户数据可能被删除、迁移、覆盖或发送出设备；
- 预计实现超过 5 个工作日或涉及 3 个以上模块。

RFC **MUST** 包含 context、goals/non-goals、方案、至少一个备选、数据流、权限/隐私、失败模式、测试、迁移、回滚和 unresolved questions。公开讨论期 **SHOULD** 至少 3 个工作日；P0 可缩短，但必须记录时限原因。

### 3.2 ADR is required when

ADR 记录已经作出的、未来难以逆转或会约束多个模块的技术决定，例如数据库、模块边界、扫描调度、更新渠道和最低 macOS 版本。纯 UI 细节、局部重构和轻易可逆的依赖配置不需要 ADR。

- ADR 状态为 Proposed、Accepted、Superseded 或 Rejected。
- Accepted ADR **MUST** 链接对应 RFC/issue/PR，并说明 consequences。
- 改变决定时不得重写历史；新增 ADR 并标记 supersedes。
- 若 RFC 已完整包含决定，仍需一页短 ADR 作为稳定索引。

## 4. Definition of Done (DoD)

工作只有同时满足以下条件才可标记 Done：

- acceptance criteria 全部有可复现证据；
- 新增/修改逻辑通过相应单元、集成、权限降级、升级或性能测试；
- 没有新增编译 warning、SwiftLint warning 或未解释的 flaky test；
- 数据与权限行为符合隐私安全基线，日志经过敏感信息检查；
- 用户文档、变更日志分类、ADR/RFC 和本地化按需更新；
- 可访问性：核心操作有 label、键盘路径，颜色不是唯一状态载体；
- 提供 rollout 与 rollback 说明；数据库迁移验证了失败时不破坏原数据；
- PR 已获所需批准，required checks 全绿，review comment 已解决；
- 合并后 issue 记录发布版本或明确 `unreleased`。

## 5. Change risk and review policy

### 5.1 Risk levels

| Level | Examples | Minimum review |
|---|---|---|
| Low | 文档、测试、无行为格式化、隔离 UI 文案 | 1 maintainer 或单维护者自审流程 |
| Medium | 新 UI、分类规则、扫描范围调整、非破坏 schema 增量 | 1 独立 reviewer；无 reviewer 时执行单维护者替代流程 |
| High | 权限、自动更新、签名、公证、迁移、删除、诊断导出、沙箱边界、供应链 | 2 人原则；例外见 5.3 |

风险由作者先标，reviewer 可提高但不得无说明降低。

### 5.2 Review expectations

- 首次 review 目标：工作日内 2 天；P1 目标 4 小时。
- review 先验证正确性、数据安全、权限、并发、资源使用和测试，再讨论风格。
- blocking comment **MUST** 指向具体风险或违反的契约；偏好建议标记 `non-blocking`。
- 作者更新后 **MUST** 回复解决方式；不得只 resolve 而不回应行为变化。

### 5.3 Single-maintainer substitute for two-person review

开源项目可能暂时没有第二位 maintainer。此时不得把“自己点 Approve”当作审查。

Low/Medium risk 可采用以下替代流程，且 **MUST** 全部满足：

1. PR 保持 Draft，作者完成模板化 self-review；
2. 最后一次功能修改后冷却至少 12 小时；
3. 从测试或 acceptance criteria 重新走读，不只看 diff；
4. required CI 在最新 commit 上从干净环境完整运行；
5. PR 中记录风险、失败注入证据和回滚方式。

High-risk 改动原则上 **MUST** 有独立人工 reviewer。确实无法获得 reviewer 时，只允许 maintainer 记录 exception，并同时满足：

- 冷却至少 48 小时；
- 两次独立 clean CI run，且 release candidate 手测清单完成；
- beta 渠道 soak 至少 7 天；迁移和更新改动还需从上一稳定版完成升级与回退演练；
- 稳定发布采用手动批准，不进入自动 rollout；
- exception 说明风险接受人、有效期和后续补审 issue。

涉及远程代码执行、更新签名验证绕过、任意文件删除或已知数据损坏风险的改动 **不得** 使用单维护者例外。

## 6. CI quality gates

每个 PR 的 required checks **MUST** 包括：

- repository hygiene：无 secret、禁止文件、未更新生成物；
- SwiftFormat check 和 SwiftLint `--strict`；
- Debug 与 Release 构建，warning 视为错误；
- unit tests 与 changed-code coverage gate；
- integration tests，包括权限拒绝和可取消性；
- 数据库迁移/fixture 校验（涉及 schema 时）；
- 依赖锁定、许可与漏洞扫描；
- 文档链接/Markdown lint（修改 docs 时）。

性能、1M 节点大 fixture、升级矩阵和签名/公证 smoke test 可在 nightly/release workflow 运行，但发布前 **MUST** 成功。具体阈值见 [Quality Strategy](./quality-strategy.md)。

任何 required check 的绕过都必须由 maintainer 在 PR 写明：失败检查、影响范围、临时缓解、owner 和不超过 7 天的修复期限。安全、迁移数据完整性、更新签名检查不可绕过。

## 7. Release process

### 7.1 Versioning and changelog

- 使用 Semantic Versioning。`1.0.0` 前，破坏性变更提升 minor（`0.4 -> 0.5`），向后兼容功能提升 minor，修复提升 patch。
- `CHANGELOG.md` **MUST** 遵循 Keep a Changelog，维护 `Unreleased`，至少分类 Added、Changed、Fixed、Security、Deprecated/Removed。
- release tag 必须为 `vX.Y.Z` 并签名；tag 必须指向通过 release workflow 的 `main` commit。

### 7.2 Branching and release candidate

通常直接从 `main` 创建 tag。仅当需要稳定候选而 `main` 继续开发时，才 MAY 创建 `release/vX.Y`：

- 存活不超过 3 个工作日；
- 只接受 release blocker、版本、文档和签名配置；
- 所有修复先进入 `main`，再 cherry-pick；禁止只留在 release branch。

每个稳定版 **MUST** 先产出 RC，完成：从上一稳定版升级、全新安装、权限拒绝/恢复、数据库迁移、卸载数据说明、所选更新机制和离线启动测试；若采用 Sparkle，必须覆盖 appcast 与无效 EdDSA 签名。High-risk 版本 beta soak 不少于 7 天；普通版本不少于 48 小时。

### 7.3 Signing, notarization, and updates

- 所有 stable `.app`/DMG **MUST** 使用 Developer ID 签名、hardened runtime、公证并 staple ticket。Developer ID 决策完成前，公开 Beta MAY 以未签名形式发布，但必须显著披露 Gatekeeper 风险、提供 SHA-256/commit provenance、禁用自动更新，并由 maintainer 手动批准；不得称为 stable。
- 更新机制目前是产品决策项。若采用 Sparkle，appcast **MUST** 通过 HTTPS 分发并使用 Sparkle EdDSA 签名；私钥只能存在受保护的 CI secret store，不能进入仓库、日志或构建产物。
- 稳定更新 **MUST** 通过 staging 验证，支持停止 rollout；不得在签名、哈希、版本单调性校验失败时安装。
- 发布产物 **MUST** 附带 SHA-256、SBOM、源码 commit 与构建环境标识；发布后从干净 Mac 验证下载、签名、公证与启动。

### 7.4 Hotfix and rollback

P0/P1 hotfix 从最后稳定 tag 创建短分支，最小化改动并添加回归测试。若无法安全修复，应先暂停 appcast rollout或撤回版本。数据库 schema 迁移原则上前向修复；回滚应用不得自动打开不兼容数据库，必须保留原文件并给出明确恢复路径。

## 8. Exceptions and process changes

流程例外不是口头决定。申请人 **MUST** 在 issue/PR 记录：被豁免规则、原因、风险、补偿控制、批准者、截止日期。过期例外自动失效。

此流程每季度或发生 P0/安全事件后复盘。调整量化门槛需要 PR；涉及隐私、安全或发布信任链的调整需要 ADR。
