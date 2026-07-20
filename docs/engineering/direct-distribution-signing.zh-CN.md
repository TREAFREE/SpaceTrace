# DMG 直接分发与代码签名

状态：**发布前策略；尚未完成公开分发资格验证**

最近更新：2026-07-20

英文事实源：[direct-distribution-signing.md](direct-distribution-signing.md)。本文是便于中文阅读的对应译文；如两者存在差异，以英文文档为工程事实源，并应在同一次变更中修正译文。

## 当前决定

在维护者尚未购买 Apple Developer Program 会员期间，SpaceTrace 可以向人数较少、明确互相信任的测试者提供 ad-hoc 签名 DMG。它属于测试渠道，不是已经获得 Gatekeeper 信任的公开发行版。

把文件放到 GitHub 并不会让 macOS 识别开发者。用户尝试打开 App 后，通常可以进入**系统设置 > 隐私与安全性 > 仍要打开**，手动绕过“未知开发者/未公证”警告。Apple 明确提醒这种绕过会失去一层重要保护，因此 SpaceTrace 不能把它描述成普通“验证”，更不能说它等同于 notarization（公证）。

不要要求用户全局关闭 Gatekeeper，也不要让用户递归删除 quarantine 属性。系统设置中的手动例外范围更小，并会保留 Gatekeeper 对其他软件的保护。

## 付费会员会改变什么

Apple 只向 Apple Developer Program 或 Enterprise Program 会员签发 Developer ID 证书。正式的站外直接分发流程是：

1. 使用 Hardened Runtime 和经过审查的 Sandbox entitlements 归档 Release 构建；
2. 使用 Developer ID Application 证书签名 App 及其中的可执行代码；
3. 创建 DMG；
4. 把交付物提交到 Apple notary service，并附加（staple）公证票据；
5. 发布前验证签名、公证、quarantine 首次启动、更新兼容性和最低系统行为。

ad-hoc 或本地开发签名不能用于提交公证。Apple Developer Program 当前标准价格为每会员年度 99 美元（不同地区会以当地价格为准）；符合条件的组织可以申请免除会费。

## 无付费会员测试包的控制措施

- 从有 tag、可复现的 commit 构建；在 DMG 旁公布 commit SHA 与 SHA-256 校验值。
- 继续启用 App Sandbox、用户自选位置只读权限、app-scoped bookmark 与 Hardened Runtime。
- 所有文件组装完成后再对最终 App bundle 做 ad-hoc 签名；使用 `codesign` 验证，并从一次全新下载、带 quarantine 的 DMG 测试启动。
- 清楚说明“仍要打开”的准确步骤，并说明 macOS 无法验证发布者身份或公证状态。
- 绝不能把产物称为“已签名并公证”或“Apple 已验证”。
- 每个重新下载的新构建都要当成新的资格验证对象。

## SpaceTrace 特有的发布风险

当前 Sandbox 资格测试只证明：同一个 ad-hoc 签名二进制在重启后能够恢复目录权限。它还没有证明 app-scoped security bookmark 在换成另一次独立构建、同样采用 ad-hoc 签名的版本后仍能连续恢复。在提供任何测试 DMG 前，必须执行更新矩阵：全新安装、同构建重启、替换构建、stale bookmark、主动撤权、外置卷返回与重新授权。如果签名身份连续性不稳定，发布说明必须明确告知：更新后可能需要用户重新选择目录。

## Apple 官方参考

- Apple Developer：[Developer ID certificate](https://developer.apple.com/help/glossary/developer-id-certificate/)
- Apple Developer：[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- Apple 支持：[打开来自身份不明开发者的 Mac App](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)
- Apple Developer：[Program enrollment](https://developer.apple.com/programs/enroll/)
