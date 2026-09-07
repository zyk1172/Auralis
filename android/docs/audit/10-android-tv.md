# 10 · S9 Android TV（app-tv）审计：Swift 规格核对 + 能力盘点

> 阶段：S9 Android TV。范围：`android/app-tv`（Leanback 壳）从占位骨架推进到
> 「浏览 → 播放 → 队列/歌词 → 设置」主链路可在 TV（D-pad）操作。
> 结论先行：**Swift 工程不存在 tvOS/Apple TV target**，故 Leanback 壳不直接对齐
> Swift 界面；对齐基准 = 移动端核心能力（S1–S8 已建）+ Android TV 交互惯例，
> 策略 = **Shell 层重写（TV 观感）、页面层零改动复用 feature Composable**。

## 1. Swift 侧是否有 tvOS 规格（核对结论）

核对来源：`Auralis.xcodeproj/project.pbxproj`、`Packages/AuralisCore/Sources/AppShell/`。

1. **Xcode target 清单**：工程内仅两个 application target —— `Auralis`
   （SDKROOT=`iphoneos`，TARGETED_DEVICE_FAMILY=`1,2` = iPhone/iPad）与 `AuralisMac`
   （SDKROOT=`macosx`）。`SUPPORTED_PLATFORMS` 只出现 `iphoneos iphonesimulator`。
   **无 tvOS SDKROOT / `com.apple.product-type.application` tvOS 变体 / TV 扩展 target。**
2. **变体目录**：`AppShell/Mac/`（Shell/Detail/Library/MiniPlayer/Player/Search/Utility +
   MacServerPage/MacSettingsWindow）确认 macOS 变体存在；**不存在** `AppShell/TV/`、
   `AppleTV` 或任何 `#if os(tvOS)` 源文件（全仓搜索命中仅 `.build/` 派生产物，
   属测试入口 boilerplate，非业务代码）。
3. **推论**：移动端视图族（HomeView/LibraryView/SearchView/PlayerViews/SettingsView…）是
   iOS 单一代码库 + Mac 条件变体，未派生 tvOS 版。Android 侧对应关系：
   app-mobile ≈ iOS+Mac 变体聚合，**app-tv 无 Swift 界面可逐像素对齐** →
   「Leanback 壳不直接对齐 Swift」，对齐基准改为移动端核心能力 + Android TV 惯例。

## 2. app-tv 现有骨架盘点（实施前基线）

1. **模块注册**：`settings.gradle.kts` 已 `include(":app-tv")`；`build.gradle.kts`
   已依赖全部 core（common/domain/opensubsonic/data/playback/offline/designsystem/image/
   lyrics/security）与 feature（home/library/player/search/settings/server）；
   **刻意不含 feature:assistant 与 core:ai**（TV 不装 AI 助手）。
2. **组合根**：`AuralisTvApp : Application` 已装配与移动端共用的 `AuralisGraph`（install）。
3. **Manifest**：INTERNET/NETWORK_STATE/FOREGROUND_SERVICE(_MEDIA_PLAYBACK)/
   POST_NOTIFICATIONS/WAKE_LOCK 已声明；`AuralisPlaybackService`
   （`androidx.media3.session.MediaSessionService`）已注册 → TV 上系统可接管媒体
   播放/暂停/切歌（MediaSession 与 Android TV 惯例一致）；`TvMainActivity` 带
   MAIN/LAUNCHER/**LEANBACK_LAUNCHER** + banner（占位系统图标）。
   **缺口**：`uses-feature leanback/touchscreen` 声明、本地 banner/app icon（现用
   `@android:drawable/ic_media_play`）、`banner` 尺寸规范。
4. **Activity**：`TvMainActivity` = Compose + AuralisTheme + `TvPlaceholder` 占位文本，
   **无导航/无页面** —— 本次替换点。
5. **此前编译痕迹**（build/ 存在）说明骨架曾通过 assembleDebug；当前为陈旧产物。

## 3. 可复用能力盘点（移动端已交付，TV 直接复用）

feature 层页面全部是「`graph: AuralisGraph` 为首参 + 行为回调」的**自包含 Composable**
（自身持有 State + 真实读写），TV 壳只传 graph 与导航回调即可复用，页面层零改动：

| 能力 | 公开 Composable | TV 用途 |
|---|---|---|
| 首页 | `HomeScreen(graph, onPlayTracks, onBrowse, onManageServers)` | 首页分区（快捷入口/模块货架/换一批/统计） |
| 音乐库 | `LibraryScreen(graph, onOpenSettings, onPlayTracks, onPlayNext, onAppendToQueue, onBrowse)` | 音乐库分区（专辑/艺术家/歌单/歌曲 scope） |
| 浏览详情 | `BrowseDetailScreen(graph, initial, onBack, onPlayTracks, onPlayNext, onAppendToQueue)` | Browse 覆盖页（含内部返回栈） |
| 正在播放 | `NowPlayingScreen(graph, controller, onClose, onOpenBrowse)` | Now Playing 全屏覆盖（Player/Queue/Lyrics tabs） |
| 搜索 | `SearchScreen(graph, onBack, onPlayTracks, onBrowse)` | 搜索分区（本地 + 服务器在线） |
| 设置 | `SettingsScreen(graph, onBack, onOpenServers, onEditHomeLayout, onOpenAiSettings)` | 设置 Route（根页+Quality/Data/Theme 子页内建） |
| 服务器 | `ServerListScreen / ServerFormScreen`（feature:server） | Boot 无服务器流程 / 管理 |
| 首页布局编辑 | `HomeLayoutEditScreen(graph, onBack)` | 设置内「首页布局」真实入口 |
| AI 连接设置 | `AiSettingsPage(graph, onBack)` | 设置内 AI 行入口（仅连接/Key/授权配置，**非** Assistant UI） |

- 组合根 `AuralisGraph`：`graph.startPlaybackService()`（幂等，未就绪时先启服务）、
  `graph.preferences`、`graph.catalogRepository` 等移动端同面。
- 播放：`core:playback` `LocalPlaybackHost.available/controller()`（进程内引擎单例）+ 已注册
  PlaybackService。TV 无需新播放设施。
- 播放回调模式（app-mobile `MobileShell` 已验证，TV 壳照搬语义）：
  `playShelf(engine 未就绪→startPlaybackService 并返回，不假装播放；就绪→playQueue from index)`、
  `playNextShelf→insertNext`、`appendQueueShelf→appendToQueue`、`openBrowse(切 Library + 覆盖)`、
  覆盖层 BackHandler 优先级（NowPlaying > Search/Browse）。

## 4. D-pad / TV 输入适配盘点（对既有 Compose UI 的影响评估）

1. **可聚焦性**：Compose 的 `clickable`/Button/IconButton/卡片默认可聚焦；D-pad 方向键在
   可聚焦项间移动；LazyColumn/LazyRow 在焦点移出视口时自动滚动（Foundation 内置
   bringIntoView）→ 既有列表/货架 TV 上可导航。
2. **焦点可见性（主要缺口）**：M3 `clickable` 的 ripple 仅在按下/悬停时可见，TV 遥控
   移动焦点时**没有可见指示** → 必须提供 TV 焦点环。零侵入方案：在 TV Activity
   以 `CompositionLocalProvider(LocalIndication provides TvIndication)` 全局替换
   indication（`clickable` 默认读 `LocalIndication.current`）→ 复用页面 item 全部获得
   accent 描边焦点视觉，**不改 feature 层**。
3. **TV 特有声明**：`<uses-feature android:name="android.software.leanback"
   android:required="false"/>`（配合 LEANBACK_LAUNCHER 上架）；`android.hardware.touchscreen
   required=false`（非触屏设备可安装）。
4. **Insets**：TV 无状态栏/导航栏 → feature 页面的 `statusBarsPadding()`/
   `navigationBarsPadding()` 按 0 inset 计算，无副作用。
5. **尺寸**：复用页面控件为触摸尺寸（IconButton 48dp、行高约 56dp），TV 上聚焦可用但偏小；
   记录为后续迭代（不阻塞主链路跑通目标）。自有 TV 控件（顶栏导航/播放条）按 TV 惯例放大。
6. **搜索输入**：`SearchScreen` 文本输入在 TV 弹系统 IME（遥控器软键盘），可用。
7. **不引入** androidx.leanback（legacy Fragment+BrowseFragment 体系与 Compose 互斥）与
   androidx.tv:tv-material（新增依赖面）；纯 Compose 实现壳与焦点，保持依赖收敛。

## 5. S9 范围决策

**页面集合（无 Assistant 的浏览/播放主链路）**：
1. `TvShell`：左/顶导航 —— 一级分区 **首页 / 音乐库 / 搜索**（移动端搜索藏在 Assistant
   分区内；TV 无 Assistant → 提升为一级，符合 Android TV 惯例，且对应 Swift `SearchView`
   实体存在）+ **设置**入口；有播放时底栏常驻 Now Playing 条（点击 → 全屏 NowPlayingScreen）。
2. Boot 流程对齐移动端：无服务器 → `ServerListScreen`（add/edit/form 复用）→ 进入 TvShell。
3. 设置 Route：复用 `SettingsScreen`；`onEditHomeLayout → HomeLayoutEditScreen`、
   `onOpenAiSettings → AiSettingsPage`（**配置面保留**：API Key/外发授权属账户安全，
   且 TV 不装 Assistant 会话 UI，两者不冲突）、`onOpenServers → ServerListScreen`。
4. Browse 详情覆盖语义同移动端（切音乐库分区 + 覆盖页，内部返回栈）。
5. 焦点：`TvIndication`（accent 描边 2dp + 轻微放大/圆角），自有控件显式
   `focusable` + 同款视觉；分区高亮 = 选中态 accent 底。
6. 播放服务已注册 → TV 遥控媒体键/系统媒体面板经 MediaSession 可用（无额外代码）。

**验证**：`:app-tv:assembleDebug` 编译零新增告警 → 安装到 TV 模拟器（Android TV
API 34 x86_64）→ D-pad 走通 首页→播放→NowPlaying(播放/暂停/切歌/队列/歌词)→搜索→
服务器管理→设置 链路；每按钮真实动作（沿用硬性规则）。

**不做（如实列为后续迭代）**：10ft 大卡片主页/详情重设计、语音搜索集成、
MediaSession 外部控制器深度定制、TV 端 Assistant、DRM/视频能力（纯音频 App）、
遥控器播放速度/HDMI-CEC 等系统集成。

## 6. 与 Swift 的语义对照说明

- app-tv ≠ 任何 Swift target；其 UI 决策引用两个基准：
  a) **移动端核心能力**（S1–S8 已逐 Swift 对齐的 feature 页面原样复用 → 语义自动继承）；
  b) **Android TV 惯例**（Leanback launcher、MediaSession 系统接管、D-pad 焦点环、
     无 Assistant 分区、搜索提为一级）。
- 记录于 `platform-decisions.md` §2n；`parity-status.md`/`ui-parity.md` 补 S9 段。
