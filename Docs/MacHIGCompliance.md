# Auralis macOS HIG Compliance

> 核对日期：2026-08-13（macOS 27 Beta 5 / Xcode 27 Beta，macOS Deployment Target 15.0）
> 依据：Apple Developer Human Interface Guidelines、SwiftUI Documentation、Apple Music for Mac 官方快捷键页面。
> 说明：PASS = 代码层面符合且可自动验证；PARTIAL = 部分符合；MANUAL-VERIFY = 需要真机人工验证；N/A = 不适用。
> 除非所有人工项真实验证，否则不宣称“100% 符合 HIG”。

| 栏目 | 状态 | 说明 |
| :--- | :--- | :--- |
| Window | PASS | 标准 `WindowGroup`（min 900×600）+ `Settings` Scene + 独立 MiniPlayer Window；可自由缩放，无固定单一尺寸。 |
| Menu Bar | PARTIAL | 自定义菜单：播放 / 歌曲 / 显示 / 播放器；无重复伪 Window 菜单（系统 Window 菜单保留）。`Command-,` 打开设置由系统 Settings Scene 提供。MANUAL-VERIFY：真实 Menu Bar 排列与系统 Window/Help 菜单不冲突。 |
| Toolbar | PARTIAL | 恢复系统 Toolbar；本轮未给主窗口加自定义 ToolbarItem 重做（播放器悬浮条独立于 Toolbar）。MANUAL-VERIFY：Toolbar 在 light/dark、窄/宽窗口下的系统外观与 overflow。 |
| Sidebar | PASS | `List(selection:) .listStyle(.sidebar)` + Sidebar `.searchable`；宽度 Token 化（210/260/300）；一级目的地语义在 `MacSidebarDestination`。 |
| Navigation | PASS | `NavigationSplitView` + `NavigationStack(path: [MacDetailRoute])`；实体身份 `MacEntityRouteID(serverID, remoteID)`；Album/Artist/Genre/Playlist 在主内容栈打开，不使用通用 Browse Sheet。 |
| Search | PASS | Sidebar 一级目的地 + 系统 `.searchable`；`Command-F` 聚焦；结果 GlobalID 双键解析、可点击；不删除 Sidebar 搜索入口（发现型音乐应用设计）。 |
| Table | PASS | 原生 SwiftUI `Table`，`Set<GlobalID>` selection、sortable/resizable、多选、`contextMenu(forSelectionType:)`、双击/Return 播放。 |
| Inspector | PASS | Library 右侧 `.inspector`（歌词 / 队列），`inspectorColumnWidth` Token 化；Expanded Player 内部 right context 独立，不合并。 |
| Settings | PASS | `Settings` Scene 共享同一 `ThemeStore`；`frame(minWidth: 760, minHeight: 560)` 允许放大；服务器保持在 Settings。 |
| Player Controls | PASS | Floating Player / Expanded / MiniPlayer 传输按钮使用统一 `canGoNext/canGoPrevious`；循环 `cycleRepeatMode`、随机 `setShuffle`；整条播放条无父级 TapGesture（不吞按钮）。 |
| Liquid Glass | PASS | `MacGlassCapsule` 集中管理 CONTROL/NAVIGATION 层 glass（macOS 26+ `glassEffect`，macOS 15 fallback）；内容层无 `glassEffect`。 |
| Keyboard | PASS | Space/Return/←/→ 统一由 `MacMusicShell.onKeyPress` 处理并带 `isTypingText` firstResponder 守卫；菜单快捷键与 Apple Music 对齐（上一首/下一首 = plain ←/→，不再注册 Command-←/→）。 |
| Pointer / Hover | PARTIAL | 表格行 / tile hover Play/More 已实现。MANUAL-VERIFY：全场景 hover 一致性（Sidebar、Table 行、tile、播放条）。 |
| Accessibility | PARTIAL | 图标按钮带 `accessibilityLabel`/`help`；循环状态带 `accessibilityValue`（不循环/列表循环/单曲循环）；随机/收藏有 label。MANUAL-VERIFY：VoiceOver 全流程、Full Keyboard Access、Increase Contrast。 |
| Resizing | PARTIAL | 响应式网格（`MacArtworkGridMetrics`）与 Expanded 几何（`MacFullPlayerMetrics`）按窗口宽度计算。MANUAL-VERIFY：900×600 / 1024×700 / 1280×820 / 1440×900 / 1600×1000 及 Expanded 1280×800 / 1536×1050 / 宽屏无 overflow/clipping/overlap。 |
| Light / Dark | PARTIAL | 主窗口跟随系统外观；Auralis Theme 不强制覆盖 Sidebar/Toolbar/Table/Settings 系统语义。MANUAL-VERIFY：两种外观下播放条玻璃胶囊与内容对比度。 |
| MiniPlayer | PASS | 独立 `Window`，`defaultPosition(.bottomTrailing)`，共享 `AuralisAppModel.shared` / `ThemeStore` / `PlaybackStore`；尺寸 Token 化。 |
| Expanded Player | PASS | 同窗口 presentation（`MacPlayerPresentationState`），展开/收起不改导航 selection/path；Reduce Motion 下用 opacity 过渡；几何 Token 化。 |

## 关键实现位置

- `Apps/macOS/AuralisMacApp.swift`：Scene / commands。
- `AppShell/Mac/Shell/MacMusicShell.swift`：NavigationSplitView / NavigationStack / inspector / Floating Player / Expanded / Reduce Motion。
- `AppShell/Mac/Shell/MacFloatingPlayerBar.swift`：悬浮播放条（无父级 TapGesture）。
- `AppShell/Mac/Shell/MacUIVisualTokens.swift`：视觉 Token。
- `AppShell/Mac/Shell/MacArtworkGridMetrics.swift` / `MacFoundation.swift`（`MacFullPlayerMetrics`）：响应式几何。
- `AppShell/Mac/Shell/MacGlassCapsule.swift`：Liquid Glass 集中管理。
