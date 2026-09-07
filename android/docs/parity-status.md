# Auralis Android — 能力对齐跟踪（parity-status）

> 以 Swift 侧审计报告（`docs/audit/`）为基准，逐能力核对 Android 落地状态。
> 状态只允许四值：**Done / Partial / Not Started / N/A**。
> 本文随开发阶段持续更新；「代码为准」，与 platform-decisions.md 冲突时以本文为快照、
> 以代码为真相。

## 约定

- Swift 基准文件列 = 该能力在 Apple 仓库中的主要实现文件（供逐文件对照）。
- Android 实现列 = `android/core|feature/*` 对应文件。
- Done = 语义对齐 + 有真实调用链/测试支撑；Partial = 部分语义或仅壳/占位。

## 1. OpenSubsonic / 服务器协议（audit 02）

| 能力 | Swift 基准 | Android 实现 | 状态 |
|---|---|---|---|
| REST POST form 协议 + JSON 信封 | ProductionServerConnector.swift | core:opensubsonic | Done |
| 服务器 CRUD + 凭据 Vault | ProductionServerConnector.swift | core:data/connector + core:security | Done |
| 端点双地址（内网/外网）+ 路由持久化 | ProductionServerConnector.swift | ServerClientRegistry + AuralisPreferences | Done |
| 连接探测语义（认证/协议失败不切外网） | — | ProductionServerConnector.selectEndpoint | Done |
| 凭据/账号回滚（不留 orphan） | — | ProductionServerConnector.rollback | Done |
| 全目录/增量目录同步 | LocalCatalogStore.swift | core:data RoomCatalogRepository | Partial（增量同步待 UI 阶段验证） |

## 2. 本地目录与多服务器（audit 03）

| 能力 | Android 实现 | 状态 |
|---|---|---|
| 全表 `server_id` 隔离 | Room 实体 + DAO | Done |
| FTS 中文搜索 + 按 server 级清理 | tracks_fts（FTS4 unicode61）+ idsForServer | Done |
| 目录提交单事务（无中间态） | database.withTransaction | Done |
| 忘记服务器全量清理 | deleteServer（单事务） | Done |
| 收藏/评分/播放标记远端先行 | LibraryActionCoordinator | Done |
| 播放历史 occurrence 语义 | PlaybackHistoryCoordinator | Done |
| 播放计数/最近播放统计 | annotationDao + homeTopArtists/homeTopAlbums 聚合 | Done（S3 起被 Home 消费，SQL 聚合有测试） |

## 3. 播放（audit 04）

| 能力 | Swift 基准 | Android 实现 | 状态 |
|---|---|---|---|
| 播放引擎（Media3/ExoPlayer） | AVFoundationPlaybackEngine.swift | core:playback AuralisPlaybackEngine | Done（骨架+核心回调） |
| 队列 occurrence（entry.id vs track.id） | — | QueueEntry + MediaItem.mediaId=entry.id | Done |
| 首响优先（先播当前曲、后台补窗口） | — | awaitPlayAt / fillWindowAround | Done |
| 播放历史/scrobble 防重复计数 | — | notifyActivated/notifyCompleted + sink | Done |
| Local/Remote 来源识别 | — | DefaultPlaybackSourceResolver + localSourceKeys | Done |
| PlaybackService 进程级单例 | — | AuralisPlaybackService | Partial（MediaSession/通知待 UI 阶段） |
| 队列窗口化（>500） | — | QueueWindowing | Partial（S5 队列页消费） |
| 位置节拍（进度条/歌词高亮用） | PlaybackStore.position | engine.position（250ms StateFlow） | Done（S5） |

## 4. 主题（audit 05）

| 能力 | Android 实现 | 状态 |
|---|---|---|
| 主题选择持久化（aurora-glass 默认） | AuralisPreferences.selectedThemeFlow | Done |
| 布局偏好 v1→v2 迁移 | homeLayoutFlow + migrateLegacySet | Done |
| 设计系统 token/组件 | core:designsystem | Partial（UI 阶段扩展） |

## 5. App Shell 与导航（audit 06）

| 能力 | Android 实现 | 状态 |
|---|---|---|
| 服务器列表/添加/编辑/删除/切换（UI） | feature:server（已接入 Shell 覆盖路由） | Done（S1） |
| 连接测试（不落库）+ URL 策略前置 | ProductionServerConnector.testConnection + ServerURLPolicy | Done |
| Bottom Dock（3 分区：Home/Library/Assistant 圆钮） | app-mobile/shell（≤760dp 居中 overlay） | Done（S2） |
| 分区根切换 + 顶栏大标题结构 | MobileShell / ShellPages | Partial（Home/Library 已真实页，Assistant 待 S8） |
| Mini Player（真实绑定 playback） | app-mobile/shell MiniPlayerBar | Done（S5：上一首/下一首/缓冲/点开 Now Playing） |
| Settings 齿轮入口 → 设置占位（服务器行可用） | LibraryScreen 顶栏齿轮 | Partial（S7 完善） |

## 5b. Home 首页（audit 06 首页规格）

| 能力 | Swift 基准 | Android 实现 | 状态 |
|---|---|---|---|
| 模块注册表（3 快捷入口 + 9 内容模块含 Downloads） | HomeModule.swift | core:domain/Home.kt | Done（S3） |
| 布局有序 JSON v2 + v1 Set 迁移 + 读写归一化 | HomeLayoutStore.swift | HomeLayoutPreference.normalized + prefs | Done（S3，单测覆盖） |
| 模块可见性过滤（关闭不渲染不查数据、空模块配置保持） | HomeSnapshotBuilder.swift | HomeState.buildQuick/ContentModules | Done（S3） |
| 数据快照真实 SQL 派生（随机/最近播放/未播放/最近添加/下载/常听聚合） | HomeSnapshotBuilder.swift | RoomCatalogRepository home* 查询 | Done（S3，5 单测覆盖） |
| 「换一批」本地重采样（样本 18，不发网络） | HomeView reshuffle | HomeState.reshuffle + ORDER BY RANDOM() | Done（S3） |
| 目录变化自动刷新（计数信号免全表解码） | AppModel regenerate | homeChangeSignals combine 5 observeCount | Done（S3） |
| 首页 UI（快捷入口 3 列、140dp shelf、模块标题行） | HomeView.swift | feature:home/HomeScreens.kt | Done（S3） |
| 布局编辑（隐藏/排序/恢复默认） | HomeLayoutEditView.swift | feature:home/HomeLayoutEditScreen.kt | Done（S3；排序用上移/下移按钮替代拖拽） |
| 播放/浏览动作接线（playQueue、pendingBrowse→Library） | HomeView onTap | MobileShell.playShelf/openBrowse | Done（S3） |

## 5c. Library + Browse Detail（audit 06 Library/BrowseDetail 规格）

| 能力 | Swift 基准 | Android 实现 | 状态 |
|---|---|---|---|
| 音乐库 7 scope（albums/tracks/artists/playlists/favorites/genres/categories，默认 albums） | LibraryView scope | feature/library LibraryScreen + ScopeSelector | Done（S4） |
| scope 列表数据全部真实（Room Flow / SQL 派生；Genre 无曲目不显示；Categories 无数据源→能力说明不伪造） | LibraryViewModel | LibraryScreen 各 Scope | Done（S4） |
| 专辑 48 网格 / 艺术家行 / 歌单卡 / 流派按歌曲数降序 | LibraryView | AlbumGrid/ArtistRows/PlaylistGrid/GenreGrid | Done（S4） |
| 行/卡尾 ⋯ = 真实动作（立即播放/下一首/加队列/添加到歌单/下载·取消·删缓存/收藏切换） | contextMenu | LibraryTrackRow + TrackRowMenu | Done（S4） |
| Browse 覆盖路由（Home 跳转→Library 上方打开；顶栏返回；再点 Library 回根） | BrowseDetailSheet | MobileShell browseDestination + BrowseDetailScreen | Done（S4） |
| 17 BrowseDestination 承接（album/artist/playlist/收藏/各列表/genre/常听/下载/推荐分类） | BrowseDetailSheet 17 case | BrowseDetailScreen + loadDetail | Done（S4） |
| 详情头图 88 + 标题/副标题 + 播放全部 + 下载（确认弹窗，跳过已下载） | BrowseDetailSheet | TrackListWithHeader | Done（S4） |
| 点行 = 整组作队列从该行起播；随机类「换一批」= 本地重采样 | BrowseDetailSheet | onPlayRow + reloadKey 重载 | Done（S4） |
| 歌单总览排序 + 单行删除（二次确认） | PlaylistOverview + PlaylistSortOrder | PlaylistOverview | Done（S4） |
| 歌单管理（重命名/复制副本/去重/删除，只读禁止；远端先行落本地） | AuralisAppModel + PlaylistTracksView ellipsis | PlaylistCoordinator + PlaylistManageMenu | Done（S4） |
| 歌单行「从歌单移除」（二次确认，曲目保留） | removeFromPlaylist | LibraryTrackRow additionalMenuItems + removeAt | Done（S4） |
| 常听艺术家/专辑（按真实播放次数降序，点行推详情） | BrowseDetailSheet topArtists/topAlbums | TopArtistList/TopAlbumList（homeTopArtists/homeTopAlbums） | Done（S4） |
| 播放动作全接线：playQueue / insertNext（下一首）/ appendToQueue（加队列） | selectAndPlay/playNext/appendToQueue | MobileShell playShelf/playNextShelf/appendQueueShelf | Done（S4） |

## 5d. 播放器 UI（audit 04 + PlayerViews 规格；S5）

| 能力 | Swift 基准 | Android 实现 | 状态 |
|---|---|---|---|
| Mini Player 展开为 Now Playing（56 胶囊：封面/标题/上一首/播放/下一首） | MiniPlayerContent / CompactMiniPlayerContent | app-mobile MiniPlayerBar（S5 扩展） | Done（S5） |
| 正在播放全屏页（渐变背景 + 顶栏「正在播放/专辑」+ 分段：歌词/正在播放/队列） | NowPlayingView | feature:player NowPlayingScreen | Done（S5） |
| 海报 hero（封面主体） | artworkHero + NowPlayingArtworkGlow | AuralisArtwork 大封面（glow 以阴影+渐变近似） | Done（S5） |
| 标题/艺人跑马灯（超长单向滚动一次） | OneShotMarqueeText | PlayerUi AutoMarqueeText | Done（S5） |
| 进度滑块拖动暂存、松手 seek（显示位置/剩余时间） | pendingSeek + displayedPlaybackPosition | dragFraction + onDragEnd seekTo | Done（S5） |
| 五键传输区：播放模式循环（顺序/随机/列表循环/单曲循环）/上一首/大播放键/下一首/⋯ | transportControls + cyclePlayMode | PlaybackControlsArea + engine.cyclePlayMode | Done（S5） |
| 收藏（当前曲实时状态 + 切换动作） | favoriteButton + toggleFavorite | observeFavoriteTracks + libraryActions | Done（S5） |
| 下载管理（下载到本地/取消 xx%/删除下载） | moreMenu download/cancel/remove | graph.downloadManager 三态菜单 | Done（S5） |
| 添加到歌单（选已有只读禁用/新建并加入，远端先行） | AddToPlaylistSheet | PlayerAddToPlaylistDialog | Done（S5） |
| 前往专辑/艺术家（真实目录存在才可用 → Library Browse） | openCurrentAlbum/openCurrentArtist | menu → Shell openBrowse | Done（S5） |
| 音量（真实 engine.setVolume） | volumeControl + setVolume | Slider + controller.setVolume | Done（S5） |
| 音频信息切换（codec ⇄ 位深·采样率） | bottomInfo + TrackInformation 精简 | audioTechnicalLabel toggle | Done（S5） |
| 队列页：点行播放 occurrence、编辑模式移除/上移/下移、窗口计数提示 | queue + playQueueEntry + removeFromQueue + moveQueue | QueueContent + controller.* | Done（S5） |
| 歌词页：同步歌词按位置高亮自动滚动、空态、加载失败重试 | NowPlaying lyrics + LyricsIndexResolver | LyricsContent + lyricsService.lyricsFor | Done（S5） |
| Android 裁剪（非本阶段）：不喜欢/歌曲鉴赏/由此继续播放（AI，S8）、Music Haptics、AirPlay 输出选择 | — | 未移植（文档记录） | N/A |

## 6. 离线 / 歌词 / 封面（audit 07）

| 能力 | Android 实现 | 状态 |
|---|---|---|
| 三并发下载闸门 + 节流 | DownloadManager Semaphore(3) | Done |
| 冷启动水合 | hydrate() | Done |
| 前台下载服务 | DownloadService（dataSync） | Done |
| 歌词结构化/纯文本 + 本地写回 | RoomLyricsRepository + LyricsServiceImpl | Done |
| 封面 URL 提供 | ArtworkUrlProvider（注册表路由） | Done |

## 7. 服务器与 AI（audit 08）

| 能力 | Android 实现 | 状态 |
|---|---|---|
| Chat Completions 客户端 | core:ai | Done |
| 流式工具调用（按 index 拼接） | core:ai | Done |
| AgentToolLoop 三不变式 | core:ai | Done |
| Assistant 页面与工具执行 UI | feature/assistant | Not Started |

## 8. 当前缺口（按用户强制顺序排队）

1. ~~Server 添加/恢复 UI（feature:server）~~ ✅ S1 完成
2. ~~Mobile Shell + Bottom Dock~~ ✅ S2 完成（Dock/分区根/MiniPlayer 绑定/设置入口占位）
3. ~~Home 页~~ ✅ S3 完成（模块注册表 + 布局编辑 + 真实数据 + 播放/浏览接线；APK 已打包）
4. ~~Library + Browse Detail~~ ✅ S4 完成（Library 7 scope + BrowseDetail 17 目的地 + 歌单远端先行管理 + 播放动作接线；APK 已打包）
5. ~~Mini Player / Now Playing / Queue / Lyrics~~ ✅ S5 完成（Mini 展开 + NowPlaying 三页 + 队列编辑 + 同步歌词高亮 + 位置节拍；APK 已打包）
6. Search ← 当前阶段
7. Settings
8. Assistant
9. Android TV（app-tv）

> 最后更新：2026-09-07（P0 Core 九项 + S1 + S2 + S3 + S4 + S5 完成，S6 待开始）
