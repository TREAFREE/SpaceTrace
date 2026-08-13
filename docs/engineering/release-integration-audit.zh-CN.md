# 发布集成审计

状态：**本地 DMG 候选物已验证；GitHub 发布集成尚未完成**

最后更新：2026-08-14

英文事实源：[release-integration-audit.md](release-integration-audit.md)。本文是对应的中文伴随翻译。

## 目的与边界

本审计严格区分三个不能混为一谈的状态：

1. 满足打包契约的本地构建产物；
2. 已接入受保护仓库与 CI 流程的候选版本；
3. 满足产品、平台、隐私和分发门槛的公开 GitHub Release。

当前保留的 `0.1.0-rc.7` DMG 只处于第一种状态，它不是公开发布授权。本文记录的是有日期的仓库和 GitHub 状态快照；正式作出发布决定前，所有动态检查都必须重新执行。

## 证据快照

以下证据于 2026-08-14 重新采集：

| 范围 | 观测状态 | 对发布的含义 |
|---|---|---|
| 仓库 | `TREAFREE/SpaceTrace` 是公开仓库，默认分支为 `main` | 公开可见本身不等于批准二进制发布 |
| 候选分支 | `agent/native-fsevents-integration` 相对 `origin/main` 落后 0 个提交、领先 85 个提交 | 候选实现尚未集成进发布分支 |
| Pull Request | 候选分支到 `main` 没有 PR | 不存在审查、required checks 和合并证据 |
| GitHub Actions | 候选分支没有工作流运行记录 | CI 只对 PR 和推送到 `main` 触发；本地 `make verify` 不能替代 GitHub 托管证据 |
| 分支保护 | GitHub 报告 `main` 未受保护 | 这与开发流程中禁止直接推送和强制推送的要求冲突 |
| 项目许可证 | GitHub 未识别到许可证，仓库内也没有 `LICENSE`/`COPYING` 文件 | PRD 中的 MIT 仍只是未获所有者批准的假设 |
| 分发身份 | 当前没有 Developer ID Application 身份；候选物使用 ad-hoc 签名且未公证 | 它最多只能成为明确接受风险的预发布 Beta，不能称为稳定版或 Apple 已验证版本 |
| 本地产物 | `0.1.0-rc.7` 已通过校验和、manifest、SPDX、精确 entitlement、Hardened Runtime、arm64、macOS 15.6 部署目标、严格代码签名和 DMG 检查 | 字节和已披露的信任边界可审计，但运行时与支持门槛仍未关闭 |

保留的 rc.7 manifest 将产物字节绑定到源码提交 `a3b8b45ca6f9dad752a9b750422b343d71c04dc8`。后续文档提交不会让该产物失效，但最终供下载的 DMG 必须从被选为发布源的精确 `main` 提交重新构建。Tag 或 Release 不得复用 rc.7 却声称它来自另一个源码提交。

## 必须遵循的集成顺序

发布流程必须保持 fail-closed：

1. **所有者决策**
   - 批准一个明确的项目许可证，并加入一致的仓库元数据；
   - 选择 Developer ID 签名/公证，或明确记录 maintainer 对 ad-hoc、未公证 Public Beta 的风险接受，并保持无自动更新；
   - 审查仍处于 Proposed 状态且与发布相关的 ADR，并记录接受或延期边界。
2. **Pull Request 与 CI**
   - 从 `agent/native-fsevents-integration` 向 `main` 创建 PR；
   - 在完整 Git 历史 checkout 上执行 GitHub `Verify` 工作流；
   - 修复失败时不得绕过隐私、迁移完整性、签名或更新检查；
   - 完成开发流程规定的独立审查，或高风险单维护者替代流程。
3. **受保护集成**
   - 在把 `main` 当作发布源之前启用分支保护；
   - 将仓库验证设为 required check，并禁止强制推送和直接发布变更；
   - 通过已审查的路径合并，并确认最终 `main` 提交。
4. **从发布源重新构建**
   - checkout 准备打 Tag 的精确、干净 `main` 提交；
   - 重新运行 `make verify` 以及仅在发布阶段执行的人工/真实设备资格验证；
   - 构建新的版本化 DMG，不得只是重命名或重新发布 rc.7；
   - 独立验证校验和、manifest 源提交、SBOM、notices、签名事实、部署目标、架构、挂载内容和 Gatekeeper/公证状态。
5. **运行时与人工资格验证**
   - 在 Apple Silicon 的 macOS 15.6 和当时最新稳定 macOS 上都通过 P0 矩阵；
   - 如果 Beta 继续使用 ad-hoc 签名，在全新账户中完成带 quarantine 的首次启动和精确的单 App 信任流程；
   - 完成全新安装、同版本覆盖、独立构建替换、bookmark 恢复、拒绝授权、撤权、stale 授权、外置卷返回、同名不同 UUID、睡眠/唤醒、事件缺口、迁移/恢复、retention 和清除历史测试；
   - 完成键盘、VoiceOver、Reduce Motion、Increase Contrast、可用性、诊断脱敏和离线/无未请求网络访问审查；
   - 记录 PRD KPI 证据，包括至少 6 次形成性测试且没有重复阻断问题。
6. **发布决策与公开发布**
   - 确认没有未关闭的 Sev-0/Sev-1，并审查全部已接受例外；
   - 创建指向已通过 release workflow 的合格 `main` 提交的签名 `vX.Y.Z` Tag；
   - 同时发布 DMG、manifest、校验和文件、SPDX、第三方 notices、源码/Tag 链接、精确支持矩阵、安装说明以及签名/公证披露；
   - 把已发布资产重新下载到干净目录，再次执行校验和、挂载内容和安装验证，之后才能宣布可用。

## 当前未关闭门槛

| 门槛 | 当前证据 | 关闭条件 |
|---|---|---|
| 许可证 | `licenseInfo = null`；无许可证文件；SPDX 使用 `NOASSERTION` | 所有者选择并批准许可证，统一更新仓库元数据、notices 和 SPDX |
| 仓库集成 | 功能分支领先 85 个提交；无 PR 或 GitHub Actions 运行 | 经过审查的 PR、托管 CI 全绿、受保护的 `main`、明确合并提交 |
| 最低系统 | 部署目标为 15.6；当前构建主机版本更高 | 在物理机或虚拟机完成 macOS 15.6 P0 运行时矩阵 |
| 当前稳定系统 | 已有当前主机自动化与签名沙盒证据 | 在届时最新稳定 macOS 上对发布源产物重复验证矩阵 |
| Gatekeeper | 已证明 ad-hoc rc.7 会被预期拒绝 | 在全新账户中完成带 quarantine DMG 的 **Open Anyway** 流程和信任后启动 |
| 替换 | rc.6/rc.7 在临时身份下的进程替换已通过 | 在独立构建的发布源候选物之间验证打包后的 bookmark 与数据库连续性 |
| 权限与卷 | 已有确定性/原生 fixture 和更早的签名沙盒 smoke | 完成拒绝、撤权、stale 授权和卷身份变化的真实打包 UI 矩阵 |
| 无障碍与可用性 | 已有自动化 UI 覆盖 | 人工 VoiceOver/键盘/视觉无障碍审查，以及至少 6 次形成性测试 |
| 治理 | ADR-003、ADR-004、ADR-006、ADR-008、ADR-009 仍为 Proposed | maintainer 审查并明确发布处置 |
| 分发政策 | 已实现 ad-hoc 警告和校验和 | Developer ID/公证，或对明确标记的 Public Beta 记录 maintainer 风险接受 |

## 禁止的捷径

- 不得从功能分支或未经验证的本地提交直接创建 Tag。
- 合并后不得发布 rc.7，却把它描述为由合并结果构建。
- 不得把 ad-hoc/未公证构建称为稳定版、Apple 已验证或无障碍安装版本。
- 不得仅因为 PRD 把 MIT 列为假设，就自行加入 MIT 或其他许可证。
- 不得全局关闭 Gatekeeper、递归移除 quarantine，或自动替用户作出信任决定。
- 不得把部署目标元数据或较新系统上的测试解释为 macOS 15.6 运行时资格。
- 不得为了让状态看起来全绿而削弱隐私、损坏恢复或发布检查。

## 需要 maintainer 记录的决策

开始下一项会产生发布状态的操作前，maintainer 必须记录：

1. 获批的项目许可证；
2. 是否授权创建集成 PR，以及采用哪种 reviewer/例外流程；
3. 下一个公开产物是等待 Developer ID/公证，还是以明确接受风险的 ad-hoc Public Beta 继续；
4. 哪些物理机或虚拟机负责提供 macOS 15.6 与全新账户证据；
5. 谁负责最终的人工无障碍、可用性和发布后验证。

在这些决策与外部资格验证完成之前，即使已经存在可审计的本地 DMG，正确的发布结论仍是 **NO-GO**。
