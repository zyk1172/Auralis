# 08. 服务器连接编排层与 AI 助手架构审计

> 源码只读审计。指导 Kotlin/Android 实现的规格报告。
> 涉及模块：`Application`（ProductionServerConnector / ApplicationComposition / ServerConnectionContracts / OpenSubsonicLibrarySyncSource）、`AppShell`（AppDomainStores.ServerStore / AssistantView / AgentCoordinator）、`Docs/AgentArchitecture.md`。

---

## 1. ProductionServerConnector 完整行为

`ProductionServerConnector` 是一个 `actor`（`ServerConnecting` 协议实现），负责：保存凭据、探测内外网端点、认证、能力探测、全量同步、失败回滚，以及此后所有按 `serverID` 路由的远程实体请求（歌词、专辑/艺术家收藏、评分、歌单、流地址、下载、搜索、ping 等）。

### 1.1 URL 归一化 / 校验规则（逐字引用）

**归一化（落库/进日志前的标准化）** —— `ProductionServerConnector.normalizedBaseURL`：

```swift
public nonisolated static func normalizedBaseURL(_ url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    if components.path.count > 1, components.path.hasSuffix("/") {
        components.path.removeLast()
    }
    // 剥离内嵌凭据：user:pass@host 中的密码不得随地址落库/进日志（凭据只进 Keychain）。
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.url ?? url
}
```

要点（Kotlin 实现必须一致）：
- scheme、host 强制小写；
- 仅当 `path.count > 1` 且以 `/` 结尾时去掉尾斜杠（根路径 `/` 保留）；
- 内嵌 `user`/`password`/`query`/`fragment` 一律置空（密码绝不落库/进日志/进备份）；
- 返回值规范化后参与 `stableServerID` 的 SHA256。

**校验（连接/编辑前）** —— `ServerURLPolicy.validate`：

```swift
public static func validate(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
          scheme == "http" || scheme == "https"
    else {
        throw ServerConnectionError.invalidURL
    }
    // 拒绝内嵌凭据（user:pass@host）：URL 中的密码会随地址明文落库、进日志与备份，
    // 违背「生产凭据只进 Keychain」的隐私模型。
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
       components.user != nil || components.password != nil {
        throw ServerConnectionError.embeddedCredentials
    }
    if scheme == "http", !NetworkHostClassifier.isPrivateOrLocal(host: host) {
        throw ServerConnectionError.insecurePublicServer
    }
}
```

另外 `validate(_:)` 还在 `connect` 内对 `displayName`/`username`/`password` 做空串检查（`.missingDisplayName` / `.missingUsername` / `.missingCredential`）。`username` 与 `baseURL` 在连接时 `trimmingCharacters(in: .whitespacesAndNewlines)`。

**稳定服务器 ID** —— `stableServerID(baseURL:username:)`：对 `normalizedBaseURL.absoluteString + "\n" + username` 取 SHA256，前缀 `server-`。同一「地址+用户名」恒得同一 ID（用于 Keychain 凭据 ID、SQLite 命名空间、辅助缓存命名空间隔离）。

### 1.2 连接流程（`connect`）

进度回调 `ServerConnectionStage`：`.validating → .storingCredential → .authenticating → .detectingCapabilities → .loadingLibrary → .savingLibrary`。

1. **validating**：`validate(input)`（URL 策略 + 显示名/用户名/密码非空）。
2. **归一化**：`normalizedURL = normalizedBaseURL(input.baseURL)`，`normalizedExternalURL = input.externalBaseURL.map(normalizedBaseURL)`，`username` 去空格。
3. **推导身份**：`serverID = stableServerID(...)`，`credentialID = "opensubsonic.\(serverID)"`。
4. **读旧状态（R12 前置快照，严格 throwing）**：
   - `previousCredential = existingCredential(id:)` → 返回旧密码或 `nil`；读取失败（非 `missing`）抛 `.secureStorageUnavailable`，**中止连接**，避免把读异常误判为「无账户」。
   - `previousAccount = persistence.account(id: serverID)`（读取失败直接抛错，中止）。
5. **storingCredential**：`credentialVault.store(input.password, for: credentialID)`（先存密码再认证）。
6. **authenticating**：`selectAuthenticatedClient(internalURL: normalizedURL, externalURL: normalizedExternalURL, ...)` —— 双地址并行探测并选端点（见 1.3）。
7. **detectingCapabilities**：`capabilities = (try? client.capabilities()) ?? ServerCapabilities()`（失败不致命，用空能力）。
8. **loadingLibrary**：`LibrarySynchronizer(source: sourceFactory(client), store: catalogStore, pageSize: 50, isRetryable: ...).sync(serverID:mode:.full)`，进度 `loadingLibrary / savingLibrary` 映射自 update stage。
9. **保存并提交**：`persistence.saveAccount(account)` → `catalogStore.upsertServer(account)` → `canonicalSnapshot` → `compactLegacySnapshot`。
10. **辅助数据（并行）**：`async let genres/playlists/starred`，成功后 `auxiliaryCache.save(playlists:genres:favoriteTrackIDs:serverID:)`；用 `getStarred2` 完整集合回填 `tracks[].isFavorite`（服务器收藏回流）。
11. **建立内存客户端**：`clients[serverID] = client`，`activeServerID = serverID`。
12. 返回 `ServerConnectionResult`（含 artists/albums/tracks/genres/playlists/serverType/serverVersion）。

**失败回滚（见 1.4）** 包裹第 6–12 步。

### 1.3 内外网探测与选择策略（准确逻辑）

枚举区分三类结果（注释原文：「端点探测只把『不可达』与『地址虽然可达但认证/协议不正确』分开；后者绝不能误切到外网」）：

```swift
private enum EndpointProbe: Sendable {
    case reachable(OpenSubsonicServerInfo)
    case unavailable
    case failed(ServerConnectionError)
}
```

`probe(_:)` 的判定（唯一权威来源）：

```swift
do { return .reachable(try await client.serverInfo()) }
catch let error as OpenSubsonicClientError {
    switch error {
    case .transport: return .unavailable
    case let .httpStatus(status) where status == 408 || (500...599).contains(status): return .unavailable
    default: return .failed(safeError(error))
    }
}
catch { return .failed(safeError(error)) }
```

`selectAuthenticatedClient` 选择算法：
- 单地址（`externalURL == nil` 或 `externalURL == internalURL`）：直接返回内网客户端（零额外网络）。
- 双地址：发起 `externalTask = probe(externalClient)`，并同步 `probe(internalClient)`：
  - 内网 `reachable` → `externalTask.cancel()`，返回**内网**；
  - 内网 `failed(error)` → `externalTask.cancel()`，**抛出该错误**（认证/协议/地址校验失败**绝不降级**）；
  - 内网 `unavailable` → 看外网 `externalTask.value`：
    - `reachable` → 返回外网；
    - `failed(error)` → 抛出错误；
    - `unavailable` → 抛 `.serverUnavailable`。

**「服务器不可达」与「账号密码错误」的精确区分**：
- **不可达** = `OpenSubsonicClientError.transport`（任何网络层错误）或 `httpStatus ∈ {408, 500..599}` → `.unavailable`，最终映射为 `ServerConnectionError.serverUnavailable`。
- **账号/密码错误** = 服务器可达但返回认证错误（`OpenSubsonicClientError.server(code,..)` / `.serverFailure` 且 code ∈ {40,41,50}）→ 经 `safeError` 映射为 `.authenticationFailed`，落在 `.failed` 分支，**原样抛出**，不会触发外网降级。
- 因此「内网可达但密码错」时，内网 `failed` 直接抛 `authenticationFailed`，UI 显示「认证失败，请检查用户名和凭据」；「内网断网、外网通」时走外网；「内外网都断」才 `serverUnavailable`。
- 探测请求 `requestTimeout: 30`（见 `makeClient`）。内网窗口最长 30s，期间 UI 不被阻塞（冷启动路径另走 1.3/2 的本地优先）。

### 1.4 失败回滚（恢复旧凭据/旧账号/旧本地状态）

`connect` 中第 6–12 步包在 `do/catch`：

```swift
} catch {
    await restoreCredential(previousCredential, id: credentialID)
    if let previousAccount {
        try? await catalogStore.upsertServer(previousAccount)
        try? await persistence.saveAccount(previousAccount)
    } else {
        try? await catalogStore.purgeServer(serverID)
    }
    throw Self.preservedError(error)
}
```

- `restoreCredential`：有旧密码则 `store` 回去，无则 `delete`（避免残留新密码）。
- 覆盖过已有账户（`previousAccount != nil`）→ 逆序恢复 `catalogStore.upsertServer` + `persistence.saveAccount`（杜绝「新 username/URL + 旧密码」）。
- 原本无账户（`previousAccount == nil`）→ `catalogStore.purgeServer(serverID)`，清除本次同步进 SQLite 的 orphan 数据。
- `preservedError` 保留原始 `errorDescription`，不让用户看到笼统「无法识别」。

**账户变更补偿辅助 `withAccountMutationRollback`**（用于 `updateServerConfiguration / updateServerDisplayName / updateServerExternalBaseURL / restoreAccountFromBackup`）：先快照 `previousAccount` + `previousPassword`（严格 throwing），`mutate` 闭包按 `credential → persistence → catalog` 写入；任一步抛错则逆序恢复 `catalog → persistence → credential`。

### 1.5 后台端点解析（冷启动不阻塞 UI）

`restoreConnection` 中（见 §2）：若 `account.externalBaseURL != nil`，自增 `endpointResolutionGeneration` 并 `Task { resolvedClient(for:) → 校验 generation 匹配 → clients[account.id] = client }`。代际校验保证：探测期间用户切到其它服务器/重新恢复时，迟到的旧探测结果**不会覆盖新状态**（`activeServerID` 不被旧探测改回）。`resolvedClient` 单地址直接 `restoreClient`，双地址并行 `selectAuthenticatedClient` 选端点。

### 1.6 重新同步（`resync`）

`resync(serverID:)` 与 `restoreConnection` 区别：后者只读本地快照（零网络），前者真正走 `serverInfo/capabilities/genres/playlists/starred + LibrarySynchronizer.sync(.full)`，重写 SQLite 快照并回填收藏。旧快照损坏/空时自愈界面。失败走 `safeError`。

---

## 2. 冷启动 Local-first 流程

真实调用顺序（App 启动）：
1. `ApplicationComposition.makeRuntimeDependencies()` —— 打开共享 `LocalCatalogStore`（SQLite，`ApplicationSupport/Auralis/catalog.sqlite`），失败依次回退到临时文件、`:memory:`、第二临时文件。
2. AppModel 调 `connector.restoreLastConnection()`（兼容入口：取 `persistence.accounts().first`）或显式 `restoreConnection(serverID:)`。
3. `restoreConnection`：
   a. `persistence.account(id:)` —— **只要求账号存在**；备份恢复的服务器可能还没有本地快照，返回空库结果让 UI 显示「已配置但未同步」，而非重加。
   b. `migrateLegacySnapshotIfNeeded`（JSON → SQLite 一次性 bridge）。
   c. `catalogStore.upsertServer(account)`。
   d. `restoreClient(for:)` 建内网客户端 → `clients[serverID] = client`，`activeServerID = serverID`（**零网络出界面**）。
   e. 若 `externalBaseURL != nil` → 后台端点解析（代际保护，见 1.5）。
   f. `canonicalSnapshot(serverID:)` —— 读 SQLite 快照（artists/albums/tracks），**冷启动不生成流 URL**（零工作量）。
   g. `auxiliaryCache.snapshot(serverID:)` —— 读本地歌单/流派/收藏 ID 回填 `tracks[].isFavorite`。
   h. 返回 `ServerConnectionResult`（capabilities 为空）。
4. UI 先渲染本地目录（HomeStore/LibraryStore 由该 snapshot 驱动）。
5. 联网后 AppModel 触发后台增量：`resync`（全量自愈）或 `refreshAuxiliaryData(serverID:)`（仅歌单/流派/收藏，离线返回 `nil` 保留缓存；单侧失败保留该侧旧缓存）。

关键：从本地恢复**不依赖「上次活跃服务器」旧行为**，按 `serverID` 恢复让「切换服务器」真正可用。

---

## 3. 多服务器：切换 / 隔离 / 当前 ID

- **路由隔离（R01）**：所有远程请求携带显式 `serverID`/`Track`，从 `clients[serverID]` 取客户端，**绝不依赖 `activeServerID`**（如 `lyrics/artworkData/genres/tracks(byGenre)/refreshStreamURL/serverSearch/serverTrack/downloadURL/scrobble/setFavorite/...`）。`activeServerID` 仅表示 UI 当前浏览的服务器，不改变既有 Track 的请求路由。
- **内存客户端表**：`private var clients: [ServerID: OpenSubsonicClient]`。
- **当前服务器 ID**：`public private(set) var activeServerID: ServerID?`（connector 内部），由 `connect`/`restoreConnection`/`resync` 设置；`disconnect()` 清空 `clients` 与 `activeServerID`。App 侧 `model.catalog.activeServerID` 与 `ServerStore` 暴露连接状态。
- **凭据隔离**：Keychain 键 `CredentialID("opensubsonic.\(serverID.rawValue)")`，每服务器独立。
- **持久化隔离**：`persistence.account(id:)` 按 serverID；SQLite 目录按 serverID 命名空间。
- **辅助缓存隔离**：`auxiliaryCache.snapshot(serverID:)` 各服务器独立命名空间。
- **切换**：`restoreConnection(serverID:)` 重建该服务器客户端并置 `activeServerID`。`forgetServer(serverID:)` 仅本地清理（删 Keychain + `persistence.removeServer` + `catalogStore.purgeServer` + `auxiliaryCache.purge` + `clients[serverID]=nil`），**绝不向远端发删除请求**。
- **切换防串库**：如 `DownloadStore` 在等待下载地址期间若 `serverIDProvider() != track.serverID` 直接取消，避免把新服务器音频写入旧服务器缓存槽。

---

## 4. ApplicationComposition 依赖装配图

唯一的组合根（`makeRuntimeDependencies`）。单例边界：

```
ApplicationComposition.makeRuntimeDependencies()
  ├─ makeCatalogStore(url:)                      // LocalCatalogStore（SQLite）
  │    ├─ 正式：ApplicationSupport/Auralis/catalog.sqlite
  │    └─ 回退链：临时文件 → :memory: → 第二临时文件 → preconditionFailure
  │        返回 (store, fallbackUsed: Bool)
  ├─ makePersistence()                           // FileBackedPersistence(library.json)
  │    └─ 失败 → InMemoryPersistence（仅存账号/配置/迁移态，音乐在 SQLite）
  ├─ serverURLSession()                          // URLSession(waitsForConnectivity=true,
  │                                             //   timeoutIntervalForResource=60)
  └─ ProductionServerConnector(
        credentialVault: KeychainCredentialVault(),
        persistence, catalogStore, session,
        sourceFactory: { client in OpenSubsonicLibrarySyncSource(client: client) })
     → 包进 ApplicationRuntimeDependencies(catalogStore, connector, catalogFallbackUsed)
```

- **单一目录 actor**：`catalogStore` 只创建/打开一次，注入 `connector` 与所有 catalog 消费者（CatalogCoordinator/AgentCoordinator/HomeStore/LibraryStore），避免重复打开或 split-brain。
- `connector` 是 `actor`，App 内共享同一实例；`sourceFactory` 注入 `OpenSubsonicLibrarySyncSource`（同步器 source，pageSize 50、有界并发 6）。
- `makeServerConnector()` 兼容旧调用点，等价于 `makeRuntimeDependencies().connector`。

---

## 5. AI 助手架构

### 5.1 分层结构

```
AssistantView / Siri / App Intent / 歌曲鉴赏入口
        │  (UI 适配、会话/确认/操作日志/偏好)
        ▼
AgentCoordinator (@MainActor)            ── 运行时协调器
        │  session / consent / operation-confirmation / UI citations
        ├──────────────┬─────────────────────────────┐
        ▼              ▼                             ▼
ConversationEngine  AgentRuntime          (Trust/Stateful Skill)
 (普通聊天循环)    (确定性工作流/状态)     RecommendationIndexSkillRuntime
        │              │
        └─────┬────────┘
              ▼
          ToolLoop
              │  SideEffectAuthorizationContext（逐操作最小授权）
              ▼
     AgentToolRegistry / AgentToolkit / SystemToolExecutor / AgentWebService
              │
              ▼
   各类 Tool：本地目录 / 播放 / 系统 / 网络 / Provider
```

- 普通聊天：`AgentCoordinator → ConversationEngine → ToolLoop`（无业务 `AgentTask`）。
- 确定性任务（如推荐索引）：`AgentCoordinator → AgentRuntime → ConversationEngine → ToolLoop`；`AgentRuntime` 只持任务状态、Workflow 路由与完成判定，不持 Provider/tool-call 循环。
- `AgentRunner` 仅为旧调用方转发 façade，生产调用链不经过它。

### 5.2 工具清单（分类）

> 注册表覆盖 100+ 工具；模型可见工具由 `tool_search` 动态发现，不是 Intent 永久裁剪。

- **本地目录 / 播放 / 队列**（缩小往返的批量工具）：
  `library_resolve_entity`、`library_get_songs_batch`、`queue_append_many`、`queue_play_next_many`、`queue_replace`（同参幂等、不同参可多次）、`play`/`pause`/`next` 等播放控制、`music_download`（模型 schema 拆为 `search/submit/status/tasks/history/history_remove/history_clean` 七个小工具）。
- **歌单 / 标注（写操作）**：
  `createPlaylist`、`renamePlaylist`、`removeFromPlaylist`、`replacePlaylistTracks`（**单次 updatePlaylist，禁止「先清空再追加」两步窗口 R02**）、`deletePlaylist`、`fetchPlaylistTracks`、`addTracksToPlaylist`（批量单次请求）、`setFavorite`、`setAlbumFavorite`、`setArtistFavorite`、`setRating`。
- **系统 / 设备 / 记忆 / 技能**（`AuralisSystemToolService` + `AgentMemoryStore`）：
  设备/网络/音频/存储/统计/诊断类工具；`memory_search`/`memory_save`/`memory_list`/`memory_delete`/`memory_clear`；`skill_create`/`skill_list`/`skill_read`/`skill_delete`。
- **网络 / Provider 可替换路径**：
  `web_search`（返回 `WebSource` 卡片，UI 可点击来源）、`web_fetch`（仅脱敏正文+URL）；由 `AgentWebService`（Tavily 全搜 + DuckDuckGo 即时答案回退）注入。`music_download` 之外，`externalMusicService`（歌曲鉴赏/公开音乐证据）属 Provider 侧能力。
- **推荐索引（可信 Stateful Skill）**：
  `recommendation_index_status`/`recommendation_index_read` 模型可见；内部 `prepareBatch`/`commit`/`verify` 等 primitive 仅 Skill 私有，注册表与 `tool_search` 均不可见。固定维度（情绪/场景/人声/质感/风格 + energy/tempo/acousticness/danceability）规范，开放语义 `dimension="tag"` 由 Agent 自创。

### 5.3 工具 Side Effect 与二次确认机制

- **唯一副作用边界**：`ToolRuntime.execute` → 先按 `ToolDescriptor` 校验参数 → `AgentToolRegistry.execute`。`AgentToolkit.execute/executeV2` 仅兼容别名，均转发注册表（不存在两套执行系统）。
- **最小授权**：`SideEffectAuthorizationContext` 只来自原始用户请求的 `lineage`（或恢复记录的 `goal`）；网页/搜索/模型文本**永远不能**产生授权。用户的自然语言请求只授权其所请求的 canonical operation；未精确授权的写操作 **fail closed**。
- **二次确认（运行时）**：只有 `ToolDescriptor.confirmationPolicy == destructive` 的不可逆删除工具才在副作用执行前**挂起等待 UI 批准**。受控工具：`playlist_delete`、`memory_delete`、`memory_clear`、`skill_delete`。确认属于具体 `runID`（非全局 continuation），避免后台 run 的确认被其它会话回答/被模型「确认」「继续」文本冒充。
  - `AgentCoordinator.requestOperationConfirmation(pending:runID:sessionID:)` → 挂起 `CheckedContinuation` → `AssistantView` 弹 alert（标题 `pending.title`、正文 `pending.detail`，按钮「批准并执行」/「取消」）。拒绝回灌结构化失败给模型，跳过桥接层。
- 写操作（收藏/评分/歌单增删）成功后会即时更新本地辅助缓存，并在 `AgentActionLog` 留记录（`actionRecords`，可 `undo` 可逆项、`clearActionLog`）。

### 5.4 隐私确认流程（首次外发）

- 触发门槛：`needsFirstSendConsent = provider == nil && resolvedProvider != nil`（仅真实 Provider 需确认；注入式 Mock Provider 用于测试，不走外发）。
- 持久化标记：`UserDefaults "auralis.ai.consentGiven"`（默认 false）。已写则直接放行。
- `AIPrivacyConsentRequest` 字段：`providerName`、`modelName`、`fields`、`purpose`。
  - `fields` 由当前 `AIPrivacyPermissions` 动态构造：
    - `allowsMetadata` → 「歌曲元数据（当前播放曲目）」
    - `allowsPlaybackHistory` → 「最近播放历史（最近 5 首）」
    - `allowsFavoritesAndRatings` → 「收藏与个人评分」
    - `allowsLyrics` → 「歌词（查询到时）」
    - `allowsExternalDiscovery` → 「公开网络检索（仅发送歌曲内容元数据）」
    - 固定追加「服务器名称与资料库统计（运行基础信息）」
  - `purpose` = 「处理你的音乐请求（搜索、播放、推荐、收藏等）」
- UI（`AssistantView`）：alert 标题「允许发送以下内容到「\{modelName\}」？」；按钮 **允许一次**（`approveConsent(remember:false)`）/ **允许并记住**（`remember:true`，写 `consentGiven`）/ **取消**（`denyConsent`，不发起网络请求，回本地提示）。无界面模式（Siri/快捷指令）无可见确认框，按默认 **拒绝** 处理。
- 边界：凭据/地址/token/cookie/authorization 在日志统一脱敏；上下文只含任务所需目录切片，**禁止整库、海报、流地址、文件路径外发**；歌词与播放历史受各自隐私开关约束。

### 5.5 会话管理能力（`AgentCoordinator` + `AssistantView`）

- **新建**：`newSession()`（绑定 `model.catalog.activeServerID`，自动激活）。
- **激活/切换**：`activate(id)`（只把目标 Session 的消息写 `messages`，仅 `activeSessionID == id` 更新屏幕；其余会话从 `SessionStore` 读取，互不串）。
- **搜索**：`sessionQuery`（标题/摘要/消息文本过滤）。
- **重命名**：`rename(id:to:)`，弹 alert 输入。
- **置顶**：`togglePin(id)`。
- **清空消息**：`clearMessages(id)`（并清该会话 `executionLineages`）。
- **删除（单）**：`delete(id)`（含当前会话则先 `revokeCurrentRun` 撤销运行权，再切下一或新建）。
- **批量归档**：`archive([UUID])`（会话列表多选 → 归档）。
- **批量删除**：`delete([UUID])`（会话管理页；含当前会话自动切换；逐个撤销后台 run 权再删除）。
- **取消归档**：`unarchive(id)`；列表可切换「显示已归档」。
- **操作记录（操作日志）**：`actionRecords`（`AgentActionLog`）；`undo(record)` 仅可逆项；`clearActionLog()`。
- **会话隔离（Session Isolation）**：消息以 Session 为唯一归属，`runID` 为运行身份；流式状态按 `runID` 隔离；迟到 callback（旧 runID）一律丢弃；唯一跨会话的是用户显式保存的 `AgentMemoryStore` 长期记忆。

### 5.6 Provider 不可用时的降级行为

- **不做关键词规则伪 Agent 降级**：复杂推荐、鉴赏、分类、歌单构建、资料库整理一律明确返回「AI 服务不可用」，不谎称切到本地模式。
- **Direct Read Fast Path（唯一例外）**：高置信度、只读、确定性状态查询（如「音乐库多少首 / 队列多少首」）在 Provider 缺失时仍直接执行一次 canonical read 返回真实数据——属性能优化，非离线模拟 AI。
- **普通聊天**：Provider 不可用时保留 Provider 错误语义，**不改写为本地音乐搜索**。
- **UI 表达**：`isLive = aiEnabled && settings.isComplete`；否则 header 显示「未配置模型接口」+「配置」按钮；空库提示「尚未连接服务器，本地目录为空」。本地搜索/播放完全独立于 AI 层，照常可用。
- **Provider 诊断**：`/v1/models` 区分模型 ID 问题与鉴权；文本/流式/原生工具/tool_choice 独立探测；`401 + ModelError` 报「模型/上游路由问题」而非「API Key 错」；仅目录确认仍含当前模型时有限重试两次。

---

## 附：Kotlin 实现关键检查清单

1. `normalizeBaseURL`：scheme/host 小写、去尾斜杠（仅 `path.count>1`）、剥离 user/password/query/fragment。
2. `validateUrl`：scheme∈{http,https} + host 非空 + 拒绝内嵌凭据 + http 仅私网/本机。
3. `stableServerId`：SHA256(normalizedURL + "\n" + username)，前缀 `server-`。
4. 连接阶段顺序与 progress 回调必须与 §1.2 一致；失败回滚三步（凭据恢复 / 旧账户逆序恢复 / 无账户则 purge）。
5. 端点探测：`.transport` 与 `408/5xx`=unavailable；其它（含认证 40/41/50）=failed，**failed 不降级外网**。
6. `clients` 按 serverID 路由，所有远程方法显式传 serverID；`activeServerID` 仅 UI 用。
7. 冷启动零网络出界面；后台 `refreshAuxiliaryData` 离线保留缓存、单侧失败保留单侧。
8. AI：副作用唯一边界在 ToolRuntime；仅 destructive 工具（playlist/memory/skill 删除）走 UI 确认；首次外发 consent 字段由隐私开关动态生成；Provider 缺失不降级为本地伪 Agent（仅 Direct Read Fast Path）。
