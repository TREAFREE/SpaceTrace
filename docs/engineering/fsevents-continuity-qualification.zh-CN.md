# FSEvents 连续性丢失资格验证

| 字段 | 内容 |
| --- | --- |
| 状态 | 已接受的工程验证规程 |
| 最后更新 | 2026-07-18 |
| 范围 | `UserDropped`、`KernelDropped`、事件 ID 回绕、回调缓冲区溢出和启动后终止 |
| 安全边界 | 仅使用公开 API 和一次性测试环境，不以特权方式操纵系统守护进程 |

## 1. 目的

本规程把 SpaceTrace 能够确定性验证的能力，与只能由 macOS 在真实 FSEvents 守护进程条件下产生的行为明确分开。注入标志位的测试可以证明应用语义正确，但不能证明某个具体系统版本一定会在压力下产生该标志。

Apple 公共 SDK 将 `UserDropped` 和 `KernelDropped` 描述为 `MustScanSubDirs` 的诊断性补充，并要求在连续性丢失后递归扫描；`EventIdsWrapped` 表示以前签发的事件 ID 已经失效。公共 SDK 没有提供用于强制制造这些守护进程条件的受支持 API。

## 2. 验证矩阵

| 条件 | 自动化证据 | 真实守护进程验证 | 当前可声明结论 |
| --- | --- | --- | --- |
| 应用回调桥溢出 | 使用单元素应用缓冲区的原生 APFS 事件流 | 不适用，这是 SpaceTrace 自己的压力边界 | 已验证 |
| 启动后事件流终止 | 可注入 client、持久恢复工作、有界重试、取消和可观测生命周期状态 | 原生意外终止仍属于实验室场景 | 应用生命周期已验证 |
| `UserDropped` | 标志解析，以及 dirty region 持久化到校准的端到端验证 | 仅接受一次性 APFS 镜像上自然产生的证据 | 语义已验证；守护进程触发未验证 |
| `KernelDropped` | 标志解析，以及 dirty region 持久化到校准的端到端验证 | 仅接受一次性 APFS 镜像上自然产生的证据 | 语义已验证；守护进程触发未验证 |
| `EventIdsWrapped` | 抑制游标、原子清除 checkpoint 和校准 | 没有可安全、确定性触发 64 位守护进程计数器回绕的方法 | 语义已验证；守护进程触发未验证 |
| 挂载回调连续性丢失 | 穷举四信号模型序列，以及原生 Disk Arbitration 溢出恢复 | 受控 APFS 卸载、重挂和同名换卷测试 | 已在开发主机验证 |

## 3. 自动化门禁

常规测试必须证明以下全部事实：

1. 原生标志被复制为可安全跨并发边界传递的 observation，且不会暴露不安全游标。
2. 每一种连续性丢失原因都会形成不带游标、持久化的根目录校准工作。
3. 事件 ID 回绕会原子清除已存 checkpoint。
4. 只有完整扫描才能解决持久化的校准工作。
5. 意外终止会发布 `active → recovering → active` 或 `active → recovering → failed`。
6. 卸载和 generation 替换会取消或关闭各自拥有的状态。
7. 两个卷身份和三个运行时磁盘身份组成的全部四信号序列，都保持仓库、协调器和 supervisor 的所有权不变量。

运行常规证据：

```sh
swift test --package-path Packages/SpaceTraceKit
```

会改变测试环境的 APFS 资格测试只能在开发机器上运行，并确保 fixture 位置没有挂载生产路径：

```sh
SPACETRACE_RUN_APFS_IMAGE_TESTS=1 swift test \
  --package-path Packages/SpaceTraceKit \
  --filter APFSDiskImageLifecycleIntegrationTests
```

## 4. 真实守护进程证据规程

只有当全部证据都来自一次性 APFS 磁盘镜像，而且原生回调确实包含对应公开标志时，才能接受为真实守护进程结果。记录必须包含：

- macOS build、硬件架构、文件系统类型和测试代码 commit；
- 原始 flag 数值和解析后的 reasons；
- 监控 scope 与一次性镜像身份，并对用户路径脱敏；
- 回调前后的 checkpoint；
- 校准之前的持久化 dirty region；
- 校准覆盖率和最终生命周期状态；
- 能否在第二个全新镜像上复现。

没有观察到守护进程标志属于“结果不确定”，不能算作通过。事件压力只能发生在一次性镜像内，并且必须有明确的文件数量和字节数上限。

## 5. 禁止使用的验证方式

不得：

- 终止或向系统 `fseventsd` 进程发送信号；
- 删除或修改 `.fseventsd` 数据；
- 在用户主目录或其他生产卷制造压力；
- 依赖 root 权限或私有 API；
- 用注入标志或应用缓冲区溢出冒充真实守护进程验证；
- 将不稳定的守护进程压力实验加入默认 CI 门禁。

## 6. Release 中的表述

在获得真实守护进程证据之前，Release Notes 和健康状态 UI 必须说明：连续性丢失处理已经实现并通过语义验证，但守护进程级 drop/wrap 复现仍未验证。这个限制不允许 SpaceTrace 跳过校准；任何实际观察到的连续性缺口仍必须安排保守校准。
