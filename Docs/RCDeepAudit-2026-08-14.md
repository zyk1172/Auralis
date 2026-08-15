# Auralis Release Candidate Deep Audit（2026-08-14）

> 历史文档说明：本文档为 RC 稳定化期间的历史审计记录，品牌名称为「澜音」；品牌已更名为 **Auralis**，文中品牌名引用已同步更新。

基线：`8f101de`（main 合并点）。分支：`codex/rc-final-audit`（提交 `f086f40`、`3e3cca7`、`b7b8867`、`815766c`）。
原则：稳定性 > 数据正确性 > 播放正确性 > 性能 > UI 细节。所有真机项目以 `MANUAL-VERIFY` 标注，不伪造 PASS。

## Release Blockers Found（已修复）

| # | 问题 | 根因 | 影响平台 | 修改文件 | 修复方式 | 测试方式 |
|---|---|---|---|---|---|---|
| RB-1 | 真实设备循环/无缝切歌不可靠 | `DidPlayToEnd → Task.yield() → 猜 currentItem`，E1/E2 到达顺序不确定，双重推进/漏推进 | 全平台 | `AVFoundationPlaybackEngine.swift`、`PlayerItemBoundaryCoordinator.swift` | 确定性边界状态机：currentItem KVO 为权威；E2 先到直接过渡、E1 先到 waiting + 有界兜底；prepared 失败/超时只触发一次 trackEnded；事件 item 校验防迟到通知 | 协调器 9 项测试 + `AURALIS_RUN_AV_TESTS=1` 真实 AVQueuePlayer 测试 + RC-1 真机 |
| RB-2 | 切服务器后播放条显示旧服务器曲目，点播放用新服务器解析旧 TrackID | `switchedServer` 未重置 currentTrack；`resolvePlayableTrack` 无服务器守卫 | 全平台 | `AuralisAppModel.swift` | 切换时重置 currentTrack 并取消预载；resolvePlayableTrack 对非活动服务器只允许本地缓存/既有 URL | `PlaybackPolicyRegressionTests`（GlobalID 用例） |
| RB-3 | Live Activity / 灵动岛 / 小组件从未被驱动 | 只有声明，无 `Activity.request/update`，也未写 `playback-snapshot.json` | iOS | `LiveActivityManager.swift`、`AuralisAppModel.swift` | 首次播放请求、5s 节流更新、停止/队列结束/移除服务器时结束；每次播放状态变化写小组件快照 | RC-4 真机 |
| RB-4 | 下载等待地址期间切服务器，新服务器音频写入旧服务器缓存槽 | `DownloadStore.download` 只按 GlobalID 令牌去重，未校验服务器 | 全平台 | `AppDomainStores.swift`、`AuralisAppModel.swift` | 等待结束后校验 `serverIDProvider() == track.serverID`，不一致取消并标记失败 | 真机/真实 NAS（RC-5） |
| RB-5 | 控制中心被旧曲目信息回写 | `updateProgress` 读 MPNowPlayingInfoCenter 后异步回写，切歌竞态 | iOS/macOS | `NowPlayingCoordinator.swift` | 基于缓存 `lastInfo` 只改 elapsed/rate，不再读系统中心 | RC-1 控制中心一致性 |

## Playback

**根因**：旧实现用一次 `Task.yield()` 猜 AVQueuePlayer 是否已推进；「播完事件」与「currentItem 变化」两个回调到达主线程的顺序不保证。猜错 → 走 `trackEndedHandler → selectAndPlay` 重建播放器，而 AVQueuePlayer 又自动推进到 prepared item，形成双重推进（或漏推进、循环失效）。

**新实现 exactly-once**：`PlayerItemBoundaryCoordinator` 状态机消解顺序不确定——
- `itemEnded(hasPrepared:currentItemIsPrepared:)`：无预载 → `[.handleTrackEnded]`；已推进 → `[.completeTransition]`；未推进 → `waiting`；
- `currentItemChanged(newItemIsPrepared:)`：仅 waiting 且匹配 → `[.completeTransition]`；
- `preparedFailed()` / `fallbackTick()`：waiting 中 → `[.removePrepared, .handleTrackEnded]`（只一次）；
- 同一边界不可能同时输出 completeTransition 与 handleTrackEnded；重复结束事件去重；`endObservedItem` 校验拒绝迟到通知。

引擎侧：DidPlayToEnd 有预载时不再立即回调 trackEnded；prepared 推进后只更新引擎/模型，不重建播放器（保留 gapless）；prepared 失败在推进前移除并按契约只回调一次。repeat one / repeat all / shuffle 语义仍在 AppModel 统一决策（引擎只负责音频与边界事件）。

## iPhone / iPadOS / macOS

- **共用**：所有播放策略统一在 `AuralisAppModel`；异步身份 GlobalID 化（重试预算、seek、预载、歌词、评分、切服守卫）。
- **iPhone**：传输控制 ≥44pt 且带 label；双击事件队列守卫；sheet 仲裁。
- **iPad**：`PadMusicShell` sheet 由 `PadPresentationArbitration` 统一仲裁（serverSetup > nowPlaying > browse），14 个目的地触控目标 ≥44pt。（已废弃：RC 收敛后 iPad 与 iPhone 共用统一 iOS Shell `IOSMusicShell`，`PadMusicShell` / `PadPresentationArbitration` 已删除，本文档为历史记录。）
- **macOS**：Expanded Player 标题栏幂等 `MacExpandedChromePolicy`（左上角绝无“Auralis”）；Collapse 恢复 titlebar/traffic lights；菜单命令与 Space/←/→/Esc 统一 firstResponder 守卫（文本编辑不误触）。
- **Siri/Spotlight/Handoff**：显式播放允许 disliked；自动发现排除 disliked；ID 均 serverID+remoteID；Handoff 不传 repeat/shuffle（接收端保持本机设置）；Siri/快捷指令文案已本地化（en）。

## Persistence / Cache / Downloads / System Integration / Performance / Accessibility

- **Persistence**：单一 `LocalCatalogStore`；`quick_check` 时间策略；无 20k 上限（Agent 工具已移除）；`library.json` 仅账号。
- **Cache**：Artwork 有界；LyricsDiskCache 64MB 字节预算 + 负缓存上限。
- **Downloads**：身份全链路 GlobalID；切服放弃保护；失败持久化/重试/取消/删除一致。
- **System Integration**：Live Activity/小组件已接通；NowPlaying 进度更新不回写旧曲目。
- **Performance**：进度 tick 合并；position 不重建歌曲列表；Expanded 不重排 titlebar。
- **Accessibility**：主播放控制 ≥44pt 带 label；Siri/AppIntents 文案本地化。

## Remaining MANUAL-VERIFY（真机清单，见 Docs/ManualValidation.md RC 章节）

- RC-1：repeat one ≥3 次 / repeat all ≥2 圈 / 队尾 C→A 无缝 / shuffle 矩阵 / 后台 30 分钟循环
- RC-2：Mac Expanded 30 次展开收起 + 全屏 + 键盘编辑不误触
- RC-3：iPad Browse/NowPlaying/服务器设置 sheet 互斥
- RC-4：灵动岛 / 锁屏 / 小组件真机行为
- RC-5：真实 NAS 断线 → 流失败策略；切服身份；下载切服放弃

另：`AURALIS_RUN_AV_TESTS=1 swift test --filter AVFoundationPlaybackEngineBoundaryTests` 在会驱动 AVPlayer run loop 的环境运行（swift test 默认不驱动，按审计规定跳过并标注）。

已知非阻断：Siri/AppIntents 文案本地化已做（zh-Hans 源 + en）；LyricsDiskCache 为大小预算而非严格 LRU；macOS「分类」崩溃为既往未复现项，当前实现已用 GlobalID 选择 + cleanedSelection + flat cards 结构性消除该崩溃类。

## Release Verdict

**READY FOR DEVICE VALIDATION**（不是 READY FOR RELEASE）。

代码层面：swift test 全量通过（202 AppShellTests 含新增 14+9+4+8、218 AgentKitTests）、Mac build PASS、iOS generic build PASS、未使用模拟器、未伪造真机数字。按审计要求，真实设备循环播放/灵动岛/标题栏视觉验证须在真机完成后方可宣布 READY FOR RELEASE。
