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
完整工具定义不会永久常驻每轮请求。

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

`ConversationEngine` 位于 `AgentRuntime` 和低层 `AgentRunner` 之间，统一维护 chat-first
入口与离线降级规则：没有明确音乐命令时，Provider 不可用不会触发本地音乐搜索。

联网通过可替换的 `AgentWebService` 注入。默认 App 实现是受 HTTPS/私有地址/响应大小约束
的 DuckDuckGo Instant Answer capability；生产环境可替换为自有后端或 Provider hosted tool。
`web_search` 结果为 `WebSource`，会进入 `AgentMessage.webSources`，UI 展示标题、域名、
摘要与可点击 URL；`web_fetch` 返回带来源 URL 的受限正文。

长期记忆仍由 `AgentMemoryService` 持有；`memory_search` 只回传与 query 匹配的条目，避免
每轮把完整记忆库放进上下文。Skill 与 Memory 保持不同语义和不同工具集合。

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
发现、严格参数形状、普通聊天降级边界和已有播放器/推荐索引回归。未使用 Simulator；真实
Provider、真实联网搜索和真实端到端 UI 仍需按环境做手工 smoke test。
