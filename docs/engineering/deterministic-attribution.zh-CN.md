# 确定性存储分类引擎

最近验证日期：2026-08-11

英文事实源：[deterministic-attribution.md](deterministic-attribution.md)。本文是便于中文阅读的对应译文。

## 目标与当前边界

`SpaceTraceAttribution` 是 FR-007 背后的纯函数、离线分类器。它把词法路径特征和明确的卷上下文转换为保守的存储类别。它不会访问文件系统、打开文件内容、检查进程、联网，也不会判断某份数据“可以安全删除”。

本阶段完成的是分类引擎和首版回归语料，尚未把分类接入历史 finding、SQLite、概览 UI、移动/删除语义或诊断导出。

## 结果契约

一次成功的 `StorageAttribution` 必须包含：

- 一个稳定类别代码；
- 稳定的规则 ID 与正数规则版本；
- `high`、`medium` 或 `low` 置信度；
- 不含路径的稳定证据代码。

Unknown 置信度不能伪装成成功结果进入持久化。分类器只会返回 `classified`、`unknown(noMatchingRule)` 或 `unknown(ambiguous)`。如果最终并列的规则属于不同类别，结果一定降级为“歧义 Unknown”，规则排列顺序不能替用户作决定。

## 输入与优先级

`AttributionInput` 只做词法规范化：折叠重复分隔符和 `.`，拒绝相对路径、`..`、空字节、非法 home 根以及像路径一样的 bundle identifier；home-relative 特征按完整路径组件边界计算。它不会解析符号链接，也不会从路径猜测卷身份。

匹配顺序固定为：

1. 规则配置的每一项证据都必须满足；
2. 显式 priority 较高者优先；
3. priority 相同时，证据维度更多者优先，其次是路径组件更具体者；
4. 同一类别完全并列时，按规则 ID 升序选择稳定证据；
5. 不同类别完全并列时返回歧义 Unknown。

通用 `Library/Caches`/`Library/Logs` 规则的优先级低于具体产品规则。快照因素必须来自平台明确观测；目录名称中出现 “Snapshots” 不能作为证据。

## 内置 catalog v1

| 类别 | 首版证据族 |
| --- | --- |
| 开发工具 | Xcode DerivedData、CoreSimulator、Xcode cache |
| 虚拟化 | Docker container/group 数据、UTM 数据 |
| AI 模型与缓存 | Ollama models、Hugging Face cache、LM Studio models |
| 创意缓存/渲染数据 | Adobe cache/media cache、DaVinci Resolve CacheClip |
| 游戏 | Steam steamapps、Epic、Blizzard |
| 日志与缓存 | 用户/系统 Library Caches 与 Logs 兜底规则 |
| 云端本地数据 | Mobile Documents、CloudStorage、CloudDocs 状态 |
| 快照因素 | 明确观测到的本地 APFS 或 Time Machine 本地快照 |

这些类别只解释观测到的存储位置或上下文，不构成归属证明，更不是清理建议。

## Fixture 证据与未关闭门禁

`attribution-fixtures-v1.json` 当前包含 24 个已知场景（8 个 P0 类别各 3 个）和 8 个近似/Unknown 场景。当前已提交的合成审阅语料上，precision、recall 与 Unknown accuracy 都是 100%。独立测试还证明跨类别并列会保持歧义，并且三种指标使用不同分母。

这只是回归证据，不是真实用户准确率证据；它尚未达到 PRD 的“至少 60 个已知路径”门禁，也没有达到更强的逐类别审阅目标。只有扩充并独立复核语料，而且应用层能为历史 finding 保留准确规则版本和证据后，Public Beta 的这一门禁才可能关闭。

## 新增或修改规则

1. 使用稳定的小写规则 ID 和证据代码，禁止放入用户路径、用户名、展示文案或本地化文字。
2. 使用精确路径组件和足够窄的前缀；路径证据不足时必须增加明确 metadata/context 条件。
3. 修改 catalog 前先加入正例、组件边界近似反例以及重叠/歧义用例。
4. 运行 `swift test --package-path Packages/SpaceTraceKit --filter SpaceTraceAttributionTests` 与 `make verify`。
5. 规则匹配或解释含义变化时递增规则版本。历史结果必须保留旧身份，禁止静默重新解释。

社区规则包、本地化证据文案、持久 finding 与显式重新计算属于后续受治理功能，不是 catalog v1 的隐含行为。
