# Ad-hoc Release Candidate 检查清单

状态：**打包契约已实现；尚未具备公开分发资格**

最近更新：2026-08-14

英文事实源：[release-candidate-checklist.md](release-candidate-checklist.md)。本文是便于中文阅读的对应译文；如两者存在差异，以英文文档为工程事实源，并应在同一次变更中修正译文。

## 用途与边界

这份清单用于在没有 Developer ID 证书时生成可检查的 SpaceTrace 测试产物。App 使用 ad-hoc 签名并启用 Hardened Runtime，继续保留沙盒，最终装入只读压缩 DMG。它**没有经过公证**，Gatekeeper 无法验证发布者，不能称为稳定版或“Apple 已验证”版本。

这里的可复现是“源码与契约可复现”：manifest 会把产物绑定到干净 Git commit、版本、构建环境、entitlements、架构、部署目标和校验值。UDZO/HFS+ 镜像元数据可能在两次运行间变化，因此不声称 DMG 的字节与 SHA-256 每次完全相同。

## 维护者构建

前置条件：

- Apple Silicon Mac 和仓库支持的 Xcode 工具链；
- 工作区位于准备发布的不可变 commit，且 `git status` 干净；
- 输出目录尚不存在；
- 明确提供 SemVer，例如 `0.1.0-rc.1`。

执行：

```bash
make package-release-candidate \
  VERSION=0.1.0-rc.1 \
  OUTPUT=/private/tmp/SpaceTrace-0.1.0-rc.1
```

预发布/构建后缀属于发布 manifest 和文件名；纯数字 SemVer 核心写入 `CFBundleShortVersionString`，确定性的 Git commit 计数写入 `CFBundleVersion`。

## 精确产物契约

新输出目录只能包含：

| 产物 | 用途 |
|---|---|
| `SpaceTrace-<version>.app` | 本地检查和资格验证；ad-hoc 签名并启用 Hardened Runtime |
| `SpaceTrace-<version>.dmg` | 只读压缩测试镜像，包含 `SpaceTrace.app`、Applications 链接、第三方声明和中英双语信任风险提示 |
| `SpaceTrace-<version>.manifest.json` | commit、版本、构建环境、Bundle ID、部署目标、架构、entitlements、真实签名状态和产物哈希 |
| `SpaceTrace-<version>.sha256` | DMG、manifest、SPDX 文档与声明的 SHA-256 |
| `SpaceTrace-<version>.spdx.json` | 确定性 SPDX 2.3 源码/依赖与来源清单 |
| `SpaceTrace-<version>.third-party-notices.txt` | 精确的内嵌依赖声明和项目许可证边界；DMG 内也包含一份 |

遇到以下任一情况，打包必须 fail closed：源码树不干净、版本缺失或格式错误、输出已存在、Release 构建失败，或最终 bundle 不满足这些不变量：

- Bundle ID 为 `com.TREAFREE.SpaceTrace`；
- 只含 Apple Silicon `arm64`；
- `LSMinimumSystemVersion = 15.6`；
- entitlement 精确等于 App Sandbox、用户选择位置读写和 app-scoped bookmark 三项。读写只用于 `NSSavePanel` 中用户选择的诊断导出文件；被监控目录 bookmark 仍显式只读；
- ad-hoc 签名、无 Team ID、存在 Hardened Runtime；
- manifest 中 `developerId = false`、`notarized = false`；
- 没有远程 Swift package、内嵌 framework/dylib 或非系统 Mach-O 依赖；最终二进制只允许链接 `/System/Library` 和 `/usr/lib`。

## 产物验证

在输出目录内运行：

```bash
shasum -a 256 -c SpaceTrace-0.1.0-rc.1.sha256
codesign --verify --deep --strict --verbose=2 SpaceTrace-0.1.0-rc.1.app
codesign -dvvv --entitlements :- SpaceTrace-0.1.0-rc.1.app
hdiutil verify SpaceTrace-0.1.0-rc.1.dmg
plutil -extract spdxVersion raw -o - SpaceTrace-0.1.0-rc.1.spdx.json
plutil -extract packages.0.licenseDeclared raw -o - SpaceTrace-0.1.0-rc.1.spdx.json
spctl --assess --type execute --verbose=4 SpaceTrace-0.1.0-rc.1.app
```

前六项必须成功，两个 SPDX 值应分别为 `SPDX-2.3` 和 `NOASSERTION`。`spctl` 应拒绝这个 ad-hoc、未公证产物；拒绝结果证明文档披露的信任边界，并不等于打包失败。如果某台机器意外接受，需要检查它是否保存过本机 Gatekeeper 例外，不能推广为其他 Mac 也会接受。

SPDX 文档是源码来源、构建来源和依赖清单，不是漏洞证明。当前依赖图没有外部 Swift package 或内嵌第三方库；Apple frameworks、系统 Swift runtime 和系统 `libsqlite3` 由 macOS 平台提供。`NOASSERTION` 是刻意保留的边界：生成元数据不能代替仓库所有者批准项目许可证。

自动化契约入口：

```bash
make package-release-candidate-test VERSION=0.1.0-rc.1
```

## 测试者安装与首次启动

1. 从同一个 GitHub Release 下载 DMG、manifest、checksum、SPDX 文档和第三方声明。
2. 校验 SHA-256，并确认 manifest 的 `sourceCommit` 等于预期公开 commit。
3. 打开 DMG，把 SpaceTrace 拖入“应用程序”。
4. 正常尝试打开 SpaceTrace；首次应被 Gatekeeper 拦截。
5. 只有在信任对应 commit 与校验值时，才进入**系统设置 > 隐私与安全性**，找到 SpaceTrace 被阻止的提示，点击**仍要打开**并确认只针对该 App 的例外。
6. 不要全局关闭 Gatekeeper，也不要把递归移除 quarantine 当成支持的安装方法。

首次启动必须显示未配置且不伪造证据的状态。SpaceTrace 只访问用户通过系统选择器明确选择的目录。

## 替换与权限矩阵

每一个不同 RC 构建都必须执行并记录以下各行；过去的 ad-hoc smoke 不能自动替代新 DMG 的资格验证。

非交互式启动/替换子集会使用一次性 Bundle ID，并尝试把与其精确匹配的临时沙盒容器移入废纸篓：

```bash
make qualify-release-candidate \
  PRIMARY_APP=/第一份/SpaceTrace-0.1.0-rc.1.app/绝对路径 \
  REPLACEMENT_APP=/第二份/SpaceTrace-0.1.0-rc.1.app/绝对路径
```

它会分别报告全新启动、同构建正常退出/重启和独立二进制替换后启动。容器移除采用 fail closed：如果 macOS 容器隐私保护拒绝终端访问，命令会返回 `container-cleanup-blocked-by-macos-privacy`，打印精确残留路径，而且不会修改容器元数据或扩大删除范围。该流程不会选择目录，因此不能验证 bookmark 连续性、拒绝权限、stale 授权或外置卷行为。

这个非交互子集会拒绝顶层 App bundle 带有 `com.apple.quarantine` 的任一输入。从网络下载的 ad-hoc 候选必须先在干净账户中完成人工、单 App 的 Gatekeeper 例外；资格脚本不会移除 quarantine，也不会自动代替用户作出这项信任决定。

| 场景 | 期望结果 | 当前资格状态 |
|---|---|---|
| 从挂载 DMG 全新复制 | 只在完成明确披露的单 App Gatekeeper 例外后启动；不伪造历史 | `0.1.0-rc.7` 已通过只读挂载、复制、quarantine 和预期 Gatekeeper 拒绝；干净账户的**仍要打开**启动仍未完成 |
| 同构建退出并重启 | 相同 bundle identity 无需再次选择即可精确恢复有效 bookmark | 一次性身份下的进程重启已通过；打包 bookmark 连续性仍未完成 |
| 使用另一次独立构建的 RC 替换“应用程序”副本 | App 可启动；原 bookmark 要么精确恢复，要么明确提示重新授权 | 非 quarantine 的 `rc.6 → rc.7` 与 `rc.7 → rc.6` 进程替换已通过；打包 bookmark 连续性仍未完成，不能从 ad-hoc 签名推断 |
| stale 或已撤销授权 | 不静默刷新或扩大 scope；必须由用户再次选择 | 确定性 fixture 已通过；真实 RC 条件未完成 |
| 权限被拒绝 | 保留已有可信状态或显示不可用；不能在能力不完整时开始扫描 | 对打包 RC 未完成 |
| 外置卷缺席，随后同一 Volume UUID 返回 | 缺席时显示不可用；相同身份返回后恢复精确授权 | 早期签名沙盒 smoke 已通过；新 RC 行未完成 |
| 同名但不同 Volume UUID 的替换卷 | 旧授权不得转移 | 原生生命周期已通过；打包 UI 行未完成 |
| 数据库/Schema 替换 | 迁移备份与恢复符合 released-schema fixture，不静默重建 | 确定性测试已通过；打包升级行未完成 |

### 当前主机候选证据（2026-08-14）

在 macOS 26.6.1、Xcode 26.1.1 上，从干净且已推送的 commit `a3b8b45ca6f9dad752a9b750422b343d71c04dc8` 生成了保留的 `0.1.0-rc.7` 产物。其打包契约已通过签名、精确 entitlement、架构、部署目标、最终 Mach-O 依赖、DMG、manifest、四项 checksum、SPDX 与 notices 校验。可执行文件 SHA-256 为 `f52a0ff3984256e606f35c61b400b2da76283b629fa315a34667b38858da356a`；DMG 为 `dab727280f2c68829cc4ddb51b78bebe1ba1250cc3c6433d4dcf0fea8116d38a`；SPDX 为 `53f7e468c9754919a282418e0f86ef23682586f2c004841cb933246a2e228a46`；notices 为 `c5bfed60122264ac1123eeabeb61893e94b964b01e1eb8fd4c79fcf5b83f4250`。先前已校验 checksum 的 `rc.6` 提供了用于正向和反向进程替换的独立二进制；这里不声称两次构建字节完全一致。

主 DMG 以只读方式挂载，内容精确为 `SpaceTrace.app`、指向 `/Applications` 的符号链接、`READ-ME-FIRST.txt` 和 `THIRD-PARTY-NOTICES.txt`。带合成下载 quarantine 属性的复制 App 仍通过严格代码签名校验。`spctl` 返回 3 和 `rejected`；`syspolicy_check distribution` 返回 70，并独立报告 ad-hoc 签名与缺失公证票据。可执行文件和 `Info.plist` 都记录 macOS 15.6 最低版本。这些检查证明当前主机上的产物与信任边界，但不能替代干净账户的**仍要打开**启动或 macOS 15.6 运行资格。

使用本机测试签名的 Xcode 沙盒 runner 完成了全部 15 个授权、历史、finding 和导出 UI 场景。诊断导出场景打开真实 `NSSavePanel`、确认用户选择的保存位置、从磁盘读取结果 JSON，并验证 2 MiB 上限、路径脱敏模式和不自动上传声明；该场景还连续聚焦运行 3 次通过。这证明当前主机签名沙盒保存路径，但不声称 quarantined ad-hoc RC 已在干净账户完成人工 Gatekeeper 例外，也不声称使用了 Developer ID 身份。

使用非 quarantine 的保留 App 和一次性 Bundle ID，`rc.6 → rc.7` 与 `rc.7 → rc.6` 都完成了全新启动、同构建正常重启、替换后启动和正常退出。流程没有选择目录，因此这只是进程替换证据，不是 bookmark 或数据库回滚资格。较早的根因调查期间，曾启动一份带合成 quarantine 的 `rc.6` 副本：macOS 创建进程后由 Apple System Policy 主动终止，准确符合已披露的信任边界；资格脚本会在启动前拒绝此类输入。macOS containermanager 隐私保护拒绝系统 `trash` 对每个约 984 KiB 一次性容器的操作，因此清理记录为阻塞而不是通过。rc.6 与 rc.7 边界资格产生的五个当前主机残留为：

```text
~/Library/Containers/com.TREAFREE.SpaceTrace.RCQualification.run20260813161709p86005
~/Library/Containers/com.TREAFREE.SpaceTrace.RCQualification.run20260813161920p86393
~/Library/Containers/com.TREAFREE.SpaceTrace.RCQualification.run20260813162038p86552
~/Library/Containers/com.TREAFREE.SpaceTrace.RCQualification.run20260813163720p39902
~/Library/Containers/com.TREAFREE.SpaceTrace.RCQualification.run20260813163738p40045
```

删除它们需要另一次由用户明确授权 Full Disk Access 的操作。这些容器只含资格测试数据，没有修改任何被监控目录。

如果替换构建后需要重新选择目录，GitHub Release 说明必须在测试者安装前明确写出。

## 卸载与回滚

- 退出 SpaceTrace，只把 `SpaceTrace.app` 移到废纸篓即可卸载；这不会删除被监控文件。
- 沙盒容器可能保留 bookmark、历史和设置，便于以后重装。只有明确需要完全重置的测试者，才应在核对精确 Bundle ID 后，按维护者复核过的手动流程删除 SpaceTrace 容器，并为实际执行删除的工具授予 macOS 所需隐私权限；发布产物不能自动删除它、修改 containermanager 元数据，或在正常使用时要求广泛磁盘权限。
- 回滚必须使用以前已校验 checksum 的产物。Schema 兼容与 bookmark 行为没有测试前，不能声称支持回滚。
- 在 SpaceTrace 内移除授权只会释放该 grant，绝不会删除被选择目录及其中内容。

## 公开发布阻塞项

这个测试渠道不会关闭 Developer ID 签名、公证/票据附加、带 quarantine 的干净账户**仍要打开**启动、macOS 15.6 真实运行、独立构建替换后的 bookmark 连续性、完整权限/替换矩阵、ADR-003/ADR-004/ADR-006/ADR-008/ADR-009 评审、项目许可证批准、人工无障碍/可用性复核或明确发布决策门禁。当前主机的重复校准矩阵已 20/20 通过，SBOM/第三方声明生成契约也已实现，但 `NOASSERTION` 会刻意保持许可证所有者决策未关闭。
