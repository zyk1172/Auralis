# 09 · S8 AI 助手审计：Swift 规格 → Android 能力映射

> 阶段：S8 Assistant。范围：Swift `AssistantView` + `AgentCoordinator` +
> `AuralisAgentBridge` + `AISettings` 的 Android 对齐实现。
> 结论先行：Android 子集按「真实、诚实、fail-closed」三原则实现，不伪装本地模式。

## 1. Swift 规格要点（逐行核对来源：AppShell/AssistantView.swift、AgentCoordinator.swift、
AuralisAgentBridge.swift、AISettings.swift、SettingsView.swift:646-657、AssistantRunPresentationState.swift、
AgentMemoryStore.swift）

1. **入口**：Assistant 是 Dock 一级分区（compactDockSections=[.home,.library,.assistant]），非设置内行。
   设置内 "OpenAI 兼容接口" 行的「配置」按钮与 Siri 兜底均可跳转；Android 对齐：Dock 分区 + 设置 AI 行入口。
2. **Header**：左状态标签 —— isLive（aiEnabled && settings.isComplete）时绿勾 + model；否则黄三角 + 「未配置模型接口」。
   右：`搜索音乐库`(magnifyingglass→.librarySearch sheet，S6 已落地)、`会话列表`(sidebar→.sessions sheet)。
   仅 !isLive 时额外显示 `配置`(gearshape)。
3. **会话模型**：`AgentSession(id,title,messages,createdAt,updatedAt,isPinned,isArchived,summary)`
   持久化 `agent-sessions.json`。消息 `AgentChatMessage(role:.user/.assistant, messages:[AgentMessage])`；
   `AgentMessage` 类型含 .text/.streaming/.reasoning/.trackCards/…/.toolProgress/.error/.confirmation。
   - 流式增量不写盘，收尾定稿落一次；
   - runID=UUID；迟到 callback 凭 ownsRun(runID,sessionID) 丢弃，绝不污染新 run；
   - 回灌策略：完整会话文本但**丢弃 transient**（.reasoning/.toolProgress/.actionPreview/.confirmation）；
     reasoning 只做瞬态展示，绝不进 transcript。
4. **消息 UI**：用户气泡 accent.opacity(0.22) 右对齐 maxWidth560；助手气泡 elevated 左对齐 + copy 按钮；
   streaming 尾部 ▌呼吸光标；发送/停止随 assistantIsRunning 切换；空状态（未连服务器）提示但本地搜索/播放照常。
5. **隐私/确认**：开关 `@AppStorage("auralis.ai.enabled")` 默认 true；首次外发 `pendingConsent`
   标题「允许发送以下内容到「模型名」？」按钮 **允许一次/允许并记住/取消**；
   "允许并记住" → 写 `auralis.ai.consentGiven=true`。
   破坏性二次确认 `pendingOperationConfirmation`：**批准并执行/取消**，文案来自 OperationConfirmation(title,detail)。
6. **工具桥**：canonical 工具按 readOnly/reversible(可撤销)/destructive(需确认) 分类（完整清单已核对，
   Android 取**真实可执行子集**，命名保持与 Swift canonical 完全一致，见 §3）。
   参数形状例：playTrack/playAlbum/playPlaylist/likeTrack 均 `{"globalID":{"serverID","remoteID"}}`；
   searchTracks `{"q":…}`；setRating `{"globalID","rating"}`；addTracksToPlaylist `{"playlistGID","trackGIDs"}`。
   模型不可见、UI 可见的**操作日志**：agent.actionRecords（agent-actions.json），reversible 可撤销。
7. **AI 连接设置**：baseURL(默认 https://api.openai.com)/apiPath(默认 /v1/chat/completions)/
   model(默认 gpt-4o-mini)/maxContextTokens/maxOutputTokens；凭据 Keychain credentialID=`ai.provider.api-key`，
   不落 UserDefaults；isComplete = baseURL 合法 + apiPath 非空 + model 非空；「测试连接」→ 绿勾+diagnosticSummary / 红叉。
   保存即实时（@AppStorage 双向绑定）。
8. **错误呈现**：不假装本地模式 —— consent 拒绝给引导文案；Provider 错误红字如实显示（401/路由问题由 Provider 分类上报）；
   本地搜索/播放不依赖模型照常可用。

## 2. Android 现状盘点

- core:ai 已具备（P0）：`AiProvider` + `MockAiProvider`（仅连接测试注入用）、`OpenAiCompatibleProvider`
  （Chat Completions、SSE 流式、tool_calls 拼接、reasoning 瞬态分类、错误分类 401）、`AiModels` 全套消息/流/错误模型、
  `AgentToolLoop`（工具循环、fail-closed 授权、Destructive confirm 挂起、run 事件流）。
- **缺口**：无 AI 连接配置存储（DataStore）；无 aiEnabled/consentGiven；无会话持久化
  （agent-sessions.json）；无工具注册表实例化（AuralisAgentBridge 等价物）；无 AgentCoordinator 编排层
  （runID 隔离/停止/回灌过滤/consent 流/操作日志）；feature:assistant 为空骨架。
- 可支撑工具执行的既有能力：graph.serverSearch / catalogRepository.search & 实体查询 /
  libraryActions（收藏/评分，远端先行）/ playlistActions（建/改名/加/删/删，远端先行）/
  LocalPlaybackHost.controller（playQueue/insertNext/appendToQueue/clearQueue/seek/pause/resume/…）/
  graph.lyricsService / preferences + vault（Keychain 等价）。

## 3. Android 决策（对齐 Swift canonical，取真实可执行子集）

- **配置存储**：AuralisPreferences 增加 AI 段（键 auralis.ai.*，对齐 UserDefaults 命名）；
  API Key 存 KeystoreCredentialVault，reference 固定 `ai.provider.api-key`（对齐 credentialID）。
- **会话持久化**：文件 JSON `filesDir/assistant/agent-sessions.json`（同名对齐），非流式消息定稿落盘。
- **工具子集（name 与 Swift canonical 一致；参数形状一致）**：
  - ReadOnly：capabilities_get / tool_search / searchTracks / searchAlbums / searchArtists /
    getTrack / getAlbum / getArtist / listPlaylists / getPlaylist / getFavorites / getCurrentTrack /
    getCurrentQueue / server_list / server_search / lyrics_get / library_get_summary
  - Write(rev 可撤销)：playTrack / playAlbum / playPlaylist / addToQueue / playNext / pause / resume /
    seek / next / previous / likeTrack / unlikeTrack / favoriteAlbum / unfavoriteAlbum /
    setRating / clearRating / createPlaylist / renamePlaylist / addTracksToPlaylist /
    removeTracksFromPlaylist / queue_remove / queue_save_as_playlist
  - Destructive（逐次确认）：deletePlaylist（其余 Swift destructive 工具如 server remove /
    清队列 / 记忆清理等在 Android 无对应能力或超出子集，**不注册即不可调用** = fail-closed 的另一种形态）。
- **授权模型（Android 与 Swift 的一处有意分歧，文档化）**：Swift 用 AgentIntentParser 从原始请求做
  lineage 解析（授权 canonical 集合）；Android 无 NLU 解析器 → 授权 = 用户 consent 门后的全部
  Write 工具（consentGiven 或逐次"允许一次"），Destructive 仍逐次弹窗且确认绑定 runID。
  效果：读操作模型可自由调用；写操作以用户明确同意为边界；删除类操作每次批准。比 Swift 更粗、
  但同样 fail-closed（未同意时写操作抛 ToolExecutionDenied 并如实回灌）。
- **回灌过滤**：历史上下文只取 text（用户/助手）与结构化卡片摘要；reasoning/toolProgress/error/confirmation
  一律不进上下文。
- **运行指示**：运行中 phase 文本（连接/思考/执行工具/回复）+ 停止按钮；reasoning 只做瞬态展示。
- **发送门槛**：isLive=false（未开 or 配置不完整）→ 发送禁用，UI 明示原因并提供配置入口，不伪装。

## 4. 交付范围（S8b/S8c）

- feature:assistant：会话/消息模型（json 持久化）、AssistantCoordinator（send/stop/runID 丢弃/consent/
  confirm/actionLog/回灌过滤）、工具注册表实例化（真实 executor 直连 graph/controller）、
  对话 UI（header/气泡/工具行/流式/会话列表/外发确认/副作用确认/操作日志）、搜索入口保留。
- feature:settings：AI 行启用 → AIProviderSettingsPage（baseURL/apiPath/model/Key/上下文窗口/输出上限/
  原生工具开关/测试连接，全部真实读写与真机探测）。
- app-mobile：AppRoot 持有 Coordinator（跨路由不中断运行）；Assistant 分区替换占位页。
- 原则：AI 不可用/失败如实呈现；不创建 Fake 正式数据；每个按钮真实 action。
