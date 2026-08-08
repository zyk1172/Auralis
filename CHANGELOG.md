# Changelog

## 0.3.5 — 2026-08-08

### Added

- Agent 新工具 `music_download`（Music Download）：接入 MovipNote（MoviePilot）音乐下载插件
  - 设置新增「音乐下载（MovipNote）」区块：服务器地址（UserDefaults）+ 调用 Token（Keychain）+ 连接测试
  - action=search：跨站搜索音乐资源（音乐/影视判别 + 无损优先排序 + 相关度），返回候选与 `album_matched_any`
  - action=download：按 ref / site_id+index / magnet 提交下载到 NAS 音乐目录；失败自动提示换候选重试
  - action=tasks：查询下载进度
  - 决策规则写入 Agent 提示词：专辑未命中禁止自动下载（只展示候选让用户选）、中文专辑需英文别名、单曲退艺人搜索
  - 触发场景：用户点播本地/服务器都没有的歌曲、或直接要求下载某歌/专辑

## 0.3.4 — 2026-08-06

### Fixed

- 修复 iOS 构建失败（3 个错误 + 7 个警告）：
  - `AuralisSystemToolService`：`AVAudioSession.Port` 无 `airPlayDevice` 成员 → 改用 `.airPlay`；
    移除多余 `await CrashLog.shared.recent`。
  - iOS 26 SDK 已移除 `.activityConfiguration` View modifier（Live Activity 自定义 UI 改走
    Widget extension）：移除自定义 Live Activity 代码（NowPlayingLiveActivity.swift、
    RootView 的 activityConfiguration/DynamicIsland 内联），灵动岛改为依赖系统自动紧凑媒体控制
    （iOS 17.1+ 活跃音频会话 + MPNowPlayingInfoCenter 自动在灵动岛显示，无需额外代码）。
    控制中心 / 锁屏展示与切歌即时更新逻辑保持不变。
  - 移除 Live Activity 时误删的 `currentLyrics` / `currentClassification` 已恢复。
  - `AppIntents.swift`：18 处 `static var title/description` 改为 `static let`
    （Swift 6 非隔离全局可变状态）；`AuralisPlaySongIntent.song` 不再作为 AppShortcut 短语
    参数插值（iOS 26 仅允许 AppEntity/AppEnum），改用 `requestValueDialog` 运行时询问歌曲名。
  - 7 个既有编译警告清零：`endObserver` 从 Sendable 闭包移入 @MainActor Task；
    `allowBluetooth` → `allowBluetoothHFP`；音频会话 completion 闭包标注 `@Sendable`。
- project.yml：AuralisIntents 扩展关闭 AppIntents 元数据提取（该扩展为 Siri Intents 扩展，
  不包含 AppIntents，避免 metadata 处理器提示）。

## 0.3.3 — 2026-08-06

### Added

- 控制中心 / 锁屏 / 灵动岛：
  - 修复「控制中心看不到」：切歌时在 engine.play 之前就先同步 MPNowPlayingInfoCenter
    （歌曲信息立即显示，即使还在缓冲），播放成功后刷新进度；补 `MPNowPlayingInfoPropertyDefaultPlaybackRate`。
  - 新增灵动岛支持（Live Activity / ActivityKit + WidgetKit）：锁屏横幅 + 灵动岛
    （封面、标题、艺术家、进度、队列位置、播放/暂停）；切歌启动、进度 2 秒节流更新、
    暂停/继续即时更新、清空队列/移除服务器时结束。Info.plist 开启 NSSupportsLiveActivities。
- Agent 工具系统（第一阶段统一命名工具，40 个全部接入真实服务）：
  - App/设备：app_get_context、app_open_page、app_get_feature_status、device_get_network_status、
    device_get_audio_route、device_get_storage_status
  - 服务器：server_list、server_get_current、server_test_connection（真实 API 请求）、
    server_get_capabilities、server_sync_status
  - 本地库：library_get_summary、library_search（统一搜索歌曲/专辑/艺术家/歌单，支持
    limit/onlyFavorites/onlyOffline）、library_get_song/album/artist/playlist、
    library_get_recently_played、library_get_starred、library_get_random_songs、library_get_similar_songs
  - 播放：playback_get_state、playback_play_song/album/artist/playlist、playback_pause/resume/
    next/previous/seek、playback_set_shuffle、playback_set_repeat
  - 队列：queue_get、queue_append、queue_play_next（插入当前歌曲之后）
  - 收藏/歌单/歌词/下载/缓存/统计/诊断：favorite_set（歌曲/专辑/艺术家）、playlist_create、
    playlist_add_songs、lyrics_get、media_download_offline、cache_get_status、
    stats_get_listening_summary、diagnostics_playback、diagnostics_get_recent_errors
  - 统一框架：`AgentSystemService` 协议（结构化、脱敏输出）、`SystemToolExecutor`（统一结果 +
    参数校验 + 错误处理）、`AgentToolRegistry` 扩展、`AgentToolkit.executeV2` 路由、
    `AgentRunner.run` 新增 `systemService` 参数；AgentBridge 新增 setShuffle/setRepeatMode。
  - 安全：所有返回不含密码/Token/完整认证 URL/文件路径；server_test_connection 只回主机名与结果；
    server_get_capabilities 返回真实能力（不支持不伪造成功）。

### Fixed

- AI 助手可调用 40 个新工具并真实执行；系统服务工具无服务实例时返回「系统服务不可用」而非伪造成功。

## 0.3.2 — 2026-08-06

### Added

- 播放会话持久化：当前曲目、播放队列、队列顺序与播放位置按服务器隔离保存
  （UserDefaults，键 `auralis.playbackSession.<serverID>`）；进程被系统终止后重启，
  先展示本地资料库并从本地恢复上次队列与进度（恢复为暂停，不自动出声），
  用户点击播放后从该进度继续。切歌/改队列/拖动进度/播放状态变化均落盘，
  进度以 2 秒节流写入。
- 最近播放记录按服务器隔离：改用「serverID:trackID」组合键存储，切换服务器后
  两台服务器同 ID 歌曲不再混在一起（旧格式数据自动丢弃）。
- Siri 意图引擎大幅增强：支持「播放指定歌曲/艺术家/专辑/歌单/收藏/最近/随机/流派」
  与「暂停/继续/上一首/下一首/切换随机/切换循环」；全部优先使用本地持久化资料库
  匹配，唯一匹配直接建队列播放，多匹配按类型与文本相似度选择最接近的结果，
  找不到明确匹配时不随意播放错误内容。
- 快捷指令（AppIntents）：新增 `Apps/iOS/AppIntents.swift`，提供播放/暂停、上一首、
  下一首、播放收藏、播放最近、播放随机、切换随机、切换循环、播放指定歌曲 9 个
  快捷指令；所有意图经 `AuralisAppModel.shared` 与界面共用同一个播放服务。
- `AuralisAppModel.shared` 全局共享实例：Siri / 快捷指令 / 页面操作统一入口，
  保证控制中心、锁屏、迷你播放器状态一致。
- 主题名称全部中文化（Aurora Glass→极光玻璃、Midnight OLED→午夜 OLED、
  Analog Hi-Fi→模拟 Hi-Fi、Cyber Pulse→赛博脉冲、Minimal Paper→极简纸张、
  Album Adaptive→专辑自适应、Neon City→霓虹都市、Zen Nature→禅意自然）。

### Fixed

- AI 助手「发送按钮没有反应」：`AgentCoordinator.send` 在无活动会话时静默 return。
  现在没有会话会自动新建会话再执行 Agent 循环。

## 0.3.1 — 2026-08-06

### Fixed

- AgentKit 测试编译失败：`AgentRunner.run` 新增 `model:` 参数、`AgentRunner.Context`
  扩展统计字段后，AgentKitTests 未同步更新导致整个测试目标无法编译（表现为「测试经常失败」）。
  修复：`Context.init` 全部参数改为带默认值；测试 7 处 `run` 调用补 `model:`。AgentKitTests
  13/13、ApplicationTests 5/5 通过。
- 收藏与服务器不同步：首次连接/冷启动从不拉取服务器收藏（getStarred2），本地 star/unstar
  只改内存不落盘，重启后收藏全部丢失。修复：连接与恢复流程把服务器收藏合并进曲目 isFavorite，
  收藏集合随辅助缓存落盘，star/unstar 成功后即时更新缓存，后台刷新以 getStarred2 为准回流。
- 歌单与服务器不同步：歌单编辑只改内存、冷启动恢复的是旧缓存、后台刷新无法反映服务器侧
  增删改名。修复：歌单写操作（新建/改名/加歌/删歌/重排/删除）成功后刷新本地缓存歌单；
  加载歌单详情后把最新曲目列表写回缓存；后台刷新以服务器歌单为基准合并（保留本地已加载的
  详情曲目，避免列表闪空）。

## 0.3.0 — 2026-08-04

### Added

- 播放页重构：循环模式（关/列表循环/单曲循环）、五键等宽对称传输区（循环 | 上一首 |
  播放 | 下一首 | 队列）、标题旁收藏心形、音量控制行；下载与添加到歌单收进「更多」菜单。
- 本地缓存：歌曲可下载到本地（Application Support/Auralis/TrackCache），已缓存歌曲优先
  本地播放；列表显示已下载标识，菜单可删除缓存。
- 添加到歌单：播放页与歌曲菜单可把歌曲追加到服务器歌单（updatePlaylist）。
- 收藏（喜爱）实时同步到服务器（star/unstar）。
- 首页新增歌单 / 收藏 / 最常听入口；本地播放次数统计持久化，最常听按次数降序。
- 主题改为下拉框选择；新增云村红、黑胶之夜、蜜桃粉雾、深海蓝调四款主题（灵感来自网易云音乐）。
- App 图标（iOS 与 macOS 共用 1024 单图源）。

### Fixed

- iOS 上「配置接口」点击无反应：AI 接口与 API Key 配置在 iOS 改为整页推入，不再依赖
  Form 内的 sheet 呈现。

## 0.2.0 — 2026-08-04

### Added

- 按需服务器歌词：切歌时通过 `getLyricsBySongId` 拉取并缓存，播放页与检查器同步高亮。
- 按需服务器封面：`getCoverArt` 按显示尺寸请求、内存缓存，全端列表/播放页/首页接入，
  缺失时回退渐变占位组件。
- 恢复上次连接时重建认证客户端并补齐播放地址，重启后可直接播放与加载歌词封面。
- 专辑/艺术家详情弹窗增加封面头部与显式「播放全部」入口，点选单曲才播放。
- OpenAI 兼容接口改为弹窗配置，设置页只保留摘要。

### Removed

- Demo 模式全面移除：Demo 曲库、Demo 播放引擎、合成音调、Demo 歌词/封面/资料库仓库、
  「切回 Demo」及全部 Demo UI 标识。测试夹具迁移到 TestSupport（TestCatalogFactory）。
- 无播放地址的歌曲现在显式报错，而不是静默播放合成音。

### Fixed

- 首页「继续聆听」的播放与打开播放页按钮固定单行排列。
- `OpenSubsonicClientTests` 中带关联值错误的 `#expect(throws:)` 断言修复。

## 0.1.0 — 2026-08-04

### Added

- Native iOS/iPadOS and macOS application targets with Swift 6 strict concurrency.
- Local multi-module `AuralisCore` package and one-direction dependency boundaries.
- Deterministic Demo catalog with 20 artists, 30 albums, 200 tracks, lyrics, history, downloads,
  classifications and recommendations.
- iPhone tab shell, iPad/macOS three-column shell, mini player, now-playing pages and inspector.
- Eight token-driven built-in themes with accessibility-aware motion/transparency hooks.
- OpenSubsonic endpoint/capability abstractions, queue actor, metadata overlay, AI Provider/SSE,
  hybrid recommendation, cache policy and tests.
- Architecture, privacy, testing, metadata, theme and open-source audit documentation.

### Known limitations

- Phase 0 uses a non-audio Demo playback engine; real networking, persistence, playback, downloads,
  Keychain provider credentials and AI requests are scheduled for later phases.
