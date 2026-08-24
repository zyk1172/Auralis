# Auralis Agent 架构

## AI Assistant 当前实现

当前实现的入口是聊天，而不是一个先把用户请求硬分进音乐意图的路由器。`AgentIntentClassifier`
只产出排序、完成条件和诊断提示；真正的能力来自注册表与运行时。普通知识聊天在 Provider
缺失或失败时不会被改写为本地音乐搜索，只有明确的音乐操作/查询才允许使用离线音乐能力。

```text
AssistantView / Siri / App Intent
              │
              ▼
AgentCoordinator (@MainActor)
              │  session / consent / UI citations
              ▼
      ┌───────┴────────┐
      ▼                ▼
      ConversationEngine   AgentRuntime (deterministic state)
      │                │
      └───────┬────────┘
              ▼
          ToolLoop
              │
       Trusted Stateful Skill
              │
      Provider / ToolRuntime
              │
AgentToolRegistry → AgentToolkit / SystemToolExecutor / AgentWebService
```

普通聊天直接进入 `ConversationEngine → ToolLoop`；只有需要持久化状态、工作流或确定性
完成条件的任务才经过 `AgentRuntime → ConversationEngine`。`AgentRunner` 已不再是生产
循环，只保留 deprecated 的 source-compatible forwarding façade。

关键架构边界：

- `AITranscript` 是 Provider-neutral 的 tool conversation；Chat、Responses 和 Anthropic
  codec 从 transcript 投影到各自 wire format。Anthropic 的同一轮并行结果会聚合成一个
  `user` content block，保留每个 `tool_use_id`。
- Provider 设置中的协议类型只决定 wire format，不证明模型可用或支持工具。设置页的能力
  诊断分别验证模型目录、基础文本、流式、原生工具与 `tool_choice`，并以 Base URL/path/model
  指纹缓存结果；未验证或失败的 OpenAI-compatible endpoint 只做普通文本聊天，不会隐式改写为
  ACTION 工具协议。流式失败但文本成功时，同一协议的非流式补全会投影为事件流。
- `ToolCatalog` 从 `AgentToolRegistry.all` 搜索能力。`tool_search` 只返回轻量摘要；
  发现后的工具会加入下一轮 schema，避免把 100+ 个完整定义永久塞进每一轮上下文。
- `ToolRuntime` 在副作用前校验必填参数、未知参数和递归 JSON Schema，并执行
  `SideEffectAuthorizationContext` 的逐个 canonical operation 授权；注册表仍是
  工具描述、别名、权限、副作用、Evidence、联网和并行安全属性的单一来源。
- Web 能力通过 `AgentWebService` 注入，`web_search` 返回 `WebSource`，UI 用可点击来源卡片
  展示；`web_fetch` 只返回脱敏正文和 URL。Provider 托管搜索能力与 App WebCapability
  是两条可替换路径。
- `music_download` 保留为兼容入口，但模型 schema 暴露为 search/submit/status/tasks/
  history/history_remove/history_clean 七个小工具；`library_resolve_entity`、
  `library_get_songs_batch`、`queue_append_many` 与 `queue_play_next_many` 用于减少逐项往返。

这部分是当前代码已经落地的架构，不把尚未完成的 Provider hosted web adapter 或真实端到端
联网 smoke test 写成已验证事实。

# Execution Philosophy

Auralis uses a provider-first conversation loop and a permissive registered-tool
runtime. `ToolRuntime` remains the only side-effect boundary: it validates the
call and checks a least-privilege `SideEffectAuthorizationContext` derived from
the user's original task. Irreversible deletion still has its separate UI
confirmation gate.

A user's explicit natural-language request authorizes only the requested canonical operation(s).

Intent is a routing hint, not a capability boundary.

Model-visible tools are discoverable from the canonical registry. Legacy aliases and
skill-private transition tools are executable only through their compatibility or trusted
stateful-skill paths; they are not ordinary model capabilities.

The runtime does not impose cumulative tool-call limits on normal tasks.

No-progress counters and repeated-tool counters do not terminate normal tasks.

Ambiguous targets require entity disambiguation, not risk confirmation.

Privacy preferences and credential isolation remain technical data-flow boundaries.

User cancellation and per-request timeouts remain supported.

## 实现对照

- `AgentTaskPolicy.authorizes(_:)` 恒返回 `true`（deprecated / diagnostics-only）：Intent 不再
  作为工具能力门禁。真正的副作用门禁在 `ToolRuntime`，按 `ToolDescriptor` 声明的
  `ToolAuthorizationOperation` 与原始用户请求逐操作匹配；没有精确授权的写操作 fail closed。
- `AgentTaskBudget` 只剩极端看门狗：`wallClockSeconds`（默认 60 分钟）与
  `maxModelRounds`（默认 1000，紧急防失控）。`maxNoProgressRounds` /
  `maxRepeatedToolPattern` 保留为诊断统计，不作为终止条件。
- `ToolLoop` 不按 Intent 拦截普通模型工具，也不因 `stopSearching` / 连续无新结果 /
  重复工具模式终止任务；仅在注册表明确标记的不可逆删除工具前等待 UI 批准。只有已
  激活的可信 Stateful Skill 可以获得其私有状态转移工具。
- `AgentRunner` 仅为旧调用方转发到 `ConversationEngine`，生产调用链不再经过它。
- 单工具超时/异常回灌结构化失败结果，模型可换工具、换参数、换策略继续。
- `queue_replace` 可用不同参数多次调用；相同工具 + 相同参数幂等复用。
- 对象歧义（多个同名歌单/曲目）通过实体解析与消歧处理，而不是风险确认；风险确认
  只表示不可逆删除，不替代实体消歧。
- `ToolSelector` 是纯 Schema 优化器：只有 `tool_search`、能力摘要和与请求语义相关的
  `.model` 工具常驻；泛化的“推荐/下载/搜索/为什么”不会单独注入音乐工具。已激活的
  Stateful Skill 另外追加它拥有的工具。旧式驼峰别名统一映射回 canonical 名称，不再
  重复暴露，执行兼容由注册表保留；模型需要新能力时可先调用 `tool_search`。

## 目标

Auralis 使用单 Agent 体系：一个模型、一个 `AgentRuntime` actor、一份结构化
`AgentTaskState`，以及注册表驱动的受控工具。它不是多 Agent 编排器；播放、目录、
服务器和持久化事实仍由现有 `AgentBridge`、`LocalCatalogStore` 与系统服务提供。

```text
AssistantView / Siri / App Intent / 歌曲鉴赏入口
                       │
                       ▼
        AgentCoordinator (@MainActor UI adapter)
                       │
                       ▼
              ConversationEngine
                       │
                    ToolLoop
                       │
              AgentToolRegistry
         LocalCatalog / Bridge / SystemService
```

确定性任务的附加链路是 `AgentCoordinator → AgentRuntime → ConversationEngine → ToolLoop`；
`AgentRuntime` 只拥有任务状态、Workflow route 与完成判定，不拥有 Provider/tool-call 循环。

## 任务创建

`AgentTaskPolicyResolver` 在任务边界解析 Intent。明确的 UI 入口应传
`explicitIntent`，避免让模型猜测；自由文本才由保守的规则分类器处理。当前 Intent
覆盖对话、目录搜索、播放/播放状态查询、发现、队列/队列查询、歌单/歌单查询、资料库维护、
服务器、诊断、歌曲鉴赏、下载与记忆。查询意图使用普通 `.modelAnswer` completion，不会
因为只读工具没有 mutation 而继续任务。

Intent 产生 `AgentTaskPolicy`。Policy 只承担路由/诊断职责，不再约束执行能力：

- Completion Predicate（完成判定）；
- Budget（仅极端看门狗）；
- 推荐的 Tool Group / 意图建议工具（ToolSelector 用，纯加法）；
- 日志与 UI 状态。

`ToolGroup` / `ToolPermission` / `AgentRisk` / `GrantedScope` 保留为兼容与诊断元数据，
Runtime 正常执行路径不再依赖它们做门禁；唯一例外是 `ToolDescriptor.requiresConfirmation`
对不可逆删除工具的精确声明。
- wall-clock 与模型轮次只作极端看门狗；输入/输出 token 跟随 Provider / ModelCapabilities，
  不在 Agent 层再加固定上限；无进展和重复模式只记录诊断。

模型上下文与单次输出均由设置中的模型能力声明决定（支持 1M 上下文和 128K 输出等档位），
请求前只按 Provider 能力为输出、工具 Schema 与协议字段预留空间。它们不是整项任务跨多轮
累计消耗的终止阈值；任务累计 token 仅用于进度与用量记录。

因此工具在注册表中“存在”即表示普通运行时可用；Runtime 不按意图缩减工具能力。
但 Provider 必须先通过本机能力诊断：`/v1/models` 目录（若 endpoint 支持）用于区分模型 ID
问题与鉴权，文本/流式/原生工具是独立探测项。`401 + ModelError` 会被报告为模型/上游路由
问题而不是 API Key 错；仅在目录确认仍含当前模型时才有限重试两次。
`ExecutionLineage` 与 conversation history 分离：完整新请求一律新建 lineage、completion、
authorization 和 mutation lease；只有“继续”“第一个”等严格短后续可安全继承上一 lineage。
`SideEffectAuthorizationContext` 的来源只能是 lineage 的原始用户请求或恢复记录中的 `goal`；
网页/搜索/模型文本永远不能产生授权。只有 playlist_delete、memory_delete、memory_clear、skill_delete
会在副作用执行前等待用户批准，拒绝会跳过桥接层并把结构化失败回灌给模型。

## 任务状态与 Evidence

`AgentTaskState` 是 Runtime 的权威状态，包含 goal、状态、事实、Evidence、候选与已选
实体、已完成/待完成动作、预算进度、无进展状态、错误与完成状态。音乐候选缓存使用
`AgentTaskWorkingSet` 这一领域辅助类型，但它不再承担通用 Runtime 状态，也不再假设
固定 20 首。只有用户明确写出数量时才建立队列数量目标。

工具使用 `ToolResult.facts` 返回结构化事实，使用 `ToolResult.evidence` 返回来源明确的
Evidence。`AgentTaskReducer` 将它们归并到 TaskState。Runtime 不从中文摘要中解析数字，
也不把模型推断伪装成本地或服务器事实。

Evidence 来源包括本地目录、播放状态、服务器、外部 API、用户陈述与模型推断。
只有非 model-inference Evidence 才能满足需要真实工具结果的完成条件。

## 完成条件

`AgentCompletionEvaluator` 独立于模型文本判定任务是否完成。示例：

- 队列/歌单/播放任务：对应工具副作用事实必须为 success；
- 搜索/诊断：至少存在真实工具 Evidence；
- 歌曲鉴赏：元数据已获得，歌词与大众评价均明确为 available 或 unavailable；
- 完整推荐索引任务：结构化事实 `recommendation.index.pending == 0`。

模型提前给出自然语言结论时，Runtime 最多要求一次修复；仍不满足则以证据不足失败，
不会谎报成功。

## 工具系统

`ToolRuntime.execute` 是 Runner 的唯一执行前入口：先按 `ToolDescriptor` 校验参数，再调用
`AgentToolRegistry.execute`。`AgentToolkit.execute` 与 `executeV2` 只作为源码兼容别名，都会
转发到注册表，不构成两套执行系统。

每个 `ToolDescriptor` 自描述：

- 参数与必填性；
- 权限和确认要求；
- 缓存策略；
- 副作用类型；
- Evidence 类型；
- 单工具结果长度上限。

注册表把本地工具交给 `AgentToolkit.executeRegistered`，把设备/系统工具交给
`SystemToolExecutor`。Runner 不再自行维护第二份工具路由。

当前注册表覆盖搜索、目录索引、播放/队列、歌单、服务器、下载、设备网络/音频/存储、
诊断、公开音乐证据、推荐与记忆/技能 CRUD 等 100+ 工具。技能使用 `skill_create` /
`skill_list` / `skill_read` / `skill_delete` 管理本地可复用指令；`memory_search` 只查询
相关长期记忆。模型的工具选择范围由 discovery 动态扩展，不是由 Intent 永久裁剪。

推荐索引是可信 Stateful Skill，而不是一组可以被通用模型任意编排的目录写工具。
`RecommendationIndexSkillRuntime` 自己持有批次 identity/revision、状态、重试收缩、完成判定和
checkpoint generation；固定链路是 `status → prepareBatch → model classification → validate →
commit → verify`。模型仅可调用 `library_index_status`、`library_index_read`；分类请求没有
tools/hosted tools，内部 prepare/commit primitive 不会被 `ToolCatalog.search`、`tool_search` 或
generic provider schema 发现。Runtime 在 exact IDs、batchID、revision、mode 都匹配后才写入。
这是结构化音乐分析索引：固定维度（情绪、场景、人声、质感、风格与
energy/tempo/acousticness/danceability 数值）保持规范；此外开放语义标签
（dimension="tag"）由 Agent 自主创建，不设数量上限，质量通过规范化、复用 canonical
与语义规则控制。详见 `Docs/RecommendationIndex.md`。

## 持久化、取消与重启

`AgentCoordinator` 只把 Runtime event 映射为 UI。`AgentTaskStore` 持久化 Intent、Goal、
预算、状态、token、工具步数、已完成动作、无进展计数和可信 Stateful Skill 的 compact
checkpoint。App 重启时仍在运行的任务标记为 interrupted；已完成副作用不会被自动重放，
恢复时以真实 catalog status 为权威，并从 checkpoint 恢复批次/UI 上下文。

取消从 Coordinator 传入结构化 Task，模型请求和工具执行遵循 Swift Task cancellation。
任务失败按超时、认证、限流、瞬时网络、服务不可用、配置、响应兼容与永久错误分类，
只对真正瞬时错误重试。

## 隐私边界

上下文通过 `AgentContextBuilder` 建立。凭据永不进入 prompt、任务状态或诊断；地址、
token、cookie 和 authorization 参数在日志边界统一脱敏。歌词和播放历史受各自隐私
开关约束。上下文只包含任务需要的目录切片，禁止整库、海报、流地址和文件路径外发。

## 自动验证

`AgentRuntimeArchitectureTests` 覆盖 Intent、Policy/Scope、逐操作越权拒绝、预算、Evidence、
上下文合法 tool-call 配对、失败分类、结构化 reducer、完成条件、显式 UI Intent、索引
完成事实以及非固定数量队列工作集；`AgentAssistantV2Tests` 还覆盖私有索引工具的
skill-only 可见性、索引查询不启动构建和 Stateful Skill checkpoint 恢复。

MANUAL-VERIFY: 使用真实 OpenAI 原生接口分别执行播放、歌曲鉴赏、完整索引和取消任务，
确认 UI 事件映射、原生 tool_call_id 和首次隐私授权与自动测试一致。


## Session Isolation

消息状态以 Session 为唯一归属，运行以 `runID` 为唯一身份：

- `AgentCoordinator.receive(message, sessionID, runID)` 永远先写入目标 Session 的
  SessionStore；只有 `activeSessionID == sessionID` 才更新当前屏幕 `messages`。
- 流式状态按 `runID` 隔离（`streamingStates[runID]`），Session A 的流式气泡不可能
  出现在 Session B。
- 迟到 callback（旧 runID）一律丢弃，不污染新运行 / 新会话。
- 任务历史从 SessionStore 读取，不依赖全局 `messages`；`trimHistoryIfNeeded` 只更新
  被裁剪会话自己的 UI 投影；任务进度（activeTask）只对活动会话更新。
- 唯一允许跨会话的是 `AgentMemoryStore` 中用户明确保存的长期 Memory（显式跨会话通道）。

## Memory vs Session History

- Session History：局部，不跨会话。
- 长期 Memory：显式跨会话，由 `memory_save` 写入、`memory_list` 读取，跨会话注入。
- Memory 存储不设普通数量硬上限（不再 200 条静默淘汰旧记忆）；Context 注入按 token
  budget 裁剪（每轮只注入最近更新的核心记忆，其余用 `memory_list` 精确查询）。
- Memory（主人长期信息）与 Skill（可复用工作指令）是两个概念，`memory_list` 与
  `skill_list` 不得互相替代。

## Tool Success vs Evidence

- `AgentTaskState.successfulToolCount` / `successfulToolNames`：真实成功执行过的工具
  结果（Tool Success）。
- `AgentEvidence`：事实来源 provenance（外部音乐数据、大众评价、诊断等）。
- 完成条件 `successfulToolResult`：至少一次真实成功 ToolResult（`successfulToolCount > 0`），
  不再要求“必须有 AgentEvidence”——`memory_list` 等查询成功即可通过，不再误报
  “没有真实工具证据”。

## Result Presentation

- `AgentPresentationState` 把内部候选池与最终展示彻底分离：
  - candidate：中间候选，只回灌模型，绝不上屏；
  - final：`result_present_tracks` / 真实副作用（queue_replace、playlist_add_songs）
    / 查看类任务收尾合并；
  - disambiguation：多个匹配供用户选择；
- 一个任务最终最多一组 TrackCards（`finalMessage()` 只返回一个消息）。
- Cancel / Fail 不倾倒候选池；Session History 只保存最终可见结果。
- UI：<=5 全部显示；>5 默认 5 首 + “展开其余 N 首”/“收起”。
