# SQLite 适配器证据评审

状态：**第一阶段适配器决策评审已完成**

评审日期：2026-07-20

英文事实源：[sqlite-adapter-evidence-review.md](sqlite-adapter-evidence-review.md)。本文是便于中文阅读的对应译文。

## 决策摘要

GRDB 7.10.0 在技术和许可上都适用于 SpaceTrace：官方 package 支持 macOS 10.15+、Swift 6.1+/Xcode 16.3+、SPM、系统 SQLite、迁移、WAL 读连接池及备份 API。作为依赖，其宽松 MIT 条款与 SpaceTrace 的 PolyForm 非商业源码可见分发兼容，但分发时必须保留 GRDB 的版权和许可声明。

不过，SpaceTrace 在第一阶段剩余工作中继续使用隔离在 repository 内的原生 SQLite 适配器。当前持久事件日志、校准发布和恢复契约仍在演进；此时引入 GRDB 会替换已经有测试保护的事务代码，却还没有经测量证明产品收益。当历史查询真正需要并发读快照时，GRDB 仍是首选候选，但必须先通过行为等价和性能 spike。

这个结论完成了依赖、许可和本机构建比较，但**不代表** ADR-004 已被接受，也不代表已经证明公证分发构建、50 万/100 万行 benchmark 或 macOS 15.6 真实运行。

## 证据矩阵

| 问题 | GRDB 7.10.0 证据 | 原生 SQLite 证据 | 结论 |
| --- | --- | --- | --- |
| 平台/工具链 | 固定 tag 的 manifest 声明 macOS 10.15+、Swift tools 6.1；SpaceTrace 目标为 macOS 15.6，当前主机为 Swift 6.2.1/Xcode 26.1.1 | 链接系统 `libsqlite3`；当前主机 CLI 为 SQLite 3.51.0 | 两者均与当前构建主机兼容 |
| 许可 | 固定版本使用 MIT；分发必须附带声明 | SQLite 由 macOS 提供，SpaceTrace 不额外打包数据库二进制 | 完成 notice/SBOM 后 GRDB 可接受 |
| 依赖面 | SPM 提供 `GRDB` 与 `GRDB-dynamic`；官方建议不确定时使用 `GRDB` | 无 package 下载和传递 Swift 依赖 | 原生方案供应链面更小 |
| 并发 | `DatabasePool` 提供 WAL 并发读和串行写 | 当前 actor 独占单连接，读写均串行 | 未来历史查询更适合 GRDB |
| 迁移 | `DatabaseMigrator` 可减少 C API 模板代码，但排序、checksum、备份和恢复策略仍由 SpaceTrace 负责 | 当前前向迁移与回滚接缝显式且已有 repository 测试 | GRDB 降低机械工作，不消除策略风险 |
| 备份/恢复 | GRDB 封装 SQLite online backup | 原生适配器可调用同一 C API，但迁移备份尚未实现 | 任一方案都不会自动完成 ADR 恢复要求 |
| 领域隔离 | 可限制在 `SpaceTracePersistence` | 已限制在 `SpaceTracePersistence` | 两者均满足依赖规则 |
| 当前回归风险 | 需要迁移事件日志、挂载 generation、bookmark、staging/finalization、基线、类型化错误和故障接缝 | 现有行为已通过 package/app 门禁 | 第一阶段保留原生适配器 |

官方一手资料：

- [GRDB 7.10.0 README 与环境要求](https://github.com/groue/GRDB.swift/blob/v7.10.0/README.md)
- [GRDB 7.10.0 Package manifest](https://github.com/groue/GRDB.swift/blob/v7.10.0/Package.swift)
- [GRDB 7.10.0 MIT 许可](https://github.com/groue/GRDB.swift/blob/v7.10.0/LICENSE)
- [SQLite 返回码定义](https://www.sqlite.org/rescode.html)
- [SQLite WAL 行为](https://www.sqlite.org/wal.html)
- [SQLite 完整性检查 pragma](https://www.sqlite.org/pragma.html#pragma_integrity_check)
- [SQLite 在线备份 API](https://www.sqlite.org/backup.html)

## 可复现的本机 spike

评审使用一次性 Swift package，固定解析 GRDB `7.10.0`，deployment target 为 macOS 15.6。Release 可执行程序打开 `DatabasePool`，注册并执行一个 `DatabaseMigrator` 迁移，查询新表后正常退出。

记录的主机证据：

```text
Apple Swift 6.2.1
Xcode 26.1.1 (17B100)
GRDB 7.10.0 exact SPM resolution
Build of product 'GRDBSpike' complete
GRDB 7.10.0 static SPM spike passed
```

`otool -L` 显示系统 `/usr/lib/libsqlite3.dylib`，没有单独嵌入 GRDB 动态 framework。这证明在当前主机上，被测的默认 `GRDB` product 链入可执行程序并使用系统 SQLite；它不是 App Sandbox、代码签名、公证或最低系统运行结果。

## 本次评审同时增加的可靠性证据

Schema v7 和确定性测试现在证明：

- 通过 `PRAGMA max_page_count` 触发真实 `SQLITE_FULL`，错误被映射为类型化“磁盘写满”，此前提交的 bookmark 不会改变；
- 一个有效 SQLite fixture 的数据库头被破坏后，会在持久 pragma 之前被识别，返回类型化损坏错误，并且不会被静默替换；
- 在 schema v7 语句执行后、提交前注入失败，会同时回滚 schema 对象和 `user_version`，保留 v6 语义状态；
- 固定时钟下的一次 retention 事务会删除过期 deleted node、可替代的旧基线和无引用已完成 scan run，同时保留当前目录事实、未解决 dirty work 以及每个 scope 的最新基线；
- 在第一次 retention 删除后注入失败，会回滚整个 retention 事务；
- retention 配置拒绝 ADR-004 的 1–30 天范围之外的路径历史窗口。

本次 retention 只处理目前已经存在的表。小时/日历史样本、finding、老化 dirty path 转为无路径校准要求、数据库体积预算、空闲 WAL checkpoint、迁移备份、只读恢复 UI 和“清除历史”仍是后续验收门禁。

## GRDB 采用门禁

在一个聚焦变更同时证明以下内容前，不把 GRDB 加入生产依赖图：

1. 当前全部事务和类型化失败的 repository 行为等价；
2. 从最新已发布原生 SQLite schema 原地迁移，不重写数据库文件；
3. 在 PRD fixture 上测量读写、内存、二进制大小、checkpoint 和 retention；
4. 固定版本锁、依赖 diff、许可声明、privacy manifest 和 SBOM 评审；
5. 有可用身份后完成签名 App Sandbox 与 Developer ID 公证；
6. 完成 macOS 15.6 与当前稳定系统的运行资格验证。

在这些门禁通过前，架构图应把 `SpaceTracePersistence` 描述为 SQLite 适配器，并把 GRDB 标注为候选，而不是已经安装的组件。
