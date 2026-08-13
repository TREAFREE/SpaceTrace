# 发布资格门禁

状态：**fail-closed 的 ad-hoc Public Beta 门禁已实现；当前发布仍为 NO-GO**

最后更新：2026-08-14

英文事实源：[release-readiness-gate.md](release-readiness-gate.md)。本文是对应的中文伴随翻译。

## 目的与信任边界

发布资格门禁用于防止把“本地有效的 DMG”误当成“已具备公开发布资格”。它完全只读：绝不会创建 Tag、PR、GitHub Release、分支规则、许可证或系统信任例外。版本 1 只支持 maintainer 已批准的 `adhoc-public-beta` 分发路径。未来 Developer ID/已公证版本必须使用单独评审过的 Schema，并验证公证与票据附加；不能通过本契约直接宣称。

门禁验证两类事实：

1. 精确候选文件仍符合 manifest、checksum、源码提交、签名事实、沙盒契约、架构、部署目标、SPDX 许可证和只读 DMG 内容；
2. 每一项外部/人工发布门槛都有不含路径的通过证据摘要，并存在明确的最终 GO 决策。

摘要只是绑定引用，不能证明被引用的人工审查真的正确完成。maintainer 在写入 `passed:<sha256>` 前必须阅读每份证据报告。验证器会拒绝缺失、畸形、失败或未绑定的声明，但不能把虚构的人工结论变成事实。

## 命令

只能在干净的 `main` 工作树运行；其 `HEAD` 必须同时精确等于已获取的 `origin/main` 和候选 manifest 中的 `sourceCommit`：

```bash
make verify-release-readiness \
  QUALIFICATION=/绝对路径/release-qualification-v1.json \
  ARTIFACTS=/绝对路径/SpaceTrace-0.1.0-beta.1
```

退出行为是稳定契约：

| 退出码 | 含义 |
|---:|---|
| `0` | `release readiness: GO`；机器可验证契约完整 |
| `1` | `release readiness: NO-GO (<category>)`；至少一项发布不变量缺失或矛盾 |
| `64` | 命令用法无效 |

输出只包含类型化类别，绝不会输出输入路径或证据内容。

## Qualification v1 契约

输入必须是不超过 64 KiB 的普通、非符号链接 JSON 文件。它是一个扁平对象，且只能精确包含以下字段；未知、缺失、重复或类型错误字段一律 fail closed。

| 字段 | 必需值 |
|---|---|
| `schemaVersion` | 整数 `1` |
| `releaseVersion` | 精确 Semantic Versioning 字符串，并与产物文件名版本一致 |
| `sourceCommit` | 40 字符小写 Git SHA，且与 manifest、本地 `HEAD`、`origin/main` 都一致 |
| `manifestSha256` | 候选 manifest 的 SHA-256 |
| `checksumSha256` | 四项 checksum 文件的 SHA-256 |
| `licenseIdentifier` | 获批 SPDX identifier 或经过审查的 `LicenseRef-*`；不能是 `NOASSERTION`/`NONE`，并且必须与 SPDX package declaration 精确相等 |
| `distributionMode` | v1 中只能是 `adhoc-public-beta` |
| `distributionRiskAccepted` | 布尔值 `true`，记录 maintainer 在 2026-08-14 作出的决策 |
| `artifactVerification` | `passed:<sha256>` |
| `repositoryIntegration` | `passed:<sha256>` |
| `minimumOSQualification` | macOS 15.6 P0 矩阵的 `passed:<sha256>` |
| `currentOSQualification` | 当前稳定 macOS P0 矩阵的 `passed:<sha256>` |
| `cleanAccountGatekeeper` | 带 quarantine DMG、单 App **仍要打开**和信任后启动的 `passed:<sha256>` |
| `replacementContinuity` | 独立构建替换、bookmark 与数据库连续性的 `passed:<sha256>` |
| `permissionsAndVolumes` | 拒绝、撤权、stale grant、卷缺席/返回/替换与重新授权的 `passed:<sha256>` |
| `accessibilityReview` | 键盘、VoiceOver、Reduce Motion、Increase Contrast 和文字审查的 `passed:<sha256>` |
| `usabilityResearch` | PRD 形成性测试/KPI 记录的 `passed:<sha256>` |
| `privacyOfflineReview` | 诊断、脱敏、无破坏操作和无未请求网络访问的 `passed:<sha256>` |
| `governanceDisposition` | 发布相关 ADR 与例外审查的 `passed:<sha256>` |
| `severityReview` | 证明决策时没有未关闭 Sev-0/Sev-1 的 `passed:<sha256>` |
| `finalReleaseDecision` | 绑定 maintainer 明确发布决定的 `go:<sha256>` |

每份被引用证据报告自身都必须写明发布版本和源码提交、观测结果，不包含原始用户路径/秘密，并随发布记录长期保留。复用不相关摘要即使满足格式，也属于审查失败。

## 产物验证

产物目录必须是普通目录，而且只能精确包含 RC 打包契约规定的 6 个文件。验证器会独立检查：

- qualification 文件绑定的 manifest/checksum 哈希；
- 精确 4 项预期 checksum，以及 `shasum -a 256 -c` 成功；
- manifest Schema、版本、干净源码声明、源码提交、Bundle ID、macOS 15.6 部署目标、纯 arm64 架构、文件名和内嵌哈希；
- SPDX 2.3 版本/package declaration 与获批许可证精确一致；
- 严格代码签名有效、ad-hoc/无 Team ID 事实和 Hardened Runtime；
- 精确 3 项沙盒 entitlement；
- 可执行文件哈希、arm64 slice、Info.plist 身份、无内嵌 framework/dylib，以及仅动态链接系统库；
- DMG 验证、只读挂载、精确 4 个挂载项、`/Applications` 链接、notices 一致和挂载 App 签名。

解析或计算哈希前，验证器还会限制 qualification、manifest、checksum、SPDX、notices 和 DMG 大小，并拒绝所有顶层输入边界上的符号链接替换。

## 自动化契约

TDD 契约会构建并 ad-hoc 签名一个很小的合成 arm64 App，创建并挂载一次性只读 DMG，覆盖有效输入，以及缺失/未知/重复字段、类型混淆、失败证据、NO-GO 决策、源码/许可证/分发不匹配、额外或符号链接产物、checksum/可执行文件篡改、脏/错误/过期仓库集成、畸形 JSON 和符号链接 qualification：

```bash
make release-readiness-test
```

测试只使用一次性临时数据并在退出时删除。它不会下载 macOS runtime、Xcode、依赖包或签名身份。

## 当前预期结果

仓库不会检入 qualification JSON，因为不能伪造尚未完成的证据。保留的 rc.7 预期无法通过本门禁：它来自功能分支提交，SPDX 许可证刻意保持 `NOASSERTION`，并且 macOS 15.6、干净账户、打包替换/权限、人工无障碍/可用性、治理和最终发布回执尚不存在。

maintainer 已拒绝 MIT，并接受 ad-hoc Public Beta 风险边界；但仍需选择另一种获批项目许可证，才能关闭 SPDX/notices/qualification 字段。在全部其他证据回执存在、且最终 DMG 从受保护的 `main` 重新构建前，正确结果仍然是 **NO-GO**。
