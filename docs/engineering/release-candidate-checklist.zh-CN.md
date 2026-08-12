# Ad-hoc Release Candidate 检查清单

状态：**打包契约已实现；尚未具备公开分发资格**

最近更新：2026-08-10

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
| `SpaceTrace-<version>.dmg` | 只读压缩测试镜像，包含 `SpaceTrace.app`、Applications 链接和中英双语信任风险提示 |
| `SpaceTrace-<version>.manifest.json` | commit、版本、构建环境、Bundle ID、部署目标、架构、entitlements、真实签名状态和产物哈希 |
| `SpaceTrace-<version>.sha256` | DMG 与 manifest 的 SHA-256 |

遇到以下任一情况，打包必须 fail closed：源码树不干净、版本缺失或格式错误、输出已存在、Release 构建失败，或最终 bundle 不满足这些不变量：

- Bundle ID 为 `com.TREAFREE.SpaceTrace`；
- 只含 Apple Silicon `arm64`；
- `LSMinimumSystemVersion = 15.6`；
- entitlement 精确等于 App Sandbox、用户选择位置读写和 app-scoped bookmark 三项。读写只用于 `NSSavePanel` 中用户选择的诊断导出文件；被监控目录 bookmark 仍显式只读；
- ad-hoc 签名、无 Team ID、存在 Hardened Runtime；
- manifest 中 `developerId = false`、`notarized = false`。

## 产物验证

在输出目录内运行：

```bash
shasum -a 256 -c SpaceTrace-0.1.0-rc.1.sha256
codesign --verify --deep --strict --verbose=2 SpaceTrace-0.1.0-rc.1.app
codesign -dvvv --entitlements :- SpaceTrace-0.1.0-rc.1.app
hdiutil verify SpaceTrace-0.1.0-rc.1.dmg
spctl --assess --type execute --verbose=4 SpaceTrace-0.1.0-rc.1.app
```

前四项必须成功。`spctl` 应拒绝这个 ad-hoc、未公证产物；拒绝结果证明文档披露的信任边界，并不等于打包失败。如果某台机器意外接受，需要检查它是否保存过本机 Gatekeeper 例外，不能推广为其他 Mac 也会接受。

自动化契约入口：

```bash
make package-release-candidate-test VERSION=0.1.0-rc.1
```

## 测试者安装与首次启动

1. 从同一个 GitHub Release 下载 DMG、manifest 和 checksum。
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

| 场景 | 期望结果 | 当前资格状态 |
|---|---|---|
| 从挂载 DMG 全新复制 | 只在完成明确披露的单 App Gatekeeper 例外后启动；不伪造历史 | 未完成 |
| 同构建退出并重启 | 相同 bundle identity 无需再次选择即可精确恢复有效 bookmark | 对打包 RC 未完成 |
| 使用另一次独立构建的 RC 替换“应用程序”副本 | App 可启动；原 bookmark 要么精确恢复，要么明确提示重新授权 | 未完成；不能假设 ad-hoc designated requirement 连续 |
| stale 或已撤销授权 | 不静默刷新或扩大 scope；必须由用户再次选择 | 确定性 fixture 已通过；真实 RC 条件未完成 |
| 权限被拒绝 | 保留已有可信状态或显示不可用；不能在能力不完整时开始扫描 | 对打包 RC 未完成 |
| 外置卷缺席，随后同一 Volume UUID 返回 | 缺席时显示不可用；相同身份返回后恢复精确授权 | 早期签名沙盒 smoke 已通过；新 RC 行未完成 |
| 同名但不同 Volume UUID 的替换卷 | 旧授权不得转移 | 原生生命周期已通过；打包 UI 行未完成 |
| 数据库/Schema 替换 | 迁移备份与恢复符合 released-schema fixture，不静默重建 | 确定性测试已通过；打包升级行未完成 |

### 当前主机非交互证据（2026-08-10）

从干净 commit `f2119be3fe0ed05e98ef5ec3656e6f7ccbe1d860` 独立生成了两份 `0.1.0-rc.1` 产物。两次运行的签名、entitlement、架构、部署目标、DMG、manifest 与 checksum 校验都通过。与预期相同，两份可执行文件和 DMG 的哈希不同；各自 manifest 记录自己的真实值，且没有声称字节完全一致。`spctl` 对 ad-hoc 未公证 App 返回 3 和 `rejected`。

在同一个一次性 Bundle ID 下，先使用第一份 App，再使用独立构建的替换 App；全新启动、同构建正常重启和替换后启动均通过。流程没有选择目录。macOS containermanager 隐私保护同时拒绝直接删除和系统 `trash` 对约 32 KiB 一次性容器的操作，因此清理记录为阻塞而不是通过。当前主机的精确残留为：

```text
~/Library/Containers/com.TREAFREE.SpaceTrace.RCQualification.run20260810152354p52734
```

删除它需要另一次由用户明确授权 Full Disk Access 的操作。该容器只含资格测试数据，没有修改任何被监控目录。

如果替换构建后需要重新选择目录，GitHub Release 说明必须在测试者安装前明确写出。

## 卸载与回滚

- 退出 SpaceTrace，只把 `SpaceTrace.app` 移到废纸篓即可卸载；这不会删除被监控文件。
- 沙盒容器可能保留 bookmark、历史和设置，便于以后重装。只有明确需要完全重置的测试者，才应在核对精确 Bundle ID 后，按维护者复核过的手动流程删除 SpaceTrace 容器，并为实际执行删除的工具授予 macOS 所需隐私权限；发布产物不能自动删除它、修改 containermanager 元数据，或在正常使用时要求广泛磁盘权限。
- 回滚必须使用以前已校验 checksum 的产物。Schema 兼容与 bookmark 行为没有测试前，不能声称支持回滚。
- 在 SpaceTrace 内移除授权只会释放该 grant，绝不会删除被选择目录及其中内容。

## 公开发布阻塞项

这个测试渠道不会关闭 Developer ID 签名、公证/票据附加、带 quarantine 的干净 Mac 下载测试、macOS 15.6 真实运行、完整替换矩阵、ADR-003/ADR-004 评审或明确发布决策门禁。
