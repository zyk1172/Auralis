# Auralis macOS 27 Apple Music Visual Parity（REFERENCE_A / REFERENCE_B）

参考截图由用户提供（REFERENCE_A 专辑主窗口、REFERENCE_B 全屏播放器），本 Agent 环境无法查看图片，因此：
所有 `VERIFIED` 一律为 **MANUAL**（需真机截图对照），不以 Build PASS 判定 MATCH。

## REFERENCE_A — Albums（1536×1044）

| 项目 | TARGET | IMPLEMENTED | VERIFIED |
| :-- | :-- | :-- | :-- |
| Sidebar 宽度 | ideal ≈260，min 210，max 300 | `MacSidebar` `.navigationSplitViewColumnWidth(min:210, ideal:260, max:300)` | MANUAL |
| Toolbar 高度 | 56-60，inline 标题 | 系统 Toolbar + `.navigationTitle("专辑")`，内容无大标题 | MANUAL |
| 内容 leading padding | 宽窗口 44-48 | `MacArtworkGridMetrics.horizontalPadding`（≥1400→46 / ≥1100→40 / ≥900→32 / 其余 24） | MANUAL |
| Album 列数（detail≈1268） | 4 列 | `MacArtworkGridMetrics.albums`：<680→2，680-930→3，930-1280→4，1280-1540→5，>1540→6 | 逻辑测试 4 列 PASS；视觉 MANUAL |
| Artwork 尺寸（detail≈1268） | ≈267-275 | 公式 `(content - gap*(cols-1))/cols`，≈276 | 逻辑测试 260-280 PASS；视觉 MANUAL |
| Grid gap / spacing | ≈24-28 | spacing=24 | MANUAL |
| Album 排版 | Title 单行 primary，Artist 单行 secondary，无 Year/Count/Format | `MacAlbumTile` body/subheadline | MANUAL |
| Artwork 圆角 | 8-10 | `MacLayout.artworkCornerRadius = 10` | MANUAL |
| 无封面占位 | 浅灰方块 + 灰色 music note，无 Navidrome 图 | `ArtworkPlaceholderStyle.macMusic`（Mac 默认） | MANUAL |
| Sidebar 结构 | 搜索/主页 / 资料库 / 播放列表 / Auralis | 已实现；播放列表不再内联全部歌单 | MANUAL |
| 搜索架构 | 全局搜索为 Sidebar 一级页；专辑页本地「在专辑中查找」 | `MacSearchView` 自带 `.searchable`；Albums/Songs/Artists/Playlists 各自本地 searchable | MANUAL |
| Toolbar 全局按钮 | 只留页面上下文动作，Player 控制只属于播放器 | Shell Toolbar 已移除 Lyrics/Queue | MANUAL |
| 底部播放器 | 宽 Glass 胶囊，仅 Main Content 上方，不盖 Sidebar | `MacFloatingPlayerBar` + detail safe-area inset；最大宽 1200 / 本体高 68 / 底距 14 | 逻辑测试 230-260 侧宽 PASS；视觉 MANUAL |

## REFERENCE_B — Full Player（1536×1050）

| 项目 | TARGET | IMPLEMENTED | VERIFIED |
| :-- | :-- | :-- | :-- |
| Artwork 尺寸 | ≈窗口宽 23%（1536→≈353） | `MacFullPlayerMetrics.artworkSize = min(420, max(280, min(w*0.23, h*0.36)))` | 逻辑测试 340-370 PASS；视觉 MANUAL |
| Artwork 左距 | ≈9.2% 宽（≈141） | `leftMargin = w*0.092` | 逻辑测试 130-150 PASS；视觉 MANUAL |
| Artwork 顶距 | 左播放轨道在窗口中部（1536×1050→≈241） | `topY = clamp(h*0.23, 190...260)` | 逻辑测试 220-250 PASS；视觉 MANUAL |
| 左列结构 | 固定播放轨道：Artwork 居中 → TrackInfo → Progress → Transport（信息/进度/控制等宽） | 已实现 | MANUAL |
| Progress | 等宽 Artwork，elapsed/remaining | Slider + 时间 caption monospacedDigit | MANUAL |
| Transport | 5 按钮 Spacer 均布，active 用 Media Accent | 已实现（shuffle/prev/play/next/repeat） | MANUAL |
| 右区 Lyrics/Queue | 与左轨分离、更靠近顶部；无歌词显示 Empty State | `MacFullPlayerContext`；空歌词显示「无可用歌词」 | MANUAL |
| 左上 Glass | 关闭 X + 迷你播放器（≈90-100×46） | GlassControlGroup capsule（xmark + pip） | MANUAL |
| 右上 Volume Glass | ≈220-240×46-50，常驻 slider | GlassControlGroup（speaker.wave.3 + slider 150） | MANUAL |
| 右下 Lyrics/Queue Glass | ≈100-110×46-50 | GlassControlGroup（quote.bubble + list.bullet） | MANUAL |
| 背景 | 全窗 Artwork blur 90-120，sat .65-.8，black 0.24-0.36 | blur 100 / sat 0.72 / black 0.30 / scale 1.15 | MANUAL |
| 窗口 chrome | 透明 titlebar + fullSizeContentView，仅 Full Player 窗口 | `MacFullPlayerWindowConfigurator` | MANUAL |
| 自动全屏 | window 解析后一次进入，已全屏不重复 toggle | `enterFullScreenIfNeeded`（didRequestFullscreen） | MANUAL |
| 关闭 | 全屏时先退全屏再关窗 | `close()` | MANUAL |
| Community/技术信息 | 禁止 | 无 | PASS（源码无） |

## 其他

- Normal Player 不再全宽底部条：`MacFloatingPlayerBar` 悬浮在 detail overlay，`GlassControlGroup`（ultraThinMaterial 胶囊 + 描边 + 阴影；macOS 27 真 glassEffect API 未在 SDK 接口中确认，统一用此 fallback）。
- Home：删除双标题；shelf 尺寸 150-210（Album/Playlist ≈190-210，Artist ≈170，Track ≈150）。
- MacNowPlayingView 已退役；⌘L = 定位当前歌曲（进入歌曲页并选中当前曲目）。
- iOS：`ArtworkPlaceholderStyle` 默认 `.auralis`，无视觉变化。
- Liquid Glass 仅用于 CONTROL LAYER（Floating Player / Full Player Capsules）；内容层无 glass。
- `MacMediaAccent`（pink/red）统一 active Shuffle/Repeat/Favorite。

## Round-4（Interaction）补充

- Expanded Player：同窗口覆盖（非新窗口）；none 时播放器列水平居中，lyrics/queue 时左移+右栏。
- 点击底部封面 → 当前窗口向上展开（matchedGeometryEffect）；窗口→全屏播放器 = 展开 + 同窗 toggleFullScreen。
- 三组 Glass Capsule（左上/右上音量/右下歌词-队列）用 `.overlay(alignment:)` + 内容进 `MacGlassCapsule`（macOS26 glassEffect，15 fallback），无整屏透明容器。
- Sidebar 无 Server；服务器仅 Settings（`MacSettingsRouter` 深链）。首页空态「打开服务器设置」。
- 验证：AuralisMac + Auralis generic build PASS；AppShellTests 128/128、LocalCatalogTests 38/38。
- 视觉与点击验收：MANUAL-VISUAL-VERIFY（需真机；本 Agent 无 GUI 截图能力）。
