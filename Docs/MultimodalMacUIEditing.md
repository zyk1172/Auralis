# Auralis 多模态图片标注 UI 修改协议

> 核对日期：2026-08-13（macOS 27 Beta 5 / Xcode 27 Beta）
> 适用：以后用户把 Mac 截图 + 数字标注（① 这里太宽 ② 封面移一下 ③ 字体小一点 …）交给多模态 Agent 时，
> Agent 必须按本协议执行。

## 0. 两条最高原则

1. **图片是视觉事实来源**：截图与标注反映用户当前看到的 UI，是视觉修改的第一依据。
2. **代码 Architecture Contract 高于单张图片**：任何标注如果会改变 Navigation / Window topology / Playback semantics / data architecture，
   必须识别为 **architecture-changing request**，显式报告，不能假装成视觉 tweak 偷偷执行。
   完整边界见 `Docs/MacUIArchitectureContract.md`。

## 1. 标注分类

每个标注先归类：

| 分类 | 含义 | 处理 |
| :--- | :--- | :--- |
| VISUAL | 间距 / 尺寸 / 圆角 / 字体 / 颜色 / hover | 改 `MacUIVisualTokens` 或对应页面视觉布局 |
| CONTROL ARRANGEMENT | 移动现有按钮 / 控件分组 | 移动控件但**复用原 action / accessibilityLabel / help / disabled** |
| ARCHITECTURE | 改变导航 / 窗口拓扑 / 播放语义 / 数据模型 | **不做**；显式报告并等待用户确认 |
| PRODUCT | 新增/删除功能入口（如删除 Sidebar 某项） | 报告为产品导航变更，不作为普通视觉修改 |

## 2. 修改前 Change Map（强制）

执行任何修改前，输出内部映射（不必给用户长文，但必须按此原则工作）：

```
Annotation → Component → File → Token/View → Architecture Impact
例：
#1 播放器高度 68→62 → MacFloatingPlayerBar → MacUIVisualTokens.FloatingPlayer.height → Visual only
#2 专辑封面间距 → MacAlbumsView → MacArtworkGridMetrics.spacing → Visual only
#3 Sidebar 删除 AI 助手 → MacSidebarDestination → Architecture / Product Navigation → 不作为视觉修改执行
```

## 3. 修改入口优先级

1. **优先 `MacUIVisualTokens`**：间距 / 尺寸 / 圆角 / 字体 / 播放器几何。
2. **响应式几何**：`MacArtworkGridMetrics`（列数断点 / 间距）、`MacFullPlayerMetrics`（Expanded 几何）。
3. **单页视觉布局**：对应 Mac 页面 View 内调整 padding / spacing / frame。
4. **禁止**：在各页面硬编码 `GridItem(.fixed(...))`（除非临时诊断）、在 10 个 View 各写一套 glass/shadow。

## 4. 控件移动铁律

- 移动 Repeat / Shuffle / Favorite / Lyrics / Queue / Play / Next / Previous 时，**继续调用既有 API**：
  `model.cycleRepeatMode()` / `model.setShuffle(...)` / `model.toggleFavorite(...)` / `model.togglePlayback()` / `model.next()` / `model.previous()`。
- 禁止绕过业务 API（例如直接 `model.repeatMode = ...`）。
- 禁止用 Canvas / Path / DragGesture / `Text+onTapGesture` 模拟系统 Button / Slider / Menu。

## 5. 禁止事项（硬性）

- 重写系统控件：`NavigationSplitView` / `List(.sidebar)` / SwiftUI `Table` / `.searchable` / `.inspector` / `Slider` / `Menu`。
- 改变 Window topology：不得新建 `Window("全屏播放器")`；Expanded Player 必须仍是同窗口 presentation；MiniPlayer 仍是独立 Window；Settings 仍是 Settings Scene。
- 修改 `MacNavigationModel` / `MacSidebarDestination` 语义身份 / `GlobalID` 双键。
- 把实体对象塞进 NavigationPath、用 name 当身份、用 Sheet 代替正常 detail 导航。
- 内容层大面积 `glassEffect`。
- 触碰播放 / 数据 / Agent / V2 / 下载 / Music enrichment 业务层（除非用户明确说“修播放功能 Bug”）。

## 6. 修改后最小回归（每次图片 patch 必跑）

至少：
1. `AuralisMac` Build（不通过 = 不允许交付）。
2. Mac architecture 逻辑测试（`MacArchitectureContractTests` / `MacNavigationTests` / `MacVisualMetricsTests`）。
3. `PlaybackModeBehaviorTests`（若改动涉及播放器控件）。

不得因为“只改 UI”跳过 Build。

## 7. 环境与约束

- 不使用 Simulator；Build/Test 走 macOS host（`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`）。
- Swift 6 Strict Concurrency Complete、Warnings As Errors、macOS Deployment Target 15.0 保持不变。
- macOS 27 独占 API 一律 `#available(macOS 27, *)`。
