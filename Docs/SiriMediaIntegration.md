# Siri 音乐播放集成（Auralis）

本文记录 Auralis 被 Siri 识别为第三方音乐播放器所需的配置、调用链路、签名前提与真机验证方法。
所有结论均来自 Apple 官方文档与本地构建产物的实测结果，不含任何私有 API 或签名绕过手段。

## 1. 三种彼此独立的机制

| 机制 | 决定什么 | Auralis 现状 |
| --- | --- | --- |
| SiriKit 媒体域（`INPlayMediaIntent`） | 用户说「播放音乐」时，Siri 的 **App 选择列表**里有谁；点选后由谁播放 | 已配置（本文第 2 节） |
| App Shortcuts（`AppShortcutsProvider`） | 用户说「Auralis 播放音乐」这类**带 App 名**的短语 | 已实现（`Apps/iOS/AppIntents.swift`） |
| Apple Intelligence 音频 Schema（`.audio.playAudio` + `IntentValueQuery`） | iOS 26+ 的 Siri AI 走 App Intents 语义层 | **未实现**，见第 6 节 |

「快捷指令能执行」≠「被 Siri 注册为音乐播放器」。前者只需要 `AppShortcutsProvider`，
后者要求 Intents 扩展正确声明媒体类别并真实加载成功。

## 2. 必需的配置

### Intents 扩展（`AuralisIntents`）

`Apps/iOS/Intents/Info.plist`：

```xml
<key>NSExtensionPointIdentifier</key><string>com.apple.intents-service</string>
<key>NSExtensionPrincipalClass</key><string>$(PRODUCT_MODULE_NAME).IntentHandler</string>
<key>NSExtensionAttributes</key>
<dict>
  <key>IntentsSupported</key>
  <array><string>INPlayMediaIntent</string></array>
  <key>SupportedMediaCategories</key>
  <array><string>INMediaCategoryMusic</string></array>
</dict>
```

两个关键点：

- `NSExtensionPrincipalClass` **必须**带模块前缀。Swift 类的 ObjC 运行名是
  `AuralisIntents.IntentHandler`（二进制里为 `_TtC14AuralisIntents13IntentHandler`），
  只写 `IntentHandler` 会让 `NSClassFromString` 返回 nil，扩展启动即抛
  `Extension's principal object should not be nil`。
- `SupportedMediaCategories` 缺省时系统不知道本 App 支持哪种媒体，媒体域不会把
  Auralis 列进音乐 App 候选。

### 主 App（`Auralis`）

- `Info.plist`：`INIntentsSupported`、`INSupportedMediaCategories`（iOS 14+ 的 App 侧声明）、
  `NSSiriUsageDescription`、`NSUserActivityTypes = [INPlayMediaIntent]`（冷启动交付 continueInApp）。
- `Auralis.entitlements`：`com.apple.developer.siri = true`。

### 签名前提（硬性）

`com.apple.developer.siri` 必须能在描述文件中生效：App ID 上要开启 **Siri** capability。
免费 Apple ID（Personal Team，描述文件 `TimeToLive = 7`）通常无法启用该 capability，
此时带 entitlement 的构建会在签名阶段失败。这是账号能力限制，不是代码问题，
无法通过修改 Info.plist 绕过。

## 3. 调用链

```
Siri「用 Auralis 播放…」
  → INPlayMediaIntent
  → AuralisIntents.IntentHandler.resolveMediaItems()
       ├ 无具体查询 → 返回占位项 identifier = auralis-play-all
       └ 有查询     → 读 App Group 共享 SQLite（Auralis/catalog.sqlite），
                      命中项 identifier = "serverID:remoteID"
  → handle() 返回 .continueInApp
  → 系统拉起 Auralis，交付 activityType = INPlayMediaIntent 的 NSUserActivity
  → AuralisRootView.onContinueUserActivity → AuralisAppModel.handleSiriUserActivity
  → processSiriPlayRequest() → executeSiriIntent() → 同一个播放服务
```

扩展不持有 AVPlayer，也不维护第二套播放状态；播放一律落在主 App 的 `AuralisAppModel`。

「暂停 / 下一首」不走 SiriKit：Auralis 是当前 Now Playing App 时，由
`MPRemoteCommandCenter`（`SystemMediaIntegration/RemoteCommandCoordinator.swift`）处理。

## 4. App Group

扩展与主 App 必须都能拿到 `group.com.auralis.player`。扩展在打开数据库前会显式检查容器；
容器不可用时记录 `siri-intents` 分类的错误日志并返回「不支持」，不会静默假装搜索成功。

## 5. 真机验证步骤

1. 确认签名：Xcode → Target Auralis → Signing & Capabilities 中存在 **Siri**；
   `security cms -D -i <profile> | grep -A1 developer.siri` 应能查到该键。
2. 冷启动 App 一次，连接服务器并完成一次同步（否则共享资料库为空，Siri 只能回「播放音乐」）。
3. 设置 → Siri 与搜索 → Auralis 已出现在 App 列表且开关为开。
4. 长按侧边键说「播放音乐」，在 App 选择列表中确认出现 Auralis。
5. 依次验证：「用 Auralis 播放音乐」/「用 Auralis 播放 <歌名>」/「用 Auralis 播放 <歌手> 的歌」/
   「用 Auralis 播放我的收藏」/ 播放中「暂停」/「下一首」/ 杀掉 App 后重试 / 锁屏状态重试。

### 故障分层判定

| 现象 | 判定 | 排查 |
| --- | --- | --- |
| 选择列表里根本没有 Auralis | 系统没把它当作媒体 App | 检查扩展 `SupportedMediaCategories`、`com.apple.developer.siri`、App ID capability |
| 列表里有，点选后 Siri 说「应用处理失败」 | 扩展没能加载 | Console 过滤 `AuralisIntents`，找 principal object / crash；核对 `NSExtensionPrincipalClass` |
| 扩展加载了但说「找不到」 | 媒体解析失败 | 看 `siri-intents` 日志：App Group 不可用 / 资料库为空 / 查询无匹配 |
| 拉起 App 但没有声音 | 主 App 侧播放失败 | 看 `siri` 分类日志（资料库为空、GlobalID 未命中）与播放引擎诊断 |

日志来源：`subsystem = com.auralis.player.ios`，category `siri-intents`（扩展）或 `siri`（主 App）。

## 6. 尚未实现：Apple Intelligence 音频 Schema

iOS 26+ 提供 `.audio.playAudio` 意图 Schema 与 `.audio.song` 实体 Schema，
配合 `MediaIntents.AudioSearch` 的 `IntentValueQuery` 可让 Siri AI 直接按语义取内容。
当前 SDK（iOS 27.0）中 `@AppIntent(schema: .audio.playAudio)` 只注入 schema 标记，
不生成参数（参数契约文档未公开完整类型），缺少官方样例时无法验证实现是否正确，
因此本仓库暂不实现——避免出现「看起来接入了、实际不生效」的死代码。
SiriKit 媒体域仍是第三方音乐 App 进入选择列表的有效机制。
