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
| 播放计数/最近播放统计 | annotationDao | Partial（统计查询待 UI 验证） |

## 3. 播放（audit 04）

| 能力 | Swift 基准 | Android 实现 | 状态 |
|---|---|---|---|
| 播放引擎（Media3/ExoPlayer） | AVFoundationPlaybackEngine.swift | core:playback AuralisPlaybackEngine | Done（骨架+核心回调） |
| 队列 occurrence（entry.id vs track.id） | — | QueueEntry + MediaItem.mediaId=entry.id | Done |
| 首响优先（先播当前曲、后台补窗口） | — | awaitPlayAt / fillWindowAround | Done |
| 播放历史/scrobble 防重复计数 | — | notifyActivated/notifyCompleted + sink | Done |
| Local/Remote 来源识别 | — | DefaultPlaybackSourceResolver + localSourceKeys | Done |
| PlaybackService 进程级单例 | — | AuralisPlaybackService | Partial（MediaSession/通知待 UI 阶段） |
| 队列窗口化（>500） | — | QueueWindowing | Partial（UI 阶段验证） |

## 4. 主题（audit 05）

| 能力 | Android 实现 | 状态 |
|---|---|---|
| 主题选择持久化（aurora-glass 默认） | AuralisPreferences.selectedThemeFlow | Done |
| 布局偏好 v1→v2 迁移 | homeLayoutFlow + migrateLegacySet | Done |
| 设计系统 token/组件 | core:designsystem | Partial（UI 阶段扩展） |

## 5. App Shell 与导航（audit 06）

| 能力 | Android 实现 | 状态 |
|---|---|---|
| 服务器列表/添加/编辑/删除/切换（UI） | feature:server（已接入 app-mobile 路由） | Done（S1） |
| 连接测试（不落库）+ URL 策略前置 | ProductionServerConnector.testConnection + ServerURLPolicy | Done |
| 三 Tab 导航（Home/Library/Assistant） | feature/*（app-mobile 壳） | Not Started（S2） |
| Bottom Dock / Mini Player | feature/player | Not Started |
| Settings 齿轮入口（Library 顶栏） | feature/settings | Not Started |

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
2. Mobile Shell + Bottom Dock（feature:home/library shell）← 当前阶段
3. Home 页
4. Library + Browse Detail
5. Mini Player / Now Playing / Queue / Lyrics
6. Search
7. Settings
8. Assistant
9. Android TV（app-tv）

> 最后更新：2026-09-07（P0 Core 九项 + S1 服务器链路完成，S2 Shell 进行中）
