# Auralis macOS Clean-Slate UI Rebuild 审计

目标：把 Mac 端从“iOS 组件 + 桌面页面”混合形态，重做为以 Apple Music for Mac 为主要参考的原生 macOS 音乐播放器。
Deployment Target 保持 macOS 15.0；macOS 27 独占 API 一律使用 `#available`；Swift 6 Strict Concurrency Complete；Warnings As Errors。

## 删除的旧 UI

- `MacAuralisRootView.swift`（旧窗口 Shell / 自绘导航）
- `MacPages.swift`（旧 Table / Home / Search / Downloads / Playlist 等 1247 行）
- `MacContentPages.swift`（旧 Detail 页 / NowPlaying / Disliked / V2）
- `MacInspector.swift`（旧 4-tab Inspector）

源码中不再保留旧视觉双体系；业务逻辑（AppModel / PlaybackStore / ArtworkStore / Catalog / MusicEnrichment / V2 / Server / Settings）原样复用。

## 新文件结构

```
Mac/
  Shell/      MacFoundation(路由+命令+布局常量) · MacMusicShell · MacSidebar
              MacPlayerBar · MacRightPanel(Lyrics/Queue) · MacArtworkCard
              MacTrackContextMenu · MacPageHeader
  Library/    MacHomeView · MacSongsView · MacSongTable · MacAlbumsView
              MacArtistsView · MacGenresView · MacPlaylistListView · MacTrackCollectionView
  Detail/     MacAlbumView · MacArtistView · MacGenreView · MacPlaylistView · MacNowPlayingView
  Search/     MacSearchView
  Utility/    MacMusicDownloadsView · MacV2CategoriesView · MacTrackInfoSheet(Get Info)
  （保留）     MacServerPage · MacSettingsWindow
```

## 窗口 / Toolbar / Sidebar / Inspector

- 标准 `WindowGroup`（min 900×600，default 1280×820）+ `Settings` Scene；无 `.hiddenTitleBar`、无伪造 Toolbar。
- `MacMusicShell`：`NavigationSplitView` + 主内容 `NavigationStack(path: MacRoute)` + `.toolbar`（搜索框 + 歌词/队列按钮）+ `.inspector(isPresented:)`（右侧 Lyrics/Queue 面板）+ `.safeAreaInset(bottom:)`（Apple Music 式播放条）。
- Sidebar（`MacSidebar`）：浏览 / 资料库 / 播放列表（真实歌单内联）/ Auralis 分区，系统 `.sidebar`，不手工涂色。
- Toolbar 中所有动作均有 Menu Bar 命令：⌘F 搜索、⌘L 正在播放、⌘⇧L 歌词、⌘⇧Q 队列、⌘⌥I 检查器、⌃⌘S 侧边栏、⌃⌘F 全屏播放、播放菜单（⌘←/⌘→/播放暂停/随机/循环）、歌曲菜单（收藏/不喜欢/信息）。
- Space 播放/暂停唯一入口：`MacMusicShell.onKeyPress(.space)` + firstResponder 文本检测（输入框内放行）。

## 页面

- Home：只展示真实有数据的货架（最近播放/最近添加/收藏/常听专辑/常听艺术家/很久没听/从未播放/收藏里随便听/播放列表）；无 server card、无继续播放大卡片。
- Songs：原生 `Table`（`Set<GlobalID>` selection、sortable/resizable、多选、双击播放、右键菜单）。
- Albums / Artists / Playlists：自适应 Artwork Grid，hover Play/More。
- Album Detail：Hero（320 ambience + 280 封面 + 元数据 + Play/Shuffle/Favorite/More）+ 按碟曲目表 + 底部元数据 + 更多信息。
- Artist Detail：名称 + Favorite/Play/Shuffle + 热门歌曲 + 专辑网格；无艺人照片时用代表专辑 2×2 mosaic。
- Playlist Detail：前 4 首真实封面 2×2 mosaic + 名称/曲目数/时长 + Play/Shuffle + Table。
- Search：Toolbar 全局搜索；空查询 Landing（最近搜索/浏览资料库/最近播放艺术家/常用歌单）；结果分 歌曲/专辑/艺术家/歌单，全部 GlobalID 双键解析、可点击。
- Now Playing：Full Player 形态（大封面 + Artwork ambience + 私人状态 + 公开评价摘要 + 技术信息）；⌃⌘F 进入系统全屏。
- Right Panel：只承担 歌词 / 队列（Apple Music 式）；详情信息走「歌曲信息」独立 sheet。
- Get Info：歌曲信息 sheet（基本信息 / 私人状态 / 公开音乐资料三来源可点击 / 操作）。
- Settings：`MacSettingsWindow` 6 Pane（通用/服务器/资料库与播放/AI 与公开数据/系统/关于），与主窗口共享同一 ThemeStore。

## 构建与测试

- `AuralisMac` generic macOS Build：PASS（strict concurrency complete、warnings-as-errors）。
- `Auralis` generic iOS Build：PASS（iOS 无视觉重构，共享层仅 `AuralisRootView` macOS 分支指向新 Shell）。
- AppShell 逻辑测试（含新增 Mac route/query 测试）与 LocalCatalog V2 传输测试：全绿。
- 不使用 Simulator。
