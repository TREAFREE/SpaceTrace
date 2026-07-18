# Security-Scoped Bookmark 与应用生命周期

状态：**非 UI 架构切片已实现；用户选择界面和权限撤销资格验证仍未完成**

最近验证日期：2026-07-18

英文事实源：[security-scoped-bookmark-lifecycle.md](security-scoped-bookmark-lifecycle.md)。本文是便于中文阅读的对应译文；如两者存在差异，以英文文档为工程事实源，并应在同一次变更中修正译文。

## 1. 本阶段范围

本阶段建立“用户选择目录”到“原生监控”的权限边界：

```text
系统文件选择器返回的 URL
  -> 获取只读 security-scoped bookmark
  -> 写入 SQLite schema v5 的 watched-scope 记录
  -> 精确恢复 bookmark 并持有访问 lease
  -> WatchedScope catalog
  -> Disk Arbitration / FSEvents runtime
  -> 进程级应用生命周期
```

本阶段明确**不会**展示 `NSOpenPanel`、添加权限 UI、默认选择目录、请求 Full Disk Access，也不会让监控成为用户可见功能。未来 UI 必须把系统选择界面返回的原始 URL 交给 `SecurityScopedWatchedScopeCatalog.acquire(selectedURL:scopeID:)`；不能先把 URL 转成字符串，因为字符串不携带 security scope。

## 2. 所有权边界

| 所有者 | 责任 | 禁止承担的责任 |
| --- | --- | --- |
| `SpaceTraceApplication` | 定义 opaque bookmark 记录、持久化端口、恢复报告和 catalog 生命周期协议 | 解析 bookmark bytes 或调用平台 API |
| `SpaceTracePersistence` | 在 SQLite v5 中保存 bookmark 和预期身份 | 记录日志、导出、解码或扩大授权范围 |
| `SpaceTracePlatform` | 创建/恢复原生 bookmark、精确校验资源、配对 access lease、实现 catalog | 打开 UI 或推断产品策略 |
| `SpaceTraceMonitoring` | 恢复 catalog、持有唯一长期 runtime 任务、在退出时取消并释放 | 把监控绑定到窗口或 View 生命周期 |
| `SpaceTraceApp` | 创建 Application Support 存储，并桥接 `NSApplication` 启动/退出 | 承载权限或监控业务逻辑 |

catalog 会为每个活跃 scope 保留一个 access lease。每次成功调用 `startAccessingSecurityScopedResource()`，都会在 catalog 被替换、runtime 失败或应用退出时，恰好配对一次 `stopAccessingSecurityScopedResource()`。

## 3. 持久记录与身份规则

schema v5 新增 `watched_scope_bookmark`：

- 稳定的 `scope_id`；
- opaque bookmark BLOB，最大 1 MiB；
- 授权时记录的精确标准化 root；
- 必填卷 UUID；
- 创建/更新时间。

挂载路径不会被当作授权依据持久化。每次恢复 bookmark 时，都从 `URLResourceKey.volumeURLKey` 重新派生 mount path；随后由 `WatchedScope` 构造保证恢复出的 root 仍位于该 mount path 内。

只有同时满足以下条件，恢复的授权才会被接受：

1. bookmark 能够在不显示 UI、也不主动挂载卷的条件下解析；
2. bookmark 不是 stale；
3. 目标是目录，且不是符号链接；
4. 在当前沙盒应用中能够成功激活 security-scoped access；
5. 标准化后的解析 root 与授权时 root 完全相同；
6. 解析到的卷 UUID 与授权时卷 UUID 完全相同；
7. root 仍在新派生的 mount path 之下。

失败只影响对应 scope，并保持隐私安全。恢复报告只包含 scope ID 和稳定错误码，绝不包含路径、原生错误 payload 或 bookmark bytes。

## 4. 恢复策略

| 失败 | 自动行为 | 需要的恢复方式 |
| --- | --- | --- |
| 应用启动时外置卷不在 | 保留待恢复记录；后续挂载事件读取 catalog 时重试 | 同一卷返回时无需操作 |
| bookmark stale | 不自动刷新或重写 | 用户重新选择该目录 |
| root 路径变化 | 拒绝恢复 scope | 用户检查后重新选择目标目录 |
| 卷 UUID 变化 | 拒绝恢复 scope | 用户明确授权替换后的卷 |
| 符号链接/非目录 | 拒绝 | 用户选择真实目录 |
| 访问被拒绝或撤销 | 不启动该 scope 的监控，并释放任何部分 lease | 用户明确恢复权限 |
| 数据库/catalog 失败 | 应用监控启动失败，并释放全部 lease | 未来 UI 提供修复/恢复流程 |

如果应用启动时已有持久 bookmark、但当前没有任何 scope 能够恢复，仍会启动 Disk Arbitration 观测。这样，曾经授权但启动时未挂载的外置卷在稍后出现时才能被恢复。若没有任何持久 bookmark，则保持 idle，不启动原生卷观测。

## 5. 应用生命周期

`NativeMonitoringApplicationLifecycle` 是 actor，也是长期监控任务的唯一所有者：

1. 恢复 catalog；
2. catalog 中没有持久记录时保持 idle；
3. 否则只启动一个 `NativeVolumeMonitoringRuntime.run()` 任务；
4. 暴露简洁的非 UI 状态：`stopped`、`restoringPermissions`、`idleWithoutConfiguredScopes`、`monitoring`、`stopping`、`failed`；
5. 退出时先取消并等待 runtime，再释放全部 security-scope lease。

SwiftUI 应用通过 `NSApplicationDelegateAdaptor` 接入。`applicationShouldTerminate` 返回 `terminateLater`，完成异步关闭后再回复 AppKit。关闭窗口不会停止监控。

## 6. Entitlement 与分发模式

当前检入仓库的开发应用启用了 App Sandbox，并声明：

```xml
com.apple.security.app-sandbox = true
com.apple.security.files.user-selected.read-only = true
com.apple.security.files.bookmarks.app-scope = true
```

因此组合根使用 `.required`：如果无法激活 sandbox extension，就会 fail closed。

ADR-002 另行提议未来直接分发的产品不启用 App Sandbox，以覆盖更广的普通用户可读目录。本次实现并不接受或落实该分发决策。平台适配器提供了显式的 `.bookmarkIdentityOnly` 模式，供测试及未来可能的直接分发组合使用；它不激活 sandbox extension，但仍执行精确 bookmark/root/volume 身份校验。任何 Release entitlement 变化仍必须经过 ADR、安全评审和发布资格验证。

## 7. 验证情况

确定性测试覆盖：

- 模型大小边界和隐私安全的恢复报告；
- 有效/stale 混合恢复；
- 外置卷暂不可用、返回后重试；
- stale bookmark 不自动重试或刷新；
- 授权获取持久化和 lease 恰好释放一次；
- identity-only 模式下真实原生 bookmark 的无 UI round-trip；
- SQLite v4 到 v5 迁移、替换、往返读取与删除；
- 生命周期 idle、启动、重复启动、失败、取消与关闭；
- `make verify` 中的 package 完整严格并发诊断，以及 Xcode Debug/Release 组合构建。

在本阶段变成用户可见功能之前，仍须用经过签名的沙盒应用完成以下资格验证：真实系统目录选择、重启恢复、运行中撤销权限、stale bookmark 重新授权、外置卷缺席/返回、应用退出，以及 macOS 15.6 真实运行行为。
