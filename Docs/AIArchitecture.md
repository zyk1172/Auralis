# AI Architecture

## 原则

AI 不在播放可靠性关键路径内，不直接访问数据库，不写音频文件，不生成不存在的 Track ID，
也不能发明 MusicBrainz ID、发行日期或参与人员。

AI Assistant 是建立在播放器之上的智能层，不是播放器 UI 的自然语言备用入口。AI Provider
不可用时 **不降级为关键词规则伪 Agent**（本地规则 fallback 已删除）：复杂推荐、鉴赏、
分类、歌单构建、音乐库整理一律明确返回“AI 服务不可用”；只有高置信度只读的 Direct Read
Fast Path 在 Provider 缺失时仍直接执行一次 canonical read 返回真实数据（性能优化，不是
离线降级）。普通播放器 UI / 搜索 / 歌单 / 队列等系统命令入口完全独立于 AI 层。

```text
User intent
  → privacy gate and request preview
  → local MusicAssistantTool execution
  → real Track candidates
  → deterministic filter/ranking/diversity
  → optional LLM ordering and explanation
  → Track ID validation
  → confirmation only for irreversible deletion
  → queue or playlist use case
```

## Provider

`AIProvider` 提供连接测试、非流式完成和 `AsyncThrowingStream`。配置包含 Base URL、API
路径、模型、Header、温度、Token、超时与能力声明。密钥只使用 `CredentialID` 间接引用；
Provider 请求层从 Keychain 读取后直接构造请求，不向日志或 UI 回传明文。

用户的思考设置使用 Provider-neutral 的 `AIReasoningConfiguration`（默认开启、中等强度），
由 `AICompletionRequest` 随单次请求传递。Responses 使用 `reasoning.effort`，支持的 Chat
兼容端点才使用 `reasoning_effort`，Anthropic 使用自己的 `thinking` 映射；未知或不支持的
协议不发送未知字段。一次没有返回 reasoning metadata 只代表未观察到，不会被缓存为永久不支持。

当前实现包含三类线上 adapter：`/v1/chat/completions`、`/v1/responses` 与 Anthropic
Messages，流式与非流式均已接入。SSE parser 支持分块和多行 data；网络层已实现 Task
cancellation（`onTermination` 取消底层请求）与参数回落重试。HTTPS 使用系统信任链校验证书；显式配置的 HTTP 端点继续支持本地服务。
未增加自定义证书信任、证书绑定或独立代理设置。

流结束与任务完成分别建模：连接自然 EOF、供应商显式停止原因（stop / tool_calls /
length / stop_reason / response.incomplete）映射到统一的终止语义，截断与传输中断不再
被当作正常完成。对确实以 EOF 为结束信号的兼容网关，可在两端设置中显式启用兼容开关；
该开关绑定当前端点、API 路径与模型，修改连接配置后失效。

工具续接保留供应商原生推理状态：DeepSeek 的 `reasoning_content`、Claude 的
`thinking`/`signature`（含 `redacted_thinking`）、Responses 的推理条目在中立 transcript
中以 opaque continuation 形式按原始顺序保存，续接请求按端点匹配回放；切换模型或端点
后旧状态不混入。UI 的思考展示与协议续接状态分别建模。

助手正文按运行期披露标记（`AgentChatMessage.disclosureCategories`）进入历史投影：
运行实际接触过的元数据 / 歌词 / 播放历史 / 收藏评分 / 外部检索类别会被记录，
并继承已投影的历史来源；撤销对应类别后过滤相关正文，无标记的旧数据只在全部类别
允许时重放。Apple 还保守记录系统提示中的曲库事实与召回来源，避免未调用工具时漏标。
Apple 跨会话记忆保留来源（userAsserted / derivedFromTools / external）、多个披露类别、
创建时间及可选有效期；`memory_save` 可接受用户要求的 RFC3339 有效期，来源由运行时
登记而非模型声明。技能使用原子 JSON 文件保存正文和来源，兼容读取旧 Markdown 文件，
同名 JSON 损坏时不回落旧的无标记内容。召回按权限过滤，外部内容保留不可信边界。
Android 当前提供聊天历史来源过滤，不包含 Apple 的跨会话记忆与技能存储功能。

## 工具边界

工具集合由 `MusicAssistantTool` 建模。读操作返回最小字段；普通播放、队列、下载、服务器
和标注写操作保持直接执行，只有删除歌单、删除/清空记忆、删除技能文件等不可逆操作生成待
确认 Action Plan。每次输出在展示和执行前分别校验 Track ID。

## Token 和上下文

会话保存结构化条件而不是无限追加完整聊天。每轮保留当前约束、最近决定和候选摘要；超出
Provider 声明的上下文窗口后生成本地摘要。AI 层不再设置固定 256K/16K 上限；默认不含
完整歌词、路径、NAS 地址、令牌或设备标识，隐私数据仍受各自开关约束。
