# Auralis AI Assistant V2 实施说明

## 设计目标

助手首先是通用对话系统，同时可以按需调用 Auralis 的音乐、播放器、服务器、记忆和联网
能力。Intent 只是提示，不是 capability boundary；工具执行的事实和副作用由 Swift 运行时
确认，模型不能用自然语言伪造成功。

## 协议层

`AITranscript` 统一保存 system、user、assistant text、assistant tool calls、tool result
和内部 reasoning。`AICompletionRequest` 保存 transcript，并保留 `messages` 兼容投影。

- OpenAI Chat：使用 `messages` 角色协议。
- OpenAI Responses：使用顶层 `function_call` / `function_call_output` item。
- Anthropic Messages：把 assistant `tool_use` 和同一轮多个 `tool_result` 编码为合法
  content blocks；并行结果只产生一个 user message。
- `ModelCapabilities` 明确 tool mode、并行工具、tool choice、strict schema、reasoning
  metadata 和 hosted web 能力，Runner 不再只看一个 `supportsToolCalling` 布尔值。

## 工具发现与执行

`AgentToolRegistry.all` 是描述和执行的单一来源。`ToolCatalog` 对其按名称、命名空间、摘要
和 tags 搜索，`tool_search` 返回轻量摘要；Runner 将发现到的 descriptor 加入下一轮 schema。
完整工具定义不会永久常驻每轮请求。普通聊天默认进入 generic loop；只有明确的
Auralis/音乐操作或确定性 workflow 才进入任务状态路径。

模型调用进入 `ToolRuntime` 后依次经过：必填/未知参数校验 → JSON Schema 基本形状校验 →
注册表分流 → 真实 `AgentBridge`、`LocalCatalogStore`、系统服务或 `AgentWebService`。
副作用工具的成功、失败和 indeterminate 都从真实调用结果产生，超时/取消不会被当成成功。

已拆分的高频入口包括：

- `library_resolve_entity`、`library_get_songs_batch`；
- `queue_append_many`、`queue_play_next_many`；
- `music_download_search`、`music_download_submit`、`music_download_status`、
  `music_download_tasks`、`music_download_history`、`music_download_history_remove`、
  `music_download_history_clean`。旧 `music_download(action: ...)` 仅作为兼容执行入口。

## 对话、联网与记忆

普通聊天的生产链路是 `AgentCoordinator → ConversationEngine → ToolLoop → Provider / ToolRuntime`，
不创建 `AgentTaskState`，也不经过 `CompletionEvaluator`。确定性任务才由
`AgentCoordinator → AgentRuntime → ConversationEngine → ToolLoop → trusted Stateful Skill`
编排；Recommendation Index V2 的 `RecommendationIndexV2SkillRuntime` 内部再驱动
`RecommendationIndexWorkflow`。`AgentRunner` 只保留弃用的 source-compatibility forwarding。入口默认是 generic conversation；
“推荐 / 下载 / 为什么 / 搜索”等通用词只有和明确音乐/Auralis 上下文组合后才会进入 deterministic
intent，避免把“推荐几本书”或“怎么下载 Python”改写成音乐任务。没有明确音乐命令时，Provider
不可用不会触发本地音乐搜索。

联网通过可替换的 `AgentWebService` 注入。默认 App 实现是受 HTTPS/私有地址/响应大小约束
的 DuckDuckGo Instant Answer capability；默认 `web_fetch` 只接受当前 run 的 source registry
已登记的 URL。登记来源包括本地 `web_search`、配置的 search backend 和 Provider hosted
citations，以降低 URLSession 二次解析造成的 DNS rebinding 风险；旧 run 的迟到写入会被拒绝。
生产环境可替换为受控自有后端或 Provider hosted tool；如需允许任意用户 URL，应由后端负责
IP pinning/proxy，而不能只依赖一次 `getaddrinfo` 检查。
`web_search` 结果为 `WebSource`，会进入 `AgentMessage.webSources`，UI 展示标题、域名、
摘要与可点击 URL；`web_fetch` 返回带来源 URL 的受限正文。

长期记忆仍由 `AgentMemoryStore` 持有；system prompt 每轮只注入有限的核心、相关和最近记忆，
以及有限的 skill 摘要，剩余内容通过 `memory_search`、`skill_list` / `skill_read` 按需获取。
外部网页结果带有 `externalUntrusted` trust level，且副作用 Runtime 只接受由原始用户请求
推导出的 `SideEffectAuthorizationContext`，网页内容不能成为用户授权。

## 验证边界

当前验证使用 Xcode Beta host/macOS package target：

```text
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path Packages/AuralisCore
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Auralis.xcodeproj -scheme AuralisMac \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Auralis.xcodeproj -scheme Auralis \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

测试覆盖 transcript round-trip、Anthropic 并行结果聚合、Responses/Chat wire shape、工具
发现、严格参数形状、普通聊天路由/降级边界、外部数据副作用隔离、Web SSRF 与已有播放器/
推荐索引回归、Stateful Skill checkpoint 和 run-scoped WebSource。本地验证未启动或运行 Simulator；GitHub CI 另有 iOS Simulator SDK 编译 job，
但不 boot Simulator 或运行 Simulator 测试。真实 Provider、真实联网搜索和真实端到端 UI 仍需
按环境做手工 smoke test。
