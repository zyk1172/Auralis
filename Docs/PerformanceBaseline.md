# Auralis 性能基线与验证方法

## 本次静态基线

本轮没有伪造耗时、FPS 或内存数字。命令行环境无法替代 Xcode Beta 真机 Instruments，
因此这里只记录可由源码确认的结构边界和已经实施的修复，数值基线留给下述真机流程。

已经存在并保留：

- `PlaybackStore` 局部发布播放位置与状态，避免整页订阅巨型 Model；
- `ArtworkStore` 使用缩略图/大图两组有界 `NSCache`，并处理 memory pressure；
- `ArtworkPipeline` 合并相同请求；
- ImageIO 按目标像素下采样，不在 SwiftUI View 中解码原图；
- `ArtworkDiskCache` 是 actor，磁盘访问不在 MainActor；
- `HomeSnapshotBuilder` 一次构建查找表并复用排序结果；
- Dock 滚动状态使用局部 Environment/Store 传播，而非每帧发布整个 AppModel。

本轮确认并修复：

- 万首曲库的首页快照曾在 `@MainActor` 同步执行多轮 filter/sort。现在小集合保持同步
  语义，大于等于 2,000 首时在 utility detached task 计算，以 generation/cancellation
  防止旧快照覆盖新目录；
- 搜索页的歌曲、专辑、艺术家和歌单 computed property 会在空态判断和列表构建时
  重复扫描。现在一次 body 只生成一份 `LocalResults`；150ms 输入防抖继续保留；
- Agent 统计曾在播放次数循环内反复 `first(where:)` 扫全库，形成 O(play-count × library)
  行为。现在每次统计先建立 TrackID 查找表；
- 本地网络 TCP 探测超时只结束 continuation、未结束 `NWConnection`。现在超时同步取消
  connection，释放 state handler 与计时器引用链；
- 封面缓存容量、不可用负缓存与波纹数组均有明确上限；未发现无限增长容器；
- NotificationCenter memory-pressure observer 的 token 由独立持有者在释放时清理。

## 真机 Instruments 基线

MANUAL-VERIFY: Xcode Beta Build/Test。使用 Xcode Beta 打开项目，选择用户实际 iPhone，
以 Release 配置运行。每项录制前强制退出 App，不清数据库或封面缓存；冷启动与热启动
分别录制，结果注明设备、系统、曲库歌曲数、缓存是否命中、连接是 LAN 还是 WAN。

### SwiftUI Instrument

1. Product → Profile，选择 SwiftUI；
2. 记录冷启动到首页稳定；
3. 首页连续快速滚动 30 秒；
4. 进入音乐库，在歌曲、专辑、艺术家、分类之间切换并高速滚动；
5. 播放中重复首页/音乐库/AI 助手切换；
6. 标记异常 body update、长 update group 和重复 view identity；
7. 对比“无封面命中”和“磁盘缓存命中”两轮。

### Time Profiler

分别录制：

- 冷启动与 SQLite Catalog 恢复；
- 同步完成后首页快照刷新；
- 搜索框连续输入与删除；
- 首页、音乐库高速滚动；
- 打开 Now Playing、歌词、队列并返回首页。

检查 Main Thread 的 self time，重点关注排序、字符串本地化匹配、图片解码、JSON/磁盘 IO
与 `objectWillChange`。保存 trace 后再填写具体毫秒数据，不根据肉眼猜测。

### Core Animation

开启 Hitches、FPS 和 Color Blended Layers，录制：

- Dock 展开/收拢；
- 首页带封面横向滚动；
- Now Playing 海报与环境光；
- 歌词滚动。

记录 hitch 时间点并回到 Time Profiler 对齐调用栈。液态玻璃本身的透明叠层不能只因
“ blended” 就判定错误，必须结合 hitch 和 GPU 时间。

### Allocations / Leaks

循环 10 次：打开/关闭 Now Playing、歌词、队列、AI 会话面板、服务器设置。然后观察：

- `ArtworkStore`、图片对象与 decoded bytes 是否回落；
- SwiftUI View/Task 是否持续累积；
- `NWConnection`、DispatchSourceTimer、Notification observer 是否留存；
- 播放切歌 50 次后 player item/observer 是否稳定。

### Network

分别在 LAN、WAN 和已有缓存下记录：

- 冷启动 Catalog 是否不必要重复拉全库；
- 同一封面尺寸是否合并请求；
- 列表缩略图是否请求目标尺寸而非原始大图；
- 播放、下一首预取、歌词和封面请求是否能按用途区分；
- 从 Wi-Fi 切蜂窝后是否只恢复必要请求。

## 建议记录表

每个场景记录：设备/OS、曲库规模、配置、冷/热、持续时间、峰值 RSS、主线程最重调用、
hitch 数、网络请求数、异常 retain 类型、trace 文件名。第一次实测结果作为 baseline；后续
只有同条件重复三次后才比较趋势。

## macOS 冷启动与 UI 性能基线（2026-08）

### 本轮已实施的结构性修复（代码可确认，非测量数字）

- 生产进程只有一个 `LocalCatalogStore`：`ApplicationComposition.makeRuntimeDependencies()` 在
  composition root 创建一次，Connector / CatalogCoordinator / Agent / 搜索 / V2 / 补全共用同一个
  actor；不再存在「Connector 一个 store、Coordinator 另一个 store」的 split-brain fallback。
- `SQLiteDatabase.init` 不再每次打开都同步执行 `PRAGMA quick_check`；改为
  `LocalCatalogStore.verifyIntegrityIfDue()` 的持久化时间策略（默认 7 天一次、后台执行、目录可用
  之后），数据库报错/异常关闭后仍会触发检查，不会永久删除完整性校验。
- `restorePersistedLibrary()` 先恢复账号与本地 Catalog；Agent（dislike 迁移等）移到后台，不再
  阻塞本地音乐库首屏。
- 冷恢复不再给全曲库生成 stream URL；`resolvePlayableTrack(_:)` 是唯一播放入口：
  本地缓存 → 现有 URL → 按需 `refreshStreamURL`，恢复后第一首点击播放仍能拿到 URL。
- `refreshCatalogFromStore` / `makeCatalogIndex` 移除 20,000 首静默上限；`catalogSnapshot(serverID:)`
  提供无上限完整快照（25,100 首回归测试覆盖，同步后数量一致）。
- Mac 歌曲表改用 O(1) `MacSongRowsRevision`（catalogRevision / metadata revision / 可见首尾 ID），
  播放进度 tick 不再重建 rows；`MacDetailTrackList` 使用真实 `LazyVStack`；艺术家「常听歌曲」只取
  播放过的 Top 12；艺术家选择改用 `GlobalID`；搜索用一次 `searchAll` FTS；Expanded Player 仅在
  context == .lyrics 时加载歌词；`MacExpandedWindowChrome` 只在窗口变化时重设布局。
- 启动阶段计时已落地 `StartupPerformanceTrace`（Observability）：Console 输出
  `AuralisStartup phase=... duration_ms=...`，同时写 os_signpost，Instruments 可直接拉时间线。

### macOS 冷启动阶段（与 StartupPerformanceTrace.Phase 对应）

| Phase | 含义 |
|---|---|
| APP_MODEL_INIT | AuralisAppModel 初始化 |
| PERSISTENCE_INIT | FileBackedPersistence / library.json 打开（记录字节数） |
| CATALOG_STORE_OPEN_CONNECTOR / COORDINATOR | 生产路径应只有一次（runtime 组合注入） |
| SQLITE_OPEN / SCHEMA / QUICK_CHECK / MIGRATIONS | SQLite 打开、建表、后台完整性、迁移 |
| RESTORE_ACCOUNT / LEGACY_SNAPSHOT_MIGRATION | 恢复账号、旧快照迁移 |
| RESTORE_ARTISTS / ALBUMS / TRACKS | 本地 SQLite → JSON decode，记录实体数 |
| RESTORE_STREAM_URLS | 冷恢复不再生成（应恒为 0） |
| APP_APPLY_DEDUPE / GENRES / LIBRARY_ADDED / HOME_SNAPSHOT | MainActor apply 各子阶段 |
| LOCAL_CATALOG_READY | 本地目录可用里程碑 |
| SERVER_CONNECTION_STATE_CONNECTED | 进入已连接状态 |
| BACKGROUND_SYNC_STARTED / FINISHED | 后台同步（不计入首屏时间） |

### macOS 本机 Instruments 流程

环境记录：Mac 型号 / macOS 版本 / 曲库歌曲-专辑-艺术家数 / catalog.sqlite 字节 /
library.json 字节 / LAN 或 WAN / 冷启动或热启动。

1. Time Profiler：启动 → 首页首次可交互 → `serverConnectionState == .connected`；把每个
   `StartupPerformanceTrace` phase 的 duration 与 Instruments 时间线对齐，明确“慢在哪一段”。
2. SwiftUI Instrument：Songs 10k+ / Albums / Artists / V2 / 大流派 / Home 滚动。
3. Core Animation：Expanded Player blur、窗口 resize、play/pause、歌词打开。
4. Allocations：展开/收起播放器 20 次、页面切换 30 次、服务器重连。

MANUAL-VERIFY：以上数值必须在真实测量后填写，禁止伪造；本轮只固化结构与测量流程。
