# Auralis macOS 平台审计（当前真实架构）

> 核对日期：2026-08-13（macOS 27 Beta 5 / Xcode 27 Beta / Swift 6 Strict Concurrency Complete / Warnings As Errors）
> 本文件只描述当前源码中的真实架构，不保留任何历史架构描述。

## 1. 窗口拓扑

| 场景 | 结构 |
| :--- | :--- |
| 主窗口 | `WindowGroup`，min 900×600，default 1280×820 |
| 迷你播放器 | 独立 `Window("迷你播放器", id:)`，`defaultPosition(.bottomTrailing)`，共享 `AuralisAppModel.shared` / `ThemeStore` |
| 设置 | `Settings { MacSettingsHost }`（`Command-,` 由系统提供），共享同一长期 `ThemeStore` / `AuralisAppModel` / `MacSettingsRouter` |
| 展开播放器 | **同窗口** presentation（`MacPlayerPresentationState`），不是独立 NSWindow |

## 2. 主窗口结构

```
MacMusicShell
└─ ZStack
   ├─ libraryUI
   │  └─ NavigationSplitView(columnVisibility:)
   │     ├─ MacSidebar  List(selection:) .listStyle(.sidebar) .searchable
   │     └─ detail ZStack(alignment: .bottom)
   │        ├─ NavigationStack(path: [MacDetailRoute]) + .navigationDestination
   │        │     .contentMargins(.bottom, 120, for: .scrollContent)
   │        ├─ MacFloatingPlayerBar（悬浮，非 safeAreaInset）
   │        └─ .inspector(isPresented:) { MacRightPanel（歌词 / 队列）}
   └─ if expanded: MacExpandedPlayerView（同窗口覆盖，zIndex 100）
```

- Sidebar 宽度：`navigationSplitViewColumnWidth(min/ideal/max)` 来自 `MacUIVisualTokens.Sidebar`（210/260/300）。
- Inspector 宽度：`inspectorColumnWidth(min/ideal/max)` 来自 `MacUIVisualTokens.RightPanel`（300/340/420）。
- 环境注入：`.environment(model.artworkStore)` + `.environmentObject(themeStore)` 放在 ZStack 层，主内容与 Expanded Player 共用。

## 3. 导航

- 一级目的地：`MacSidebarDestination`（搜索/首页/最近播放/最近添加/歌曲/专辑/艺术家/流派/收藏/不喜欢/下载/播放列表/分类/AI 助手）。
- 详情路由：`MacDetailRoute`（album / artist / playlist / genre），身份用 `MacEntityRouteID(serverID, remoteID)`。
- `MacNavigationModel`：`selection` + `path`；`selectSidebar` 清空 path，`push` 不改 selection，`back` 弹 path。
- 全局统一解析：`AuralisAppModel.track(for: GlobalID)` 必须同时匹配 `serverID + remoteID`。

## 4. 内容页

- **Songs**：原生 SwiftUI `Table`，`Set<GlobalID>` selection，sortable / resizable / 多选 / `contextMenu(forSelectionType:)` / 双击播放。
- **Albums / Artists / Genres / Playlists**：响应式 Artwork Grid（`MacArtworkGridMetrics` 计算列数与 itemWidth），hover Play / More，右键菜单。
- **Album / Artist / Genre / Playlist Detail**：主内容 `NavigationStack` 内 push，不使用通用 Browse Sheet。
- **Search**：Sidebar 一级目的地 + Sidebar `.searchable`；结果分 歌曲/专辑/艺术家/歌单，全部 GlobalID 双键解析、可点击；`Command-F` 聚焦搜索。
- **分类（Recommendation V2）**：Sidebar「分类」→ Dimension → Value → Track Table，复用现有 V2 索引。
- **不喜欢**：Sidebar「不喜欢」Smart Collection，可双击播放 / 右键取消不喜欢。

## 5. 播放器

- **Floating Player**（`MacFloatingPlayerBar`）：底部悬浮胶囊（`MacGlassCapsule`，CONTROL LAYER），三区 = 传输控制（左）/ 身份（中，含进度 Slider）/ 收藏·歌词·队列·音量·更多（右）。点击封面或标题/艺术家文本展开播放器；**整条胶囊不挂父级 TapGesture**（避免 macOS 祖先手势吞掉内部按钮）。
- **Expanded Player**（`MacExpandedPlayerView`）：同窗口覆盖，`MacFullPlayerMetrics` 响应式计算封面/边距/右栏宽度；右侧 Lyrics / Queue 上下文；左上关闭 / 右上音量 / 右下歌词·队列 玻璃胶囊。Reduce Motion 下展开/收起用 opacity 过渡，不强制 spring/move。
- **MiniPlayer**（`MacMiniPlayerWindow`）：独立窗口，`MacMiniPlayerView`，可隐藏封面；共享播放状态。
- **播放模式**：循环 `cycleRepeatMode`（off → all → one → off）、随机 `setShuffle`；`canGoNext/canGoPrevious` 统一 capability（含 shuffle 池语义）；模型逻辑由 `PlaybackModeBehaviorTests` / `SharedPlaybackCapabilityTests` 覆盖。

## 6. 菜单 / 键盘

- 自定义菜单：**播放**（播放暂停 / 上一首 / 下一首 / 随机 / 循环 / 音量）/ **歌曲**（收藏 / 不喜欢 / 当前歌曲信息 ⌘I）/ **显示**（侧边栏 ⌃⌘S / 歌词 ⌥⌘L / 队列 ⌥⌘U / 正在播放 ⌘L / 搜索 ⌘F）/ **播放器**（迷你播放器 ⌥⌘M / 全屏播放 ⇧⌘F）。
- 上一首 / 下一首：**plain ← / →**（`MacMusicShell.onKeyPress`），菜单中不再注册 Command-←/→（与 Apple Music 语义一致）。
- Space = 播放/暂停，Return = 播放选中；全部带 `isTypingText` firstResponder 守卫（输入框内放行）。
- 无重复的伪 Window 菜单：系统 Window 菜单保留，自定义窗口级动作收在「播放器」。

## 7. Liquid Glass 分层

- **NAVIGATION / CONTROL**：Sidebar / Toolbar / Floating Player / Expanded 玻璃胶囊使用系统 glass（`MacGlassCapsule` 集中管理 macOS 26+ `glassEffect` 与 macOS 15 `ultraThinMaterial` fallback）。
- **CONTENT**：Album tile / Home card / Song row / 内容 Section **不使用** `glassEffect`。

## 8. 视觉常量

- 所有高频视觉几何集中在 `MacUIVisualTokens`（Sidebar / Content / Artwork / Typography / FloatingPlayer / ExpandedPlayer / MiniPlayer / RightPanel）。
- 响应式算法保留在 `MacArtworkGridMetrics`（列数 / itemWidth）与 `MacFullPlayerMetrics`（Expanded 几何），只引用 Token 常量。
- 历史误导常量（`MacLayout.albumArtworkSize=168` 兜底 / `playerBarHeight=78` / `contentMaxWidth` / `sidebarIdeal/Min/Max`）已删除或迁移。

## 9. 设置

- `Settings` Scene（6 Pane：通用 / 服务器 / 资料库与播放 / AI 与公开数据 / 系统 / 关于），`frame(minWidth: 760, minHeight: 560)` 允许放大，避免大字体裁剪。
- 服务器配置保持在 Settings，不回 Sidebar。
- 主窗口与 Settings 共享同一 `ThemeStore` 实例（改主题后主窗口实时生效）。

## 10. 构建与测试状态

- `AuralisMac`（macOS）：BUILD SUCCEEDED（strict concurrency complete、warnings-as-errors）。
- `Auralis`（iOS generic device）：BUILD SUCCEEDED（iOS 本轮无视觉重构，仅共享层改动）。
- AppShellTests 162/162 PASS（含 PlaybackModeBehaviorTests 24、SharedPlaybackCapabilityTests 9、MacNavigationTests、MacArchitectureContractTests 4、MacVisualMetricsTests）。
- 不使用 Simulator；真实引擎播完事件需真机人工验证（见 `ManualValidation.md`）。
