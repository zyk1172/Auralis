# Auralis Mac Apple Music Parity（Round-2 审计与修正）

依据：Apple Developer HIG / SwiftUI 文档 / Apple Support（Music on Mac、Shuffle/Repeat、Queue、Lyrics、MiniPlayer、Keyboard shortcuts、Customize window/sidebar）。
不复制 Apple 商标资产；本文件只记录与真实 macOS 音乐 App 行为的对照与已修正项。

## 分类

| 项目 | 状态 |
| :-- | :-- |
| Navigation（Sidebar 一级 vs 详情 push） | MATCH（已修正） |
| Search（系统 .searchable） | MATCH（已修正） |
| Full Screen Player（独立窗口 + 全屏） | MATCH（已修正） |
| Detail 滚动模型（单 ScrollView + TrackRow） | MATCH（已修正） |
| Sidebar 信息架构 | MATCH（已重构 + Library Edit） |
| System Appearance（跟随系统，不强制 Theme） | MATCH（已修正） |
| Media Tiles（Album/Artist/Playlist/Track 分离） | MATCH（已修正） |
| Playlist mosaic（真实 2×2 去重） | MATCH（已修正） |
| Songs Table 默认列 + 显示选项 | MATCH（已收敛 + View Options 切换年份/流派/格式） |
| Player Bar 三区稳定布局 | MATCH（已修正） |
| Lyrics 排版 | MATCH（已修正） |
| Queue 语义（History/Current/Upcoming） | MATCH（已修正） |
| Get Info（TabView 面板） | MATCH（已修正） |
| MiniPlayer 独立窗口 | MATCH（已实现） |
| 菜单 / 快捷键 | MATCH（含 ⌘N 新建播放列表） |
| Library Edit（资料库显示/隐藏/排序） | MATCH（已实现，持久化） |
| Drag to Playlist | NOT IMPLEMENTED（P2） |

## Round-2 已修正（文件 → 行为）

- `MacFoundation.swift`：拆分 `MacSidebarDestination` / `MacEntityRouteID` / `MacDetailRoute` / `MacNavigationTarget` / `MacNavigationModel`（@MainActor ObservableObject，含 search 单一事实源）。Home「查看全部」与 Search「浏览」→ `selectSidebar`（清空 path）；Album/Artist/Playlist 卡片 → `push`（不改 selection）；path 只存实体 ID，渲染时从 Catalog 解析。
- `MacMusicShell.swift`：删除自绘 Search Field，改用 `.searchable(placement: .toolbar)`；⌘F 打开系统搜索；提交时 `recordSearch`；关闭搜索恢复原 destination；移除全局 `.tint`/`.preferredColorScheme`（跟随系统外观）；`showFullScreenPlayer`/`showMiniPlayer` 打开独立窗口；Space/Return/←/→ 键盘由 Shell 唯一处理（输入框放行）。
- `MacFullScreenPlayerView.swift`（新）：全窗口 Artwork 背景 + 超大封面 + 右侧同步歌词 + 底部最小控制；独立窗口进入系统全屏；无公开评价/技术参数。
- `MacNowPlayingView.swift`：精简为 封面 + 标题/艺术家/专辑 + 收藏/更多；公开资料与参数移入 Get Info。
- `MacDetailTrackList.swift`（新）：详情页曲目行（#/Play hover、Title、可选 Artist/Album、时长、收藏、More），替换 Album/Artist/Playlist/Genre 的嵌套 Table；整页单一 ScrollView。
- `MacAlbumView.swift`：Hero ambience 覆盖横向整区（非封面后方形 Glow）；紧凑 actions（Play primary / Shuffle secondary / Favorite / More）；删除 DisclosureGroup 设置式 footer。
- `MacArtistView.swift`：`常听歌曲`（本地播放次数排序，非外部热门）；Hero mosaic/monogram。
- `MacGenreView.swift`：Album 过滤改用 `AlbumRouteIdentity(serverID, albumID)` 双键。
- `MacPlaylistView.swift`：真实 mosaic 封面；删除歌单带 confirmationDialog。
- `MacTiles.swift`（新）：`MacAlbumTile` / `MacArtistTile` / `MacPlaylistTile` / `MacTrackTile` / `MacPlaylistArtwork`（2×2 去重、2 均分、1 单一、0 占位）；删除万能 `MacArtworkCard`。
- `MacHomeView.swift`：最近播放/最近添加按 Album 投影去重；收藏用紧凑歌曲列表；其余曲目货架按专辑去重封面。
- `MacSongTable.swift`：删除 `.onTapGesture(count:2)` 重复双击（仅保留 Table primaryAction）；Songs 默认列收敛为 标题/艺术家/专辑/时长/收藏。
- `MacRightPanel.swift`：无 segmented Picker；标题 歌词/待播队列；Queue 分 正在播放 / 播放下一首（可拖动、Delete、清空=clearUpcoming）/ 历史记录（近似）。
- `AuralisAppModel.swift`：新增 `currentQueueIndex` / `upcomingTracks` / `clearUpcoming()`。
- `MacPlayerBar.swift`：LEFT/CENTER/RIGHT 三区各 `.frame(maxWidth: .infinity)`，CENTER 真正居中。
- `MacTrackInfoSheet.swift`：Get Info 改为 TabView（详细信息/插图/歌词/文件/Auralis）。
- `MacMiniPlayerView.swift`（新）：独立 MiniPlayer 窗口，支持隐藏封面紧凑模式。
- `AuralisMacApp.swift`：新增 迷你播放器/全屏播放 窗口 Scene；菜单按 播放/歌曲/显示/窗口 分组，快捷键对齐（⌘L、⌥⌘U 队列、⌘I 信息、⌘↑/⌘↓ 音量、⇧⌘F 全屏播放、⌥⌘M 迷你播放器；删除 ⇧⌘Q）。
- `MacSidebarPreferences.swift`（新）：资料库显示/隐藏 + 拖动排序，UserDefaults 持久化；Sidebar「资料库」hover 出现「编辑」。
- `MacArtistsView.swift`：艺术家改为资料库内二级 split（左侧紧凑列表 + 右侧详情）。
- `MacSongsView.swift`：新增「显示选项」菜单（年份/流派/格式列开关，@AppStorage 持久化）。
- `MacPlayerBar.swift`：右侧新增「更多」菜单（不喜欢/取消不喜欢 + 歌曲信息），Favorite 常显、Dislike 低权重。
- 菜单「文件 → 新建播放列表（⌘N）」：弹窗命名后 `createPlaylist(named:)`。

## 人工验收

逐页 Structure / Density / System Controls / Cards / Typography / Resize / Keyboard / Hover / Light-Dark 清单见 `Docs/ManualValidation.md` → “Mac Apple Music Parity”。

## Round-3 Visual Parity（REFERENCE_A/B）

- Sidebar：+搜索一级页；播放列表不再内联；ideal 260。
- 搜索架构：全局搜索为 Sidebar 页（自带 .searchable）；专辑/歌曲/艺术家/播放列表各自本地搜索（「在专辑中查找」等）。
- Albums：响应式大封面 Grid（detail≈1268 → 4 列 ≈276pt）；Toolbar inline 标题 + 排序 + 本地搜索；无内容大标题。
- Placeholder：Mac 默认灰色 music note（macMusic），无 Navidrome 图。
- Floating Player：悬浮 Liquid Glass 胶囊，只位于 Main Content 上方；Toolbar 全局 Lyrics/Queue 移除。
- Full Player：按 REFERENCE_B 重排（Artwork≈31% 宽、左列 TrackInfo/Progress/Transport、右区 Lyrics/Queue 常驻、三组 Glass Capsule、全窗 ambience、透明 titlebar、enterFullScreenIfNeeded）。
- MacNowPlayingView 退役；⌘L 定位当前歌曲。
- 视觉状态一律 MANUAL-VISUAL-VERIFY（见 Docs/MacVisualParity.md）。

## Round-4（Interaction Parity）

- **同窗口 Expanded Player**：删除独立 `Window("全屏播放")` / `MacFullScreenPlayerWindow` / `openWindow(fullScreenPlayer)`；`MacPlayerPresentation(.library/.expanded)` 由 Shell 管理，Expanded Player 覆盖同一主窗口（`MacExpandedPlayerView`，ZStack + zIndex），保留 traffic lights，不新建 NSWindow。
- **点击底部封面**：在当前窗口向上展开（`matchedGeometryEffect("nowPlaying.artwork")` + spring 0.42）；右键菜单可「展开播放器 / 迷你播放器」。
- **窗口 → 全屏播放器**：先在当前窗口展开，再 `toggleFullScreen` 同一窗口；× / Esc 先退全屏再收起；收起后恢复原 Sidebar/页面/Scroll/Search 状态。
- **Expanded 三状态**：`MacExpandedPlayerContext(none/lyrics/queue)`；none 时播放器列水平居中，歌词/队列时左移 + 右侧 context 淡入；左上 Glass（× + 迷你）、右上常驻音量 Glass、右下歌词/队列 Glass（`.overlay(alignment:)` 定位，内容进 Glass，无 EmptyView 假背景、无整屏透明吞点击）。
- **Tile 点击**：Album/Artist/Playlist/Track Tile 删除父级 `onTapGesture`；Artwork/Title 为独立 `Button(onOpen)`，Play/More 分离；Menu destructive role 生效。
- **Search**：未解析实体显示「已不在本地资料库」且不可点（删除 placeholderTrack 参与真实动作）；最近艺术家按 (serverID, artistID) 双键；搜索状态 idle/searching/results/empty + 200ms debounce。
- **Grid**：Album/Playlist Grid 改为 GeometryReader 测宽 + 内部 ScrollView（不再 `ScrollView>GeometryReader+minHeight(600)`）。
- **Server → Settings**：删除 `MacSidebarDestination.server` 与 Sidebar/Shell 的 Server 页；新增 `MacSettingsRouter`（深链 Server 分类）；连接错误/首页空态改为「打开服务器设置」（`openSettings`）。
- **Liquid Glass**：`MacGlassCapsule` —— macOS 26+ 用真实 `glassEffect(.regular.interactive(), in: Capsule())`（已核对 Xcode 27 SDK），macOS 15 fallback ultraThinMaterial 胶囊。
- **假功能移除**：AlbumSort 移除不真实的「最近添加」；Playlist 空态提供「新建播放列表」。
- **未复制 Apple 业务**：无 广播/Apple Music scope/账户/订阅/AutoPlay/Crossfade/SharePlay/Apple Logo。
- 视觉状态一律 MANUAL-VISUAL-VERIFY（见 Docs/MacVisualParity.md）。

## Round-4 补充（Songs 数据列）

- Songs Table 新增真实「播放次数」列（`model.playCounts`，View Options 开关，持久化）。
- 新增 `AuralisAppModel.addedDate(for:)`（真实本地入库时间）；「添加日期」列因 SwiftUI `Table` 11 列 + Date 类型触发编译器类型检查限制而暂缓（数据访问器已就绪，后续可单独加回），不伪造数据。
