# Auralis Android — 平台决策记录

> 迁移过程中与 Apple 实现不同的决策、理由与范围裁剪。每条都给出差异与原因，
> 供后续维护者（或反向往 iOS 回灌改进）参考。

## 1. core:data 全表带 `server_id` 列（相对 Apple catalog.sqlite）

**差异**：Apple 的 `favorites/ratings/play_history/downloads/lyrics` 只靠 `global_id`
前缀（`"{serverId}:{remoteId}"`）隔离服务器，无独立 `server_id` 列。Android Room 版本
**所有表都带 `server_id` 列并建索引**。

**理由**：
- 按服务器批量清理（删除服务器 → 清除其全部本地痕迹）只需一次索引查询，
  不需要 LIKE `'{sid}:%'` 扫描；
- 索引可为将来跨服务器统计/去重提供列级支持；
- 审计报告 03-local-catalog.md 明确建议补列。

**代价**：写入需冗余维护该列；由 DAO 层在 `upsert` 时统一从 `global_id` 前缀推导，调用方无感。

## 2. core:data 搜索：Room FTS4（`tracks_fts` 影子表）

目录规模需要 FTS，最终落地为 **`@Fts4` 影子表 `tracks_fts`**
（tokenizer `unicode61` 支持中文，`notIndexed = ["global_id"]`），由 DAO 在
`upsert/delete` 时同步维护，不依赖 SQLite 触发器（Room 外键/触发器在纯 Kotlin
管线配置繁琐）。查询一次性下发 `MATCH`，不在内存中 filter。

**多服务器隔离（P0-4 修正）**：FTS 行无独立 `server_id` 列，靠 `global_id` 前缀
归属服务器。清理时**禁止全表 `DELETE`**——先 `idsForServer(serverId)` 用子查询
`SELECT global_id FROM tracks_fts WHERE global_id IN (SELECT global_id FROM tracks
WHERE server_id = :serverId)` 捕获该服务器当前曲目行，再 `DELETE ... WHERE
global_id IN (:ids)` 精确清理，避免误删其它服务器索引。

## 2a. 目录提交为 Room 真事务（P0-4）

`commitCatalogSnapshot()` 整体包在 `database.withTransaction {}`：
1. 事务内先捕获该服务器旧 FTS id 集；
2. 删旧目录（tracks/albums/artists/genres 按 server）；
3. 分批写入新目录快照（`WITH_TRANSACTION` 内分批避免大事务锁库）；
4. 按 server 精确删 FTS、再插新 FTS 行。

任一步失败整体回滚——**不会出现“目录已删但收藏/播放记录残留”的中间态**。
`deleteServer()`（忘记服务器）同样单事务清理 server-scoped 目录 + FTS +
annotations + downloads + sync 元数据。

## 2b. 多服务器凭据与路由（P0-1/2/3）

- **唯一来源 = 进程级 `ServerClientRegistry`**（serverId → `ResolvedServerEndpoint`
  `(baseUrl, kind, client)`）；`AuralisGraph` 不再维护第二份易漂移的 accountCache。
  所有远程操作 `registry.client(serverId)`，**禁止**默认回落内网。
- **端点双地址**：服务器可配内网 `baseUrl` + 外网 `externalBaseUrl`；
  `EndpointKind.Internal/External` 与选中结果持久化到 DataStore，重启按上次路由恢复。
- **连接探测语义**：内网可达（ping/认证/协议均过）→ 用内网；内网**认证或协议失败
  → 直接失败不切外网**（避免把明文密码发到公网）；内网**不可达 + 有外网** → 试外网。
- **凭据回滚（P0-2）**：`connect()` 连接前快照 `previousSecret`；失败时恢复旧
  secret 或删除全新的 credential reference，恢复 `previousAccount` 激活态；
  全新服务器首次连接失败**不留 orphan**。`rollback()` 是唯一回滚路径。

## 2c. 收藏/评分/历史：远端先行，成功才落本地（P0-5/6）

- `LibraryActionCoordinator`：star/rating/scrobble 一律**远端服务器先行**，成功才写
  Room 注释表；失败不改本地、不留假状态（UI 乐观态由上层回滚）。按 `serverId` 取
  客户端，单服务器故障不影响其它服务器。
- `PlaybackHistoryCoordinator`（实现 `PlaybackHistorySink`，由播放引擎在
  `MediaItemTransition`/`STATE_ENDED` 回调）：occurrence 级去重
  （`started`/`completed` HashSet），防「STATE_ENDED + MediaItemTransition +
  窗口 refill」三重重复计数；完成时 `markCompleted`（只翻 completed 不叠加
  playCount）+ `scrobble(submission=true)`。开关由设置控制，默认开。

## 2d. 下载：三并发闸门 + 节流 + 前台服务（P0-7）

- 真实并发上限 `Semaphore(3)`（非注释承诺）：`submit()` 统一入队（等待队列 +
  拿到许可才进 `runningKeys`），enqueue 与水合走同一路径，**进程启动不会把上百条
  恢复任务同时 launch**。
- 进度写库节流：`progress ≥ +1%` **或**距上次落库 ≥250ms 才写 Room；UI 高频显示走
  内存 `StateFlow`（`runningCount`/`activeCount`）。
- `DownloadService`（foregroundServiceType=`dataSync`）由 `activeCount` 0→1 拉起、
  归零 stopSelf；Manifest 已注册 + `FOREGROUND_SERVICE_DATA_SYNC` 权限。
- 取消用墓碑集合（tombstones）防重绑；下载 URL 运行时由 urlFactory 生成，绝不持久化
  带认证 URL。

## 2e. 歌词：本地优先 + 远端降级 + 写回（P0-8）

- `RoomLyricsRepository` 以 `track.globalId.serialized` 为 key 落 annotation 表；
  `LyricsServiceImpl`（core:lyrics）组合 `store` 与 `remote`：本地命中即返回；
  未命中走当前服务器客户端（结构化歌词 → 纯文本兜底），成功即写回本地。
- 与 Apple 侧 `LyricsStore` 语义对齐（结构化/纯文本双通道，保留原文绝不丢弃）。

## 3. core:ai 只实现 Chat Completions（相对 Swift AIKit 双协议）

**差异**：Swift `OpenAICompatibleProvider` 同时支持 Chat Completions、Responses API 与
Anthropic Messages。Android 子集**只实现 Chat Completions**（`/v1/chat/completions`）。

**理由**：
- 本 App 主要对接 Navidrome 生态用户自建的 OpenAI 兼容网关（LM Studio / Ollama /
  DeepSeek / OpenRouter 等），全部走 Chat Completions；
- Responses API 的 hosted web 工具依赖不同请求结构，Android 首版不承诺。

**行为**：`apiPath` 命中 `/responses` 或 Anthropic `/messages` 时抛出
`AiProviderException`（IncompatibleRequest），不静默降级。

## 4. AI 工具循环语义与 Swift AgentKit 对齐但规模裁剪

Android `AgentToolLoop` 保留了审计 §5.2/5.3 的**三条不变式**：
1. 副作用唯一边界 = `AgentToolRegistry.execute`（先校验后执行，无第二套执行系统）；
2. 最小授权：`SideEffectAuthorizationContext` 只来自用户请求解析出的 canonical
   operation；未授权写操作 `fail closed`；
3. 仅 `Destructive` 工具（playlist/memory/skill 删除）在副作用前挂起等 UI 确认，
   确认绑定具体 run（由上层 Coordinator 负责）。

**裁剪**：`tool_search` 动态发现、RecommendationIndex Skill、`AgentRuntime` 工作流、
`AgentActionLog`（undo/clear）放到 feature/assistant 或后续迭代，不进 core:ai。

## 5. 流式工具调用：按 index 跨 chunk 拼接，流末统一产出

对齐 Swift `chatStream`：`delta.tool_calls` 的 id/name/arguments 分片按 `index` 累积，
到 `[DONE]` / `finish_reason` / 自然结束才 flush 完整 `AiToolCall`，避免参数截断。
`reasoning_content` → `ReasoningDelta`（绝不持久化）；无法分类的正文 → `UnknownDelta`
（保持可见，绝不静默丢弃）。

## 6. 400/422 参数降级边界

仅当服务端 detail 提到 `temperature` / `max_tokens` 时做字段名适配重试一次；
**绝不删除 tools/tool_choice**——网关不支持原生工具时保留原错误，让上层报告原生协议失败。

## 7. Gradle / SDK 基线

- Gradle 8.9（本地 wrapper 分发网络受限，用同版本本地 Gradle 驱动；`gradle-wrapper.properties`
  已就位，联网环境 `./gradlew` 可直接用）
- JDK 17（`$HOME/Library/Java/JavaVirtualMachines/jdk-17.0.20.1+1`）
- compileSdk 34 / minSdk 26 / targetSdk 34，Kotlin jvmTarget 17
- 模块：11 core + 7 feature + app-mobile + app-tv（TV 不含 feature:assistant 与 core:ai）

## 8. 测试策略

- core:data：Robolectric + Room in-memory（`room-testing`）+ MockWebServer。
  FakeVault/SubsonicJson/enqueueCatalog 等测试件见 `core/data/src/test/TestSupport.kt`。
- core:offline：Robolectric + MockWebServer 真网络下载（Semaphore 并发、节流、水合）；
  MockWebServer `throttleBody` 提供可控时长。**注意**：并发断言等待预算已放宽
  （密集采样峰值 + 15s 完成上限），避免并行负载/首轮预热导致抖动。
- core:ai：MockWebServer 集成（非流式/SSE 碎片拼接/参数降级/错误分类）+ FakeProvider
  循环语义测试。
- 单测跑在 Android library 模块的 `testDebugUnitTest`（JVM），无需设备。

## 9. App 壳与页面导航规划（对齐 audit 06）

- 底部一级导航只有 **3 个**：Home / Library / Assistant（Dock 圆按钮）。
- **Settings 不在 Dock**：Library 顶栏齿轮入口。
- **Search 不在 Dock**：由 Assistant 页以 sheet 拉起「搜索音乐库」。
- Android 不把 Search/Settings 做成底部 Tab。

## 10. 状态：2026-09-07 快照

- **P0 Core 九项全部落地并配真测试**：core:data（注册表/路由/回滚、FTS 多服务器隔离、
  真事务目录、收藏回流、历史/scrobble、歌词仓库）+ core:offline（并发/节流/水合）
  + core:ai 单测全绿；core:playback 编译通过（sink 已装配到引擎）。
- 具体：`ServerClientRegistry`/`ProductionServerConnector`（P0-1/2/3）、
  `withTransaction` 目录提交（P0-4）、`LibraryActionCoordinator`（P0-5）、
  `PlaybackHistoryCoordinator` + 引擎 occurrence 去重（P0-6）、
  `DownloadManager` Semaphore(3)+节流+Service（P0-7）、`RoomLyricsRepository` +
  LyricsService 组合（P0-8）、首响优先 + HomeLayoutPreference v2 + 主题 DataStore
  闭环（P0-9）。
- feature/* 七个模块为空壳，待填充页面（下一步：Server 添加/恢复链路）。

## 2f. 服务器 UI 链路（S1，2026-09-07）

- **URL 策略前置**：`connect()`/`edit()`/`testConnection()` 先过 `ServerURLPolicy`
  （拒绝内嵌 `user:pass@`；公网必须 HTTPS），校验在写 Vault 之前，失败零副作用。
  主机分类镜像 Swift `NetworkHostClassifier`（localhost/.local/IPv4 私网/回环、
  IPv6 ::1/ULA/link-local/IPv4-mapped/zone id），测试覆盖见 ServerURLPolicyTest。
- **`testConnection`（对齐 testServerConnectionWithInput）**：用**内存 Vault** 构造
  客户端探测，不保存凭据、不同步、不改变当前连接；成功只回服务器公开信息。
- **编辑身份稳定（对齐 updateServerConfiguration）**：新增 `edit()`，沿用既有
  serverId/凭据引用——改地址/用户名不新建重复服务器、不删已同步目录；
  密码留空 = 沿用本机已存凭据；失败走同一 rollback 恢复旧账户+旧凭据。
- **UI 规则**：保存按钮 canSave（必填齐全 + 非 busy）；连接中显示 stage 标题
  （检查地址/保护凭据/验证服务器/…）；失败折叠详情；删除服务器二次确认（只删本地）。

## 2g. Mobile Shell（S2，2026-09-07）

- **Shell 在 app-mobile**（跨分区的 Dock/Mini Player 属应用级，不做成 feature 模块）；
  分区占位页先放 app-mobile/shell，真实页面（feature:home/library/assistant）后续按
  S3/S4/S8 逐个替换接线。
- **Dock 语义对齐 iOS**：一级分区只有 Home/Library/Assistant（Search/Settings 不进
  Dock）；Assistant 为圆形 accent 钮（sparkles）；宽屏最大约 760dp 居中，悬浮 overlay
  + 系统导航条安全区。
- **Mini Player 真绑定**：订阅 `LocalPlaybackHost` → `PlaybackSnapshot`（封面/标题/
  艺人/播放暂停），仅 Home/Library 分区显示，无播放内容时隐藏；展开 Now Playing 属 S5。
- **服务器/设置入口**：服务器管理按 iOS 语义放在 **Settings**（Library 顶栏齿轮 →
  设置占位，含真实「服务器」行 → feature:server 列表）；首页摘要卡也提供真实入口。

## 2h. Home 首页（S3，2026-09-07）

- **模块注册表驱动**：`core:domain/Home.kt` 三枚举（`HomeQuickEntry` 3 个 +
  `HomeModuleId` 9 个含 downloads 无 playHistory + `HomeLayoutPreference` v2）对齐
  Swift `HomeModule.swift`/`HomeLayoutStore.swift`。布局有序 JSON 存 DataStore
  （key `auralis.home-layout.v2`，v1 Set 迁移保留）。
- **读写一律归一化**：`HomeLayoutPreference.normalized()`（丢弃未知 ID / 数组顺序为
  权威 / 去重 / 补齐注册表新模块按默认可见性追加末尾）在 `homeLayoutFlow` 读路径与
  `setHomeLayout` 写路径都执行——防旧版本/未来版本数据污染 UI 与注册表不一致。
- **首页数据快照全部真实 SQL 派生**（对齐 Swift `HomeSnapshotBuilder` 语义，不做
  内存全表遍历）：random/favoriteRandom = `ORDER BY RANDOM()`；recentlyPlayed =
  play_history 倒序；longUnplayed/neverPlayed = 排除窗口内/从未播放；recentlyAdded =
  30 天窗口（dateAdded）；downloads = JOIN downloads state='Downloaded' 倒序；
  topArtists/topAlbums = JOIN tracks + play_history 按真实播放量聚合降序。
- **「换一批」= 本地重采样**：仅 random/favoriteRandom 显示，SQL 本地重取
  （`RESHUFFLE_SAMPLE=18` 对齐 Apple 取 18），**不发网络**。
- **目录变化自动刷新**：`RoomCatalogRepository.homeChangeSignals` combine 5 路
  Room `observeCount` Flow（曲目/专辑/收藏/播放/下载计数）→ `distinctUntilChanged`，
  避免监听后全表解码；关闭模块不渲染**也不查数据**，开启但无数据暂不渲染但配置保持。
- **UI 布局**：快捷入口 3 列（icon+count，不显示长文字主体）；内容模块标题行
  「换一批」/「数量 ›」；曲目/艺人/专辑 shelf 卡片固定 140dp（对齐
  `AuralisChrome.homeCardWidth`）；`BrowseDestination` 已含 Downloads（Home 独有）。
- **布局编辑**：上移/下移 IconButton 排序（SwiftUI onMove 拖拽在 Android 用按钮
  替代，语义对齐：本地数组为唯一数据源，改动即时持久化）；「恢复默认布局」走
  AlertDialog 二次确认；Home 入口在 设置 →「首页布局」行（S3 已接 Settings 占位）。
- **播放/浏览真实动作**：货架点击 = `playQueue(entry 序列, startIndex)`；引擎未就绪
  先 `startPlaybackService()`（幂等）并停手——**不假装已播放**；首页浏览请求
  （快捷入口/数量›/艺人专辑卡）切 Library 分区携带 `BrowseDestination`
  （pendingBrowse，完整浏览页 S4 实现，占位非假数据）。

## 2i. Library + Browse Detail（S4，2026-09-07）

- **音乐库 7 scope 分段**（albums 默认 → tracks/artists/playlists/favorites/genres/
  categories，横向滚动胶囊近似 Swift segmented picker）：每个 scope 内容全部来自真实
  本地目录（Room Flow 观察 / 一次查询），无任何伪造数据；`categories`（AI 推荐索引）
  Android 第一版无数据源 → 显示能力说明（`Categories.NOT_PORTED_MESSAGE`），空态承接、
  不渲染假列表。
- **流派语义**（对齐 Swift `tracks(for:)` 过滤）：`genreTracks(serverId, name)` 内存
  过滤 track.genres（大小写不敏感），空流派 scope 不显示。
- **Browse 覆盖路由**：Home 内浏览请求切 Library 分区并在其内容上方覆盖
  `BrowseDetailScreen`（页面自带内部返回栈：常听 → 专辑/艺术家详情）；顶栏返回回库根、
  再点 Library Dock 回库根、系统返回键关闭覆盖页。
- **BrowseDetail 17 目的地全部承接**：album/artist 按 GlobalId 解析实体；playlist 先
  `playlistActions.refreshPlaylist`（服务器单数拉取落本地，失败降级展示本地曲目）；
  favorites/mostPlayed/recentlyPlayed/recentlyAdded/longUnplayed/neverPlayed/random/
  favoriteRandom/downloads/genre 全走本地 SQL 派生（`DETAIL_TRACK_CAP=1000`）；
  topArtists/topAlbums 按真实播放量降序。
- **多服务器隔离**：目的地未显式携带 serverId（列表类）时在加载期解析
  `preferences.activeServerIdFlow.first()` 落到当前激活服务器，绝不跨服务器合并；
  专辑/艺术家/歌单详情按 GlobalId（内含 serverId）直接查询。
- **详情动作**：头图 88 + 播放全部 + 下载（确认弹窗估算体积，enqueue 幂等跳过已下载）；
  点行 = 整组作新队列从该行起播；random/favoriteRandom 右上「换一批」= reloadKey 驱动
  本地重采样重载；歌单顶栏 ⋯ 管理菜单（重命名/复制「原名 副本」/去重/删除，全部远端
  先行、成功落本地并刷新详情标题与曲目）。
- **歌单行级「从歌单移除」**：行尾 ⋯ 追加槽位（`additionalMenuItems(close)`，关闭行菜单
  回调），二次确认后 `playlistActions.removeAt`（服务器 removeIndex 语义）成功刷新整表。
- **播放动作接线**：Shell 新增 `playNextShelf`（`insertNext` 插当前曲后）与
  `appendQueueShelf`（`appendToQueue` 队尾追加不打断）；引擎未就绪一律先
  `startPlaybackService()` 再停手，不假装成功。
- **歌单写操作集中在 `PlaylistCoordinator`**（`PlaylistRemoteOperationException` 统一
  包装远端失败）：rename/addTracks/removeAt 远端成功后用 getPlaylist 单数拉最新整表替换
  本地（对齐 loadPlaylistTracks），不做本地猜测；只读歌单禁止修改/删除但可复制。
- **行徽标实时驱动**：行内已下载/已收藏徽标分别由 downloads 表行级 observe 与
  favorites 计数信号（`observeFavoriteTracks` flatMapLatest 重查）驱动，非静态快照。

## 2j. 播放器 UI（S5，2026-09-07）

- **位置节拍（engine.position）**：快照只在播放器事件时发布，长时播放会“静止”；
  S5 在引擎新增 250ms `position` StateFlow（值不变不发布），进度条与同步歌词都订阅它，
  不抬高整体快照的重组频率（Shell 仍订阅低频 snapshot）。
- **Mini Player = 展开入口**：点封面/标题区打开 Now Playing 全屏页（覆盖 Dock）；胶囊内
  上一首/下一首真实绑定 engine.previous/next，canPrev/canNext 由队列游标决定（当前项
  logicalIndex>0 / < totalCount-1），缓冲中播放键位显示 spinner 而切歌保持可用。
- **Now Playing 覆盖路由**：Shell 层 `nowPlayingOpen` 单处理器 BackHandler（NP 优先于
  Browse 覆盖页）；页面内三页共用同一套固定控制区（标题/进度/五键/音量/音频信息），
  切页不跳布局——对齐 Swift “controls pinned below TabView”。
- **进度拖动 = 松手 seek**：拖动只更新本地 fraction 显示，`onValueChangeFinished` 才
  `seekTo(fraction×duration)`（对齐 pendingSeek）；显示剩余时间为负值格式。
- **五键等宽传输区**：播放模式循环为引擎真实状态（Sequential→Shuffle→RepeatAll→
  RepeatOne，顺序与 Swift cyclePlayMode 一致），非本地假切换。
- **队列页**：展示引擎真实窗口 entries（>500 窗口化时给“N–M / 总数”计数提示与队尾
  “已到末尾”不伪造）；点行 = playOccurrence(entryId) 精确播放该 occurrence；编辑模式
  提供移除/上移/下移（removeOccurrence/moveOccurrence 逻辑下标，窗口内行号映射
  windowStart+i）。
- **同步歌词**：LyricsServiceImpl 本地缓存→远端→miss 负缓存；页面按 positionMs 求
  当前行并 animateScrollToItem 居中；空态与错误重试文案对齐 Swift。纯文本歌词只平铺
  不高亮。
- **本阶段裁剪**（文档记录，不作假按钮）：不喜欢（heart.slash）、歌曲鉴赏、由此继续
  播放（AI 工具链，S8 Assistant 接）、Music Haptics（平台特性）、AirPlay 输出选择
  （Android 无对应）；播放模式/音量/下载/加歌单/收藏全部真实。

## 2k. 搜索（S6，2026-09-07）

- **入口 = Assistant 顶栏放大镜**（对齐 Swift `AppSection.compactDockSections`：Search 不是
  一级 Tab，注释明确“搜索保留为助手内的兜底能力”）：S6 在 AssistantPlaceholderPage 顶栏
  提前启用真实放大镜按钮 → MobileShell 全屏覆盖 SearchScreen（sheet 语义的 Android 近似）；
  S8 重做 Assistant 主体时保留同一入口，不加 Swift 没有的其它搜索入口（Home/Library 不加）。
- **本地优先 + 服务器兜底**：本地四类结果走 `catalogRepository.search`（曲目 FTS4 unicode61
  真查询、专辑/艺人/歌单索引 contains——绝不在内存过滤一万首）；本地空时才可点
  “在线搜索服务器”走 OpenSubsonic `search3`（新增 `AuralisGraph.serverSearch`：artistCount/
  albumCount=0、只映射歌曲为 Track，对齐 Swift serverSearch 只返回 [Track]）。
- **150ms 防抖**：query 变化立即清服务器结果（对齐 `.task(id: query)` 的 clearServerSearch），
  停顿后才更新 debounced 触发本地查询；点历史 chip 直接置 debounced 跳过防抖（对齐 Swift）。
- **R15 失败语义**：在线搜索“进行中 / 有结果 / 失败”三态分离，失败显示错误与重试入口，
  不把网络失败伪装成“无结果”；无激活服务器时按钮给出明确提示（不静默）。
- **搜索历史已就绪**：DataStore（`auralis.recent-searches`，分隔符 \u001f）在 P0 阶段已建，
  S6 直接消费；recordSearch 时机 = 键盘提交 / 点任意结果 / 点历史 chip（对齐 Swift）。
- **结果动作**：歌曲行 → `playQueue([track], 0)` 单曲播放（对齐 Swift selectAndPlay(track)
  的“单曲播放”语义；Swift 保留旧队列并插到队首，Android 无该引擎 API，S6 采用单曲开新队列，
  文档记录差异）；专辑/艺术家/歌单 → Shell.openBrowse 切 Library 打开 BrowseDetail。
- **本地结果当前曲高亮裁剪**：Swift TrackRow 的 isCurrent 指示依赖全局播放游标，S6 未做
  （文档记录；后续如需可经 Shell 传入 playback 快照实现）。

