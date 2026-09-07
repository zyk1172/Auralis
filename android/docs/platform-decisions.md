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
