# Auralis App Shell 与全页面 UI 规格审计报告（iOS → Android Compose）

> 审计对象：iOS 主 Shell 与全部页面（只读，未修改任何源文件）。
> 所有数值均来自源码实测，并已与用户预期逐项核对。带 ✅ 表示与用户预期一致，⚠️ 表示**与用户预期不符**，需重点关注。

---

## 0. 全局通用度量（供 Compose 复用）

| 名称 | 值 | 源码位置 |
|---|---|---|
| `AuralisSpacing.xSmall / small / medium / large / xLarge / huge` | 4 / 8 / 12 / 20 / 28 / 40 | ThemeContracts.swift:171 |
| `AuralisRadius.small / medium / large / artwork` | 8 / 14 / 22 / 18 | ThemeContracts.swift:179 |
| `IOSLayoutMetrics.readableContentMaxWidth` | 960 | AuralisRootView.swift:319 |
| `IOSLayoutMetrics.floatingChromeMaxWidth` | 760 | AuralisRootView.swift:317 |
| `IOSLayoutMetrics.playerContentMaxWidth` | < readableContentMaxWidth | 测试断言 |

---

## 1. 底部 Dock（AuralisRootView.swift）

### 1.1 常量实测（✔ 与用户 56/56/8/6 完全一致）

| 常量 | 值 | 说明 |
|---|---|---|
| `miniPlayerHeight` | **56** ✅ | BottomChromeMetrics 默认 |
| `dockHeight` | **56** ✅ | 底部主栏高度 |
| `spacing` | **8** ✅ | 展开态双层间距 |
| `bottomPadding` | **6** ✅ | Dock 底部内边距 |
| `safeAreaBottom` | 0 | 运行时注入 |
| `bottomBarHeight` | 56 | = dockHeight |
| `dockSpacing` | 8 | = spacing |
| `dockBottomPadding` | 6 | = bottomPadding |

> ⚠️ 源码注释明言：「之前 **72pt** 太大，现统一收小到 **56pt**」（AuralisRootView.swift:388）。若历史 PRD 写 72 已作废。

### 1.2 派生高度

| 度量 | 公式 | 结果 |
|---|---|---|
| `singleBarReservation` | dockHeight + bottomPadding + safeArea | 56+6 = **62** |
| `expandedReservation` | miniPlayerHeight + spacing + singleBar | 56+8+62 = **126** |
| `expandedInteractionHeight` | bar*2 + spacing + bottomPad | **126** |
| `compactInteractionHeight` | bar + bottomPad | **62**（注释「62pt 交互树」来源） |
| `playerCollapseWidth` | — | **128** |
| `compactInteractionThreshold` | collapseProgress 阈值 | **0.96** |

### 1.3 手势规则（BottomDockProgressReducer）

| 规则 | 值 |
|---|---|
| `minimumVerticalSwipeDistance` | **44** ✅ |
| 方向判定 | `abs(height) > abs(width)` **且** `abs(height) >= 44` |
| 结果映射 | 上滑 → 1（收拢）；下滑 → 0（展开）；否则 nil（不触发） |
| `shouldPublish` | 两端须精确 0/1；中间变化需 ≥ `publicationEpsilon=0.008` |
| `terminalProgress` | 只选终态，绝不留半展开 |

### 1.4 动画

| 场景 | 时长 / 缓动 |
|---|---|
| `BottomDockMotion.duration` | **0.56s** `.smooth(duration:0.56)` |
| `reduceMotion` | `.linear(duration:0.18)` |
| 全程 | 手势结束才启动动画，拖动速度不影响时长 |

### 1.5 结构：展开态 vs 收拢态

**展开态 `ExpandedDock`**：`VStack(spacing:8)` → [MiniPlayer（若 `showsPlayer`）, MainTabBar]。双层均高 56，外层 `padding(.horizontal,16) + .bottom(6)`。

**收拢态 `CollapsedDock`（progress≥0.96）**：`HStack(spacing:8)` → 三区：
1. **Home 圆端点** `CircularDockButton`（house.fill，font 19 semibold，accent 色）→ 点击=展开 Dock（非切页）。
2. **中间槽**：`.player` 时放 `CompactMiniPlayerContent`；`.assistant` 时透明占位（真实输入栏占用）。
3. **Assistant 圆端点** `CircularDockButton`（sparkles，font 21 semibold，primaryText 色）→ 选中 assistant。

> 收拢三区 = Home 圆端点 / Compact Mini Player / Assistant 圆端点 ✅ 完全吻合。

**Morphing 过渡**：单一 `MorphingBottomDock` 层；MiniPlayer 从顶部下落并收窄至中间胶囊；Home/Assistant 圆按钮「存活」（缩小到 56×56 圆形玻璃），中间 library 项与玻璃底板淡出（chromeFade 0.38→1，itemFade 0.32→0.78）。progress≥0.96 后切到真实 `CollapsedDock` 交互树。

---

## 2. Mini Player（PlayerViews.swift）

### 2.1 完整版 `MiniPlayerContent`（用于展开态与 Morphing）

| 项 | 值 |
|---|---|
| height 默认 | 56 |
| 封面 `coverSize` | `min(42, max(36, height-14))` → 56 时 **42**（范围 36~42 ✅） |
| 封面圆角 | 8，阴影 black 0.12 / r3 / y1 |
| 标题 | `.subheadline.weight(.semibold)`，lineLimit 1 |
| 艺术家 | `.caption` |
| 左内边距 | 12；Spacer minLength 8 |
| 控制 HStack spacing | 4 |
| 上一首/下一首 | `backward.fill`/`forward.fill`，font 16 semibold，按钮 44×44 |
| 播放/暂停 | `PlaybackControlIndicator` font 17，frame minWidth 44 minHeight 44 |
| 外边距 | `.padding(.horizontal,12)` |
| 进度条 | **无**（注释：进度仅在完整播放页提供）⚠️ 注意：完整 MiniPlayer 不带进度条 |
| 点击 | 整条 → `isNowPlayingPresented` |

### 2.2 紧凑版 `CompactMiniPlayerContent`（收拢态中间槽）

| 项 | 值 |
|---|---|
| 封面 | 36，圆角 8 |
| HStack spacing | 10 |
| 标题 | `.subheadline.weight(.semibold)`，lineLimit 1（**无艺术家行**） |
| Spacer | minLength 4 |
| 按钮 | **仅播放/暂停**，`PlaybackControlIndicator` font 17，frame **宽 42 × 高 44**（⚠️ 非 44×44） |
| 外边距 | `.padding(.horizontal,10)` |
| 点击 | → `isNowPlayingPresented` |

### 2.3 Assistant 输入栏 `DockAssistantInputBar`

复用 `BottomGlassBarShell`，高 56；左侧 sparkles（22），`TextField`（占位「描述你想听的音乐…」），右侧发送/停止按钮（随 `agent.isRunning` 切换）。

---

## 3. 一级导航（AuralisAppModel.swift / AuralisRootView.swift）

`AppSection` 枚举有 **5** 个值：`home, library, assistant, search, settings`。但 Dock 只渲染 `compactDockSections = [.home, .library, .assistant]`，且展开态 `MainTabBarContent` 同样只用这 3 个 → **一级导航确认只有 3 个** ✅。

| 入口 | 真实路径 |
|---|---|
| Home / Library / Assistant | Dock 三个圆按钮/标签（`MainTabBarContent` 胶囊选中，font 19 medium，选中=accent 色） |
| **Settings** ⚠️ | **不在 Dock**：LibraryView 右上工具栏 gear（`selectTopLevelSection(.settings)`，AuralisRootView 无；LibraryView.swift:40）+ AssistantView（AssistantView.swift:657） |
| **Search** ⚠️ | **不在 Dock**：由 AssistantView 触发 `presentedSheet = .librarySearch` → `SearchView` 以 sheet 呈现（标题「搜索音乐库」）；AppSection.search 仅作为 SectionContent 备用 |

> 结论：Android 不应把 Search/Settings 做成底部 Tab；Settings 用 Library 顶栏入口，Search 从 Assistant 页拉起 sheet。

---

## 4. HomeView（HomeView.swift / HomeModule.swift / HomeLayoutStore.swift）

### 4.1 卡片度量（✔ 与 140/12/3/20 一致）

| 项 | 值 |
|---|---|
| `HomeCardMetrics.width` | **140** ✅ |
| `HomeCardMetrics.spacing` | `AuralisSpacing.medium` = **12** ✅ |
| `HomeCardMetrics.textSpacing` | **3** ✅ |
| `HomeCardMetrics.titleHeight` | **20** ✅ |
| 主内容最大宽度 | `IOSLayoutMetrics.readableContentMaxWidth` = **960**（窄屏满宽，宽屏限宽居中） |
| 快捷入口网格 | `LazyVGrid` 3 列（超 3 自动换行），卡片 minHeight 64，圆角 `AuralisRadius.medium`=14，bg surface，图标+数量（无文字标题） |

### 4.2 HomeModule 注册表与默认开关（实测 9 个内容模块）

**快捷入口（quickEntry，固定 3 个，均默认显示）**：`playlists`(歌单) / `favorites`(收藏) / `mostPlayed`(最常听)。
> ⚠️ `HomeModuleID.playHistory` 在枚举里但**未注册**；`downloads` 属于内容模块而非快捷入口。

**内容模块（content，9 个）默认开关**：

| # | ID | 标题 | 默认 | order |
|---|---|---|---|---|
| 1 | random | 随机音乐 | **ON** | 0 |
| 2 | recentlyPlayed | 最近播放 | **ON** | 1 |
| 3 | longUnplayed | 很久没听 | **ON** | 2 |
| 4 | recentlyAdded | 最近添加 | **ON** | 3 |
| 5 | favoriteRandom | 收藏里随便听 | **ON** | 4 |
| 6 | downloads | 下载 | **ON** | 5 |
| 7 | neverPlayed | 从未播放 | **OFF** | 6 |
| 8 | topArtists | 常听艺术家 | **OFF** | 7 |
| 9 | topAlbums | 常听专辑 | **OFF** | 8 |

→ 默认 **6 开 / 3 关**，与「9 个模块」预期数量一致。布局持久化于 `UserDefaults["auralis.homeLayout.v1"]`，读盘时 `normalized()` 丢弃未知 ID、补齐新模块。

### 4.3 底部资料库统计（4 项）

`librarySummary`：`艺术家 / 专辑 / 歌曲 / 歌单`（取自 `model.catalog` 计数，HStack 等宽，headline.bold + caption2）。

### 4.4 「换一批」机制

仅 `random`、`favoriteRandom` 模块头部有「换一批」按钮 → `model.regenerateRandomMusic()` / `regenerateFavoriteRandomMusic()` → `HomeStore.regenerateRandom` 本地 `shuffled().prefix(18)`。
> ✅ **纯本地重采样，不发网络请求**（源码注释明言；大库快照走 `Task.detached`）。

### 4.5 首页背景

渐变 `[background, accent 0.12, background]`，`topLeading → bottomTrailing`。

---

## 5. LibraryView（LibraryView.swift）

### 5.1 Scope 与默认

`LibraryScope` = `albums, tracks, artists, playlists, favorites, genres, categories`（**7 个** ✅）。**默认 = `.albums`**。分段 `Picker(.segmented)`。

### 5.2 TrackRow 视觉规格（✔ 48 / 圆角 10）

| 项 | 值 |
|---|---|
| 封面 | size **48**，cornerRadius **10** |
| 行 HStack spacing | `AuralisSpacing.medium` = 12 |
| 文本 VStack spacing | **3** |
| 标题 | `.body`（当前曲目 `.semibold` + accent 色） |
| 副标题 | `.caption`：`艺术家 · 专辑` |
| 右侧 | 已下载(arrow.down.circle.fill, success 色) / 已收藏(heart.fill, accent) / 时长 `.caption.monospacedDigit` |
| 行垂直 padding | 3 |

**Track 点击/长按菜单项**（tracks & favorites scope）：立即播放 / 下一首播放 / 加入队列 / 添加到歌单 / [删除本地缓存|取消下载|下载到本地] / [收藏|取消收藏]。

### 5.3 各 Scope 规格

| Scope | 布局 | 关键尺寸 |
|---|---|---|
| albums / playlists | `LazyVGrid(.adaptive(minimum: 142), spacing: 12)`，纵向 28 | 封面方形，title .headline，artist/count .caption |
| artists | `List` | 封面 **48 圆形**（cornerRadius 24），`N 张专辑` .caption |
| genres | `LazyVGrid(.adaptive(minimum: 150), spacing: 12)` | 卡片 minHeight 86、surface、圆角 14；**按歌曲数降序** |
| categories | 同 genres 栅格（adaptive 150） | 数据来自**本地 SQLite 推荐索引** `recommendationIndexCategories`（维度 mood/scene/…） |
| favorites / tracks | `List` + TrackRow | — |

顶部右侧有 **Settings gear**（→ settings）。专辑/艺术家 contextMenu：播放全部 / 收藏 / 下载全部。

---

## 6. BrowseDestination 枚举与分派（AuralisAppModel.swift:6527 / BrowseDetailSheet）

**枚举共 17 个 case（✔ 与用户「17 个」一致）**：
`album, artist, playlist, playlists, favorites, mostPlayed, genre, recommendationCategory, random, recentlyPlayed, recentlyAdded, longUnplayed, neverPlayed, favoriteRandom, topArtists, topAlbums, downloads`。

**BrowseDetailSheet 分派逻辑**：
- `.playlists` → 歌单总览列表（含批量删除/排序工具栏）
- `.topArtists` → 艺术家列表；`.topAlbums` → 专辑列表
- `.recommendationCategory` → `onAppear` 异步 `recommendationIndexTracks` 按需解析
- `.genre` → 本地筛选；为空时 `onAppear` 从服务器 `loadGenreTracks`
- 其余（album/artist/playlist/favorites/mostPlayed/random/recentlyPlayed/recentlyAdded/longUnplayed/neverPlayed/favoriteRandom/downloads）→ `trackList`
- 通用：顶部「播放全部」、下载全部确认弹窗；`random`/`favoriteRandom` 顶部工具栏有「换一批」

---

## 7. PlayerViews / Now Playing（PlayerViews.swift）

### 7.1 背景渐变（✔ accent 0.42 → accentSecondary 0.22）

`LinearGradient([accent.opacity(0.42), background, accentSecondary.opacity(0.22)], topLeading → bottomTrailing)`。

### 7.2 三页面与默认页

分段 `Picker`：歌词 / 正在播放 / 队列（`NowPlayingPage`）。**默认页 = `.player`（正在播放）** ⚠️ 注意：默认不是歌词。
控制区（标题、进度、传输、音量、底部信息）在三个页面间**固定不动**，仅上方内容区切换（`TabView` page 样式）。

### 7.3 传输区（五等分）

`transportControls`：5 个 `transportItem`（各自 `frame(maxWidth:.infinity)`，严格对称）：
1. 播放模式（顺序/随机/列表循环/单曲循环循环切换）
2. 上一首
3. **播放/暂停（中心，圆形 accent 填充 + 白字，size 56 或紧凑 64）→ 视觉权重最高** ✅
4. 下一首
5. 更多菜单

### 7.4 seek 的 pendingSeek 机制

`pendingSeek: Double?`（0…1）。拖动中 `displayedPlaybackPosition = pending*duration`；松手（`onEditingChanged(false)`）才真正 `model.playbackProgress = pending` 并提交 seek。`ThinSlider`：3pt 轨道，滑块 9→16（拖动放大），白点。VoiceOver 步进 = 5s/时长。

### 7.5 Favorite / Dislike

- 收藏（右，heart）44×44，accent 高亮；`toggleFavorite`。
- 不喜欢（左，heart.slash）44×44，与收藏严格镜像；`toggleDisliked` → **只影响未来自动推荐，不跳歌/不改队列/不暂停**。

### 7.6 更多菜单（完整项）

添加到歌单 / [下载到本地 | 取消下载(x%) | 删除下载] / 前往专辑 / 前往艺术家 / 由此继续播放 / 歌曲鉴赏 / 歌曲信息 / 音乐震动（Toggle，仅 iOS 可用时）。

### 7.7 音量 & 音频技术信息 & AirPlay

- 音量：`speaker.fill` + `ThinSlider`（步进 5%）+ `speaker.wave.3.fill`，maxWidth 420。
- 音频技术信息（`bottomInfo` 左按钮，waveform 图标）：默认显示 `effectiveCodec`（大写）；点击切换显示采样率/位深（`showsAudioTechnicalInfo`）。
- **AirPlay**：`RoutePickerView()`，位于 `bottomInfo` 右侧，44×44，label「AirPlay 输出设备」。

### 7.8 歌词 UI

居中（`alignment:.center`）；当前行 accent 色、scale **1**、opacity **1**；其余 secondary 色、scale **0.92**、opacity **0.62**；随播放位置自动滚动（`.smooth(duration:0.44)`，reduceMotion 时禁用动画）。无同步歌词 → 空态「暂无歌词」。

---

## 8. SearchView（SearchView.swift）

| 项 | 值 / 行为 |
|---|---|
| 防抖 | **150ms** ✅（`Task.sleep(for:.milliseconds(150))`，清空立即生效） |
| 空查询 | 显示「最近搜索」（`model.recentSearches`，可清除 `clearSearchHistory()`，点击回填并 `recordSearch`） |
| 本地无结果 | 显示在线搜索入口「在线搜索服务器」（`model.searchOnServer`）；`isServerSearching` 时 ProgressView |
| 结果分区 | 服务器在线结果 / 歌曲 / 专辑 / 艺术家 / 歌单（本地来自 `catalog` 过滤） |
| 搜索框 | magnifyingglass + TextField（占位「歌曲、专辑、艺术家或歌单」）+ 清除按钮(44×44) |

> 存储：`recentSearches` 由 `AuralisAppModel` 持有（历史记录数组，提交时 `recordSearch`，可 `clearSearchHistory`）。

---

## 9. Settings（SettingsView.swift / SettingsDetailPages.swift）

### 9.1 IA（✔ 与用户预期一致）

- **设置**：服务器 / AI 助手 / 播放与音质 / 数据与备份
- **外观**：首页布局 / 主题
- **关于**

### 9.2 服务器设置页

**字段**：服务器地址（TextField）、名称、用户名、密码（Keychain）；编辑页：`内网服务器地址` / `外网服务器地址（可选）`。
**测试连接状态枚举 `ServerConnectionViewState`**：

| case | 展示 |
|---|---|
| `.idle` | 「未连接」 |
| `.connecting(stage)` | ProgressView + `stage.title` |
| `.connected(account,_,_,trackCount)` | 「资料库：account.displayName」「已同步：N 首歌曲」 |
| `.failed(message)` | 「连接失败」+ message + 「重新连接」按钮 |

### 9.3 播放与音质设置项清单

| 分组 | 控件 | 默认 |
|---|---|---|
| 网络音质 | Wi-Fi 优先原始音质（Toggle） | true |
| 网络音质 | 蜂窝网络允许转码（Toggle） | true |
| ReplayGain | 模式（Picker） | 默认关闭 |
| ReplayGain | 前级 dB（Slider -12…12 step 0.5） | 0 |
| ReplayGain | 峰值保护（Toggle） | — |
| 音乐震动反馈(iOS) | 自动开启音乐震动（Toggle） | false |

> 注意：播放设置**不含**交叉淡入/crossfade/gapless；ReplayGain 默认关闭，优先用服务器 Track/Album Gain。

---

## 10. 与用户预期不符汇总（重点）

1. **Dock 高度历史值 72 已改为 56**（注释明示），当前 56/56/8/6 正确，但请勿沿用旧 PRD 的 72。
2. **Compact Mini Player 播放键为 42×44**，非 44×44（完整版才是 44×44）。
3. **完整 MiniPlayer 无进度条**（进度只在 Now Playing 完整页）。
4. **一级导航仅 3 个 Tab**，Search/Settings 不在 Dock：Settings 走 Library 顶栏 gear，Search 由 Assistant 页拉起 sheet。
5. **Now Playing 默认页是「正在播放」(player)，不是歌词**。
6. **Home 快捷入口固定 3 个**（歌单/收藏/最常听）；`playHistory` 未注册、`downloads` 属内容模块；内容模块默认 **6 开 3 关**（neverPlayed/topArtists/topAlbums 关）。
7. **「换一批」为纯本地重采样**（shuffle 取 18），不请求服务器。
8. **Library 默认 scope = albums**；genres/categories 栅格 minimum 为 **150**（非 142），genres 按歌曲数**降序**。
9. **AirPlay 位于底部信息行右侧**（音量行下方），非传输区。
10. Server 状态枚举 `connected` 携带 trackCount 用于「已同步 N 首」；`failed` 携带 message 文案。
