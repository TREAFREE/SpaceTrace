# 后台长时间运行资格验证

状态：**当前主机两次尝试仍为失败/中断；加固后的重跑与 macOS 15.6 矩阵仍待完成**

最后复核：2026-07-30

英文原文：[Background Soak Qualification](background-soak-qualification.md)

## 目的

本协议用于把一次“已签名、启用沙盒的 SpaceTrace 运行”转换为有界的本机证据，从而验证后台空间生命周期。它必须由开发者或测试者明确开启，不会改变产品默认的“无遥测”立场。

当前实现包括：

- 应用层拥有的 recorder；它观察既有后台协调器，不创建第二套调度器；
- 每次生命周期状态变化和每 60 秒 heartbeat 记录一个不含路径的 JSON 对象；
- 记录当前进程累计 CPU 时间、常驻内存、SQLite 主库/WAL/SHM 聚合大小、容量历史序号、类型化资格状态、采样失败、retention 结果及唤醒恢复延迟；
- 两段式日志，合计最多 10 MiB、最长保留 7 天；目录权限为 `0700`、文件权限为 `0600`；
- 诊断启用期间，菜单栏持续显示本机记录提示；以及
- 可复现的自动分析器，输出机器可读 JSON 报告，失败时返回非零退出码。

它不会上传数据、生成稳定设备标识、阻止系统睡眠，也不会把短时运行冒充成 24 小时资格验证。

## 隐私契约

诊断 Schema 在结构上无法表达以下内容：

- 已授权路径、文件名、卷名、卷 UUID 或 bookmark；
- 可用空间具体字节值或目录测量数据行；
- 环境变量、命令行参数、用户身份或联系方式；以及
- 文件内容。

每次进程启动都会生成一个随机 session UUID。它只用于关联本次运行，不会脱离有界日志另行持久化。即使不含路径，时间与使用行为仍按敏感本机诊断数据处理。

| 字段组 | 分类 | 目的 | 保留/导出 | 删除 |
| --- | --- | --- | --- | --- |
| 墙上时间、连续时钟、随机 session ID | 敏感本机诊断 | 排列事件、测量包含睡眠的真实持续时间、关联一次启动 | 仅本机；最长 7 天/最多 10 MiB；只有用户手动复制才会导出 | 自动过期/轮转，或删除诊断目录 |
| 生命周期 phase、trigger、计数、失败、retention 布尔值 | 敏感本机诊断 | 证明睡眠/唤醒、恢复与维护行为 | 同上 | 同上 |
| 容量序号与类型化资格状态 | 敏感本机诊断 | 不暴露卷身份和容量值的前提下检测倒退，并证明最终 24 小时状态 | 同上 | 同上 |
| 累计 CPU 时间、常驻内存、数据库聚合字节 | 敏感本机诊断 | 检查 NFR 预算与增长趋势 | 同上 | 同上 |

当前不存在自动导出或网络传输。

## 如何开启资格运行

只有启动进程收到以下精确值时，诊断记录才会开启：

```text
SPACETRACE_BACKGROUND_SOAK_DIAGNOSTICS=1
```

App 会把文件写入自身沙盒的 Application Support：

```text
SpaceTrace/Diagnostics/BackgroundQualification/
```

开启后，菜单栏会持续显示“正在本机记录”的提示。如果 writer 创建失败，正常监控仍会继续，但 UI 不会谎称诊断正在工作。

正式发布证据必须使用签名沙盒构建。ad-hoc 签名可用于当前主机的工程 smoke，但不能作为 Developer ID 分发证据。

## 自动分析器

构建并测试资格工具：

```bash
make package-background-soak-qualification
```

分析一次已完成的诊断目录：

```bash
swift run --package-path Packages/SpaceTraceKit \
  SpaceTraceSoakAnalyzer \
  --input "/path/to/BackgroundQualification" \
  --output "/path/to/qualification-report.json"
```

也可以用一条 fail closed 命令同时完成签名 App 预检和分析：

```bash
Scripts/qualify-background-soak.sh \
  "/path/to/SpaceTrace.app" \
  "/path/to/BackgroundQualification" \
  "/path/to/qualification-report.json"
```

既有的 `SPACETRACE_ALLOW_NEWER_HOST_SMOKE` 与 `SPACETRACE_ALLOW_ADHOC_SMOKE` 只允许产生清楚标记为“不计入资格”的预检结果；设置 `SPACETRACE_SOAK_SMOKE_SECONDS` 时，分析器也会切换为 smoke 策略。

默认策略要求全部满足：

- 不倒退的连续时钟证据至少达到 24 小时；
- 非睡眠区间内不存在超过 5 分钟的 heartbeat 缺口；
- 容量历史序号不倒退；
- 最终容量状态为 `qualified`，且没有仍未恢复的连续采样失败；
- 至少观察到一次 retention 成功；
- 从唤醒到状态发布不超过 10 秒；
- 常驻内存不超过 150 MB；
- SQLite 主库、WAL 与 SHM 聚合大小不超过 250 MB；
- 平均 CPU 占比不超过 0.5%，区间 p95 不超过 2%。

仅验证管线连通性时可以使用 `--smoke <最短秒数>`，它会放宽 24 小时、retention、最终容量资格和 CPU 要求。smoke 结果绝不能作为发布资格结果。

## 必须完成的真实矩阵

每次签名沙盒运行结束后，都使用默认策略执行分析器：

| 主机 | 时长 | 必需转换 | 状态 |
| --- | ---: | --- | --- |
| Apple Silicon 当前稳定版 macOS | 至少 24 小时 | 启动、普通运行、真实睡眠/唤醒、时间变化、时区变化、跨本地午夜、退出/重启 | 2026-07-27 资格失败；2026-07-29 被中断；需用加固 runner 重跑 |
| Apple Silicon macOS 15.6 | 至少 24 小时 | 同一矩阵 | 待完成 |

每台主机还必须：

1. 保持系统正常睡眠，不能用防睡眠工具“优化”结果。
2. 覆盖交流电和电池运行；条件允许时包含低电量模式。
3. 验证菜单栏只有在持久化证据有效后才进入 qualified，真实缺口后会降级。
4. 保存分析器报告以及构建/签名元数据。
5. 使用 Instruments/Energy Log 或其他 Apple 支持的分析工具采集能耗证据。内部累计 CPU 时间不是能耗测量。
6. 接受结果前检查日志大小、文件权限、数据库增长，以及日志中不存在类似路径的内容。

当前主机 runner 会让应用自身的诊断保持连续，同时通过 5 个有界的 Activity Monitor Instruments 切片控制磁盘占用：分别在第 0、6、12、18、24 小时记录 5 分钟。

```bash
Scripts/run-current-host-soak.sh start \
  "/path/to/SpaceTrace.app" \
  "$HOME/Library/Application Support/SpaceTraceQualification/<run-id>" \
  90000
```

请先创建证据目录，并避开 Desktop、Documents 和 Downloads。脱离终端运行的 launchd worker 不会继承 Terminal/Codex 对这些隐私保护目录的访问权。runner 会在启动前把不可变的 App、分析器和 worker 复制进证据目录，并为本次运行创建显式的 LaunchAgent plist：`RunAtLoad=true`、`KeepAlive=false`。worker 失败后必须以 `FAILED` 终止，不能被静默重新拉起。

可以在不中断长跑的情况下查看 detached supervisor：

```bash
Scripts/run-current-host-soak.sh status \
  "/path/to/evidence-directory"
```

脱离会话的 worker 现在会在运行窗口结束后立即完成正常退出、受保护存储检查、隐私扫描和默认 24 小时分析；最终状态应为 `PASSED` 或 `FAILED`。手动命令只保留给停在 `READY_TO_FINALIZE` 的旧版/中断运行作恢复用途：

```bash
Scripts/run-current-host-soak.sh finalize \
  "/path/to/evidence-directory"
```

25 小时墙上时间窗口会在最后一个 24 小时切片之后再保留 1 小时，用于正常退出与最终分析。runner 不会阻止系统睡眠。每个 Instruments 切片都会导出目录、进程 ledger、实时进程序列和 Thermal State 区间，其中包含 CPU 百分比/时间、Idle Wake Ups、物理内存、磁盘读写、App Nap、是否阻止睡眠以及系统温度状态。

在 Xcode 26 中，虽然列表里仍有 `Power Profiler`，但它会拒绝 macOS target，并明确表示只支持 iOS/iPadOS；旧 `Energy Log` 模板也未安装。因此 Activity Monitor 数据只能称为**与能耗相关的进程证据**，不能称为直接的焦耳/瓦特测量。`powermetrics --show-process-energy` 可以补充 SoC 估算功耗与进程 Energy Impact，但需要交互式管理员授权；其帮助文档也明确警告估算功耗不能用于跨设备比较。缺少授权时必须保留为证据缺口。每次运行还会把已安装模板列表，以及最新的 Power Profiler / 非特权 `powermetrics` 支持探针写入 `energy-capability.txt`。

在较新 macOS 上以 15.6 deployment target 编译，不等于完成 macOS 15.6 真实运行资格验证。

## 2026-07-27 当前主机真实长跑：已采集，未通过资格

本次在 Apple Silicon MacBook Air、macOS 26.5.2 上运行独立 bundle identity 的 ad-hoc 签名 Release/App Sandbox 构建。App 只包含 App Sandbox、用户选择只读与 app-scoped bookmark 三项 entitlement，`LSMinimumSystemVersion = 15.6`。它属于当前主机工程证据，不属于 Developer ID、公证、分发或 macOS 15.6 运行证据。

默认分析器按设计 fail closed：

- 单一 session 的 1,693 条无路径记录覆盖 168,945,297 ms（46 小时 55 分 45.297 秒）；旧 runner 等待人工最终化，因此 App 超过预期 25 小时窗口后仍继续运行；
- `final_capacity_not_qualified` 是真实资格缺口：一次长睡眠使 24 小时窗口的端点容差内不存在基线样本，退出前只有约 1.5 小时的新鲜清醒历史；
- `wake_recovery_budget_exceeded` 暴露的是 recorder 缺陷，不是真实的 30 小时恢复。一次成功 wake 长期保留为“最后采样触发器”，后续延后的 maintenance 状态发布重复从旧 wake 计算耗时。原始证据中的即时 wake 发布为 0–198 ms，但正式报告仍必须保持失败，并用修正后的 recorder 重跑；
- 其他分析器指标在预算内：最大清醒 heartbeat 间隔 62,047 ms、最大 RSS 141,115,392 字节、最大数据库 350,016 字节、平均 CPU 占比 0.00624%、区间 p95 CPU 占比 0.02325%，不存在未恢复采样失败，并且已观察到 retention 成功；以及
- 有界诊断目录约 900 KiB，目录/文件权限为 `0700`/`0600`，禁止字段扫描为空。

五段 Activity Monitor 记录与导出均无采集失败。五个 5 分钟 live 序列（合计 25 分钟）的证据如下：

| 指标 | 证据 |
| --- | ---: |
| CPU 时间 | 0.493001 秒 |
| 各切片平均 CPU | 0.011914%–0.038800% |
| 各切片 p95 CPU | 0.023103%–0.073675% |
| 最高瞬时 CPU | 启动切片 2.843294% |
| Idle Wake Ups | 合计 1,180，约 0.79 次/秒 |
| 磁盘写入 / 读取 | 2,023,424 / 155,648 字节 |
| 最大物理内存 footprint | 53,068,760 字节 |
| App Nap | 后四个切片均观察到 |
| Preventing Sleep | 五个切片均未观察到 |
| Thermal State | 五个切片均为 Nominal |

这些属于与能耗相关的进程资源测量，不是瓦特/焦耳测量。Power Profiler 拒绝 macOS target，非特权 `powermetrics` 则要求 superuser 授权。

这次证据直接推动了四项 fail-closed 修正：wake 恢复时间只为每个新的成功 wake 记录一次；睡眠中延后的 retention 机会只确认一次，并在真实唤醒后由 App 补执行，避免要求系统快速重试；自动导出 thermal XML；脱离会话的 worker 在窗口结束后只依赖系统路径工具自动最终化。随后 60 秒 detached 回归通过自动正常退出、thermal 导出、真实隐私扫描、分析器执行和 launchd 清理。

容量历史契约同时新增了 schema-v10 睡眠/唤醒边界：只有严格相邻的一对边界才能解释长间隔；醒着漏采、边界缺失/单侧以及 App 退出造成的缺口仍然失败关闭。v9 迁移、失败回滚和 24 小时查询分支均已有确定性回归。当前主机矩阵仍须等待新的默认策略运行通过。

## 2026-07-29 当前主机重跑：被外部中断

提交 `3ae4f24` 的 schema-v10 构建使用独立 bundle identity，完成 ad-hoc 签名并在 Release/App Sandbox 中启动。签名预检、三项必要 entitlement、`LSMinimumSystemVersion = 15.6`、诊断记录以及第一段 Activity Monitor attach 均成功。

App 在运行 212.012 秒后以 `exit(0)` 完成有序退出。无路径日志包含一个 session、三次 heartbeat 和最终 `stopped` 记录，没有采样失败；系统没有对应 crash report 或信号终止证据，现存统一日志也无法确定外部正常终止请求的来源。监督器正确发现 App 未到资格端点就已退出。主机随后又在 2026-07-30 01:11 关机、09:36 重启，这一点也独立地使整轮墙上时间证据失去资格。因此它属于“运行被中断”，既不是产品可靠性失败结论，也不是 24 小时结果。

这次中断暴露了 runner 的两个缺陷：zsh `EXIT` trap 在函数作用域结束后读取局部变量，导致状态文件遗留为 `RUNNING`；`launchctl submit` 还会推断 `KeepAlive`，非零退出的 worker 可能被重新拉起。runner 现改为脚本生命周期清理状态、受保护的类型化失败摘要、对遗留孤儿 `RUNNING` 的失败投影，以及不自动重启的逐次运行 LaunchAgent。

两轮相互独立的签名沙盒回归覆盖了两个终态：

- 受控提前 `exit(0)` 后写入 `FAILED` 与 `failure_reason=app_exited_before_qualification_end`，App 和 supervisor 均清理且没有重启；
- 不受干扰的 60 秒 smoke 写入 `PASSED`：采集失败为 0、隐私扫描为空、分析器退出码为 0；一个 session 的 4 条记录覆盖 59,737 ms，最大 RSS 为 139,509,760 字节，最大数据库为 292,336 字节，launchd job 无残留。

这些 smoke 只验证 runner 管线，不关闭当前主机 24 小时门禁。下一轮仍保持正常系统睡眠，但期间不能关机、注销或主动退出 SpaceTrace。

## 当前主机 smoke 证据

2026-07-25，在 Apple Silicon macOS 26.5.2 上使用独立 bundle ID 构建 Release App，完成 ad-hoc 签名并在 App Sandbox 中开启诊断。设置 120 秒的“不计入资格” smoke 策略后通过：

- 签名与 designated requirement 校验通过；最终产物包含三项必需沙盒 entitlement 以及 `LSMinimumSystemVersion = 15.6`；
- 7 条记录覆盖 241.636 秒，并包含正常 App 退出；
- 排除不足 10 秒、不可用于区间百分位的生命周期瞬态后，平均 CPU 占比为 0.0344%，p95 为 0.0907%；
- 最大常驻内存为 135,495,680 字节，数据库聚合大小为 263,496 字节；
- 日志大小 3,585 字节；目录/文件权限分别为 `0700`/`0600`；以及
- 禁止字段扫描未发现用户路径、bookmark、卷身份、容量具体值、环境、命令行或文件名字段。

这项 smoke 证明当前主机上的签名沙盒接线、heartbeat、资源探针、正常退出、受保护持久化与分析器互操作。它**没有**覆盖睡眠/唤醒、retention 到达、能耗测量、24 小时容量资格、Apple 签名身份或 macOS 15.6 运行证据。

## 自动化覆盖

确定性测试覆盖：健康资格、资源预算和序号边界的 fail closed、睡眠包围缺口与普通唤醒缺口的区分、Schema 隐私、retention 过期、两段轮转、POSIX 权限、原生进程资源探针，以及菜单栏启用提示。新增 package 代码还通过了完整严格并发告警审计。

这些测试可以证明实现逻辑；只有真实矩阵才能证明长时间调度、睡眠/唤醒、能耗和最低系统运行行为。
