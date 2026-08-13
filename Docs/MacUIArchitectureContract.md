# Auralis Mac UI Architecture Contract

> 核对日期：2026-08-13（macOS 27 Beta 5 / Xcode 27 Beta）
> 目的：冻结已经稳定的 Mac 架构，让后续「多模态截图标注」只做视觉迭代，不破坏导航 / 播放 / 数据 / 交互语义。
> 配套：`Docs/MultimodalMacUIEditing.md`（标注执行协议）、`Docs/MacHIGCompliance.md`（逐项合规）、`Docs/MacPlatformAudit.md`（当前真实架构）。

## LOCKED ARCHITECTURE（除非用户明确要求改功能，禁止改动）

- `AuralisAppModel` 播放 / 业务逻辑（repeat / shuffle / queue / seek / favorite / dislike / history）
- `PlaybackStore` / `PlaybackEngine`（AVFoundationPlaybackEngine） / `SystemMediaIntegration`
- `LocalCatalog` / `AgentKit` / Server services / Download services / Music enrichment / Recommendation V2
- `GlobalID` 语义（serverID + remoteID 双键），禁止退回 bare TrackID
- `MacNavigationModel` / `MacSidebarDestination`（语义身份）/ `MacDetailRoute` / `MacEntityRouteID` / `MacNavigationTarget`
- Window topology：主窗口 `WindowGroup`、同窗口 Expanded Player（`MacPlayerPresentationState`）、独立 MiniPlayer Window、`Settings` Scene
- Inspector 语义角色（Library = `.inspector` Lyrics/Queue；Expanded = 内部 right context）
- 搜索 = Sidebar 一级目的地 + Sidebar `.searchable`（不删除）
- 服务器入口 = Settings（不回 Sidebar）

## VISUAL-EDITABLE（多模态标注可直接改）

- `MacUIVisualTokens`（间距 / 尺寸 / 圆角 / 字体 / 播放器几何）
- `MacArtworkGridMetrics`（列数 / itemWidth 响应式策略，可调断点与间距常量）
- `MacFloatingPlayerBar` 内部视觉布局（控件排列、hover、间距；动作必须复用 `model.cycleRepeatMode()` 等既有 API）
- `MacExpandedPlayerView` / `MacMiniPlayerView` 内部视觉布局
- `MacSidebar` 的 spacing / icon / label 展示（不改变 selection binding 与路由语义）
- Library 页面间距、Album/Artist/Playlist tile、Typography、Artwork 尺寸、padding、corner radius、control 视觉分组

## CONDITIONALLY EDITABLE（仅 Apple HIG 架构修复或用户明确要求功能变化才改结构）

- `MacMusicShell`（ZStack / NavigationSplitView / inspector 挂载点）
- `AuralisMacApp`（Scene / commands）
- `MacFoundation` 路由文件（`MacCommand` 广播通道等）

## 硬性禁止（图片 Agent 一律不允许）

1. 把 `NavigationSplitView` / `List(.sidebar)` / SwiftUI `Table` / `.searchable` / `.inspector` 换成 ScrollView / 自绘 rows / 自绘搜索框。
2. 把实体对象塞进 NavigationPath、用 name 当唯一身份、用 Sheet 代替正常 detail 导航。
3. 重新建立 `Window("全屏播放器")`——Expanded Player 必须是同窗口 presentation。
4. 创建第二套播放状态 / MiniPlayer 独立播放逻辑。
5. 把 Server 移回 Sidebar。
6. 在内容层大面积 `glassEffect`。
7. 重写业务 API（如直接 `model.repeatMode = ...` 绕过 `cycleRepeatMode`）。
8. 用 Canvas / Path / DragGesture 模拟系统 Button / Slider / Menu。

## 修改前 Change Map（强制流程）

每次图片修改前，先生成：
```
Annotation → Component → File → Token/View → Architecture Impact（Visual only / Architecture）
```
若标注会改变 Navigation / Window topology / Playback semantics / data architecture → 识别为 **architecture-changing request**，不得伪装成视觉 tweak，必须显式报告。
