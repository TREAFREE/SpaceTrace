# Contributing to SpaceTrace

感谢你帮助 SpaceTrace 更准确、更节能、更值得信任。SpaceTrace 会观察用户的磁盘元数据，因此一个看似普通的路径、日志或权限改动也可能产生隐私影响。请先阅读本指南，以及：

- [Development Process](docs/engineering/development-process.md)
- [Quality Strategy](docs/engineering/quality-strategy.md)
- [Privacy and Security Baseline](docs/security/privacy-and-security.md)

本文中的 **MUST**、**SHOULD**、**MAY** 表示强制、默认应遵循、可选。

## Before you start

- Bug：先搜索现有 issue，再使用 bug template，提供最小复现。不要上传未脱敏路径、数据库或诊断包。
- Feature：先描述用户问题和期望结果，不要只提交实现方案。超过 5 个工作日、引入权限/依赖/数据字段或改变核心架构的工作，必须先完成 RFC。
- Security/privacy issue：不要公开 issue；使用仓库 GitHub Security 页的 private vulnerability reporting。
- 小型文档/拼写修复可直接 PR；其余变更应先有关联 issue。

维护者确认方向前，请不要投入大型实现。标记为 `help wanted` / `good first issue` 的 issue 已具备基本边界，但 acceptance criteria 仍是最终依据。

## Development setup

要求：

- 与仓库/CI 指定版本一致的稳定版 Xcode；
- macOS 15.6 或更高版本；首发支持 Apple Silicon，Intel 暂不属于正式支持范围；
- SwiftFormat 与 SwiftLint 的版本必须由仓库工具配置锁定，不能依赖本机任意版本。

Clone 后先确认 scheme：

```bash
xcodebuild -list -project SpaceTrace.xcodeproj
```

仓库的完整本地验证入口：

```bash
make verify
```

该命令与 CI 共用同一入口，依次执行仓库卫生和架构边界检查、`SpaceTraceKit` 测试、package 完整并发诊断与 warning-as-error 审计、scheme 发现、Debug 构建、应用单元测试和 Release 构建。也可用 `make package-concurrency-audit` 单独执行并发门槛。签名、公证和未来的更新发布测试只在受保护 CI environment 中运行；普通贡献者不需要发布凭据。

目录授权 UI 成为有意义的用户旅程后，交互式 Mac 会话还需运行：

```bash
make app-test-ui
```

该命令使用 Xcode 的本机 “Sign to Run Locally” 配置；在当前 Xcode 26.1.1、macOS 26.5.2 主机上，即使钥匙串没有 Apple 开发签名身份，ad-hoc 签名的 UI test runner 与沙盒 App 也可完成受控 DEBUG fixture。该结果只验证确定性的界面状态、操作名称与可访问性树，不替代真实 Powerbox/bookmark/重启流程，也不替代 Apple 身份签名、Developer ID 分发或 macOS 15.6 运行门禁。若 runner 无法初始化，应把主机、Xcode、签名与 Developer Mode 状态记为环境证据，不能把 `build-for-testing` 当作通过。完整的真实权限矩阵见[用户选择目录 UI 与沙盒资格验证](docs/engineering/user-selected-directory-qualification.zh-CN.md)。

## Branches and commits

从最新 `main` 创建短分支：

```text
feat/42-growth-timeline
fix/108-permission-stale-state
docs/57-threat-model
```

- 分支 SHOULD 在 2 个工作日内合并；Draft PR 越早越好。
- PR SHOULD <= 400 行非生成代码或 <= 15 个文件；超出时解释拆分困难并提供 review map。
- commit/PR title 使用 Conventional Commits，例如 `feat(timeline): explain daily storage growth`。
- 不提交 `.xcuserdatad`、DerivedData、签名证书、真实扫描数据库、原始诊断包或本机绝对路径。
- 不格式化与当前工作无关的文件；自动生成变更与手写逻辑应分开提交或清楚标注。

## Coding expectations

- 用户文件访问默认只读；不得新增删除、移动、内容读取、shell 拼接或静默 kill 行为。
- 时间、文件系统、卷、权限和调度器边界应可注入，测试不得扫描真实 `$HOME` 或 `/`。
- 不可访问目录必须表示为 unknown/permission denied，不能计作 0 bytes。
- 新增日志中的路径、文件名、卷名和错误 payload 必须 private/redacted。
- 关键路径不得新增 force unwrap、`try!`、未说明的 `fatalError` 或无界 task/event queue。
- 新增依赖、entitlement、网络访问、权限、持久化字段、schema 迁移必须在 PR 明示；其中高风险项需 RFC/ADR。
- UI 要支持 VoiceOver label、键盘导航，并且不能只用颜色表达错误或置信度。

## Tests

生产逻辑与回归测试必须在同一 PR。按改动选择并提供证据：

- 单元测试：路径、大小、分类、diff、retention、redaction、错误和取消；
- 集成测试：临时目录、事件 overflow、symlink、权限、sleep/wake、数据库故障；
- 升级测试：schema 变化必须覆盖 N-1/N-2 golden databases 和中断迁移；
- 性能测试：扫描、事件批处理、内存、数据库增长；超过预算不得以本机很快为由忽略；
- UI/可访问性：关键旅程 smoke test，必要时附截图/短视频；
- 权限降级：拒绝、撤销、恢复时不 crash、不反复提示、不伪造完整性。

最低 coverage 与性能门槛见 [Quality Strategy](docs/engineering/quality-strategy.md)。Fixture 必须是合成/公开数据；golden 更新必须附 human-readable diff，禁止提交真实用户名和目录。

## Pull request process

1. 将 PR 标为 Draft，关联 issue，并完整填写模板。
2. 自审整个 diff，包括生成物、日志、entitlement、依赖和失败路径。
3. 确保 required checks 在最新 commit 全绿；不要用无说明 retry 掩盖 flaky test。
4. 回应每条 blocking comment，说明如何解决；如果不同意，请提供契约、测试或数据依据。
5. Maintainer squash merge。合并不保证立即发布。

风险级别：

- Low：文档、测试、隔离文案；
- Medium：用户行为、扫描/分类规则、非破坏 schema；
- High：权限、更新、签名、迁移、删除、诊断导出、供应链。

High-risk 改动原则上需要独立 reviewer；单维护者例外有 48 小时冷却、两次 clean CI、7 天 beta soak 等补偿控制，详见开发流程。更新验签绕过、任意文件删除和已知数据损坏风险不得例外。

## Documentation and release notes

用户可见行为必须更新对应文档和 `CHANGELOG.md` 的 `Unreleased`。以下改动还需：

- 难以逆转的架构决定：ADR；
- 新权限/依赖/网络/数据保留或大范围改动：RFC；
- 数据采集、日志或导出变化：隐私威胁模型；
- schema 变化：迁移说明、fixture、回滚/前向修复策略；
- 性能预算变化：基准数据与获批 RFC。

## Reporting sensitive test evidence

请优先使用合成目录复现。如果必须引用真实环境：

- 将 home 替换为 `~`，其余名称改为随机占位符；
- 不截图 Finder 侧边栏、Apple ID、客户/项目名称；
- 不公开上传 `.sqlite`、`.xcresult`、crash memory 或完整 Console log；
- 通过 maintainer 指定的私密渠道提交诊断包，并说明删除期限。

提交贡献即表示你有权提交相关内容并同意按仓库许可证分发；如果许可证尚未建立，请先等待 maintainer 完成许可基线，不要引入第三方代码片段。
