# macOS 开源小工具机会研究：证据与方法说明

研究日期：2026-07-17（Asia/Shanghai）

## 研究问题

1. Mac 用户目前有哪些持续、具体且可复现的问题？
2. 哪些问题已有成熟第三方方案，继续进入只会形成同质化？
3. 哪些问题仍存在“系统告诉你发生了什么，却不解释为什么”的缺口？
4. 哪些缺口适合个人开发者用原生 macOS 技术做成一个可信、可维护的开源小工具？

## 判定标准

- 用户影响：是否可能导致数据丢失、工作中断、时间浪费或持续焦虑。
- 现有替代成熟度：是否已有多个维护活跃、体验成熟或广泛采用的工具。
- 差异化空间：能否用一句话说清新工具解决了现有方案没解决的问题。
- 技术可行性：是否可主要依赖公开框架、只读系统信息和有限权限完成。
- 开源适配性：本地优先、可审计、无需云服务是否会构成可信度优势。
- 维护风险：是否依赖私有 API、系统内部数据库、硬件兼容矩阵或高风险自动修改。

## 证据边界

- 本研究是探索性市场与产品分析，不是代表性用户调查；Reddit、Apple 社区和商店页面用于发现需求和竞争信号，不能推断总体发生率。
- “推荐等级”是基于上述维度的分析判断，不是统计测量，因此报告使用表格而不是把主观分数画成精确图表。
- 2026 年的新应用变化很快，正式开发前应再做一次 App Store、GitHub、Product Hunt 和 r/macapps 的竞品复核。
- macOS 的“系统数据”不是公开、稳定的文件分类 API；任何产品都应表达为“可观察磁盘增长归因”，不能承诺复现系统设置中的同一个数字。

## 关键证据索引

### 最新用户需求与生态

- r/macapps 的 2026 年 7 月讨论集中提到 Finder、通知、显示器、音频、AirDrop、Spaces、权限总览等摩擦，同时也显示不少需求已经有开发者快速进入。
  - https://www.reddit.com/r/macapps/comments/1uw5fg3/what_is_the_one_tiny_macos_annoyance_you_would/
- Agent Island 展示了一个有效的小工具模式：单一清晰痛点、被动读取本地状态、持续可见反馈、本地优先、无遥测。
  - https://github.com/tristan666666/agent-island

### 系统数据与磁盘增长

- 2026 年仍有大量用户报告 100GB 到数百 GB 的 System Data，常见建议只能做一次性扫描或清理，用户尤其难以回答“为什么又长回来了”。
  - https://www.reddit.com/r/MacOS/comments/1tg3dfu/system_data_size_is_huge/
  - https://www.reddit.com/r/MacOS/comments/1rj6xp9/system_data_is_expanded_to_over_half_of_storage/
  - https://www.reddit.com/r/macbookpro/comments/1uiznz2/245gb_system_data_and_keeps_climbing_after/
  - https://www.reddit.com/r/AskTechnology/comments/vsw9ye/i_need_an_app_for_macos_that_keeps_tracks_of/
- 现有成熟工具 DaisyDisk、GrandPerspective、OmniDiskSweeper 和 Mole 擅长回答“现在谁占空间”；DaisyDisk 也能查看快照，但核心仍是当前状态扫描。
  - https://daisydiskapp.com/
  - https://grandperspective.org/
  - https://github.com/tw93/mole

### Time Machine 可靠性

- Apple 的排障建议覆盖磁盘空间、连接、网络、安全软件和重新开始，但用户仍会遇到设置中没有具体错误的失败。
  - https://support.apple.com/en-us/102220
  - https://www.reddit.com/r/MacOS/comments/1shykzm/time_machine_backup_failed_but_theres_no_error/
- 已有 TimeMachineStatus、T2M2、BackupLoupe 等状态、日志和备份浏览工具；真正较少见的差异是自动化、低风险的“测试文件能否从最近备份恢复并校验”。
  - https://www.macupdate.com/app/mac/65001/timemachinestatus
  - https://macupdater.net/app_updates/appinfo/co.eclecticlight.TheTimeMachineMechanic2/index.html
  - https://support.apple.com/guide/mac-help/verify-your-backup-disk-mh26840/mac

### iCloud 与开发目录

- Apple 鼓励同步 Desktop 与 Documents；当开发者把 Python 虚拟环境、node_modules 等高文件数目录放进去时，可能制造大量小文件同步和 Finder 卡顿。
  - https://support.apple.com/en-us/109344
  - https://www.reddit.com/r/MacOS/comments/1uj42n8/icloud_drive_and_github_problems/
- CloudMonitor 已覆盖一般 iCloud 进度、冲突、卡住与本地占用，因此不建议再做通用同步监视器；更小的空白是“在问题发生前发现开发目录位于云同步范围内”。
  - https://apps.apple.com/by/app/cloudmonitor/id6760430242?mt=12

### 已高度拥挤的方向

- 窗口管理：Rectangle 等已经形成成熟开源基线。
  - https://rectangleapp.com/
- 外接显示器：BetterDisplay 已覆盖分辨率、HiDPI、DDC 和布局等大量需求。
  - https://betterdisplay.dev/
- 每应用音量：FineTune、SoundSource、eqMac 等竞争密集。
  - https://github.com/ronitsingh10/FineTune
- 磁盘安全弹出：Ejecta 已直接显示阻塞进程并提供退出/弹出操作；Sloth 也提供通用 lsof GUI。
  - https://www.ejecta.app/en/
  - https://github.com/sveinbjornt/Sloth
- 输入法自动切换：InputSwitcher、Input Source Pro、AutoSwitchInput 等已覆盖按应用切换。
  - https://inputswitcher.com/
- 隐私权限总览：TCCExplorer、Veil 等已经进入；直接修改 TCC 数据库还涉及 SIP/安全风险。
  - https://apps.apple.com/us/app/tccexplorer/id6502870842?mt=12
  - https://spectrumzero.com/veil/
  - https://support.apple.com/guide/mac-help/control-what-you-share-mchl2b29231a/mac

## 产品原则（受 Agent Island 启发）

- 不做“万能清理器”；只回答一个高价值问题。
- 默认只读，不自动删除、不静默 kill 进程、不修改系统数据库。
- 本地计算、无账户、无遥测；诊断报告由用户主动导出。
- 用菜单栏提供状态，用独立窗口解释证据和变化。
- 对系统无法确认的部分显示置信度和原因，避免“AI 猜测式修复”。
