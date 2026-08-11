# Auralis Agent 架构

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
              AgentRuntime (actor)
          policy / state / budget / completion
                       │
                       ▼
          AgentRunner (low-level model loop)
                       │
                       ▼
              AgentToolRegistry
         LocalCatalog / Bridge / SystemService
```

## 任务创建

`AgentTaskPolicyResolver` 在任务边界解析 Intent。明确的 UI 入口应传
`explicitIntent`，避免让模型猜测；自由文本才由保守的规则分类器处理。当前 Intent
覆盖对话、目录搜索、播放、发现、队列、歌单、资料库维护、服务器、诊断、歌曲鉴赏、
下载与记忆。

Intent 产生 `AgentTaskPolicy`。Policy 同时约束：

- 允许的 `ToolGroup`；
- read-only / reversible / destructive 权限；
- 最大风险；
- Granted Scope；
- Completion Predicate；
- wall-clock、模型轮次、输入/输出 token、无进展和重复模式预算。

模型上下文上限统一为 256,000 token，单次输出上限为 16,000 token。输入上限是每次
模型请求的上下文限制（并会预留输出空间），不是整项任务跨多轮累计消耗的终止阈值；
任务累计 token 仅用于进度与用量记录，避免长工具任务被误判为“达到输入 token 预算”。

因此工具在注册表中“存在”不代表本次任务可以调用。Runtime 会再次按当前 Policy
授权；例如歌曲鉴赏不能删除服务器，纯分析不能替换播放队列。

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

`AgentToolRegistry.execute` 是唯一公开执行路径。`AgentToolkit.execute` 与
`executeV2` 只作为源码兼容别名，都会转发到注册表，不构成两套执行系统。

每个 `ToolDescriptor` 自描述：

- 参数与必填性；
- 权限和确认要求；
- 缓存策略；
- 副作用类型；
- Evidence 类型；
- 单工具结果长度上限。

注册表把本地工具交给 `AgentToolkit.executeRegistered`，把设备/系统工具交给
`SystemToolExecutor`。Runner 不再自行维护第二份工具路由。

推荐索引 V2 是普通目录工具服务。它的批次规则属于工具描述与工具结果，Runtime 的
通用模型循环不解析索引摘要、不采用索引专属超时，也不维护索引专属轮次状态。
原生工具调用直接把分类批次作为结构化 `items` 数组写回；旧版 `itemsJSON` 仍可读取。
V2 是结构化音乐分析索引，只保留固定维度：情绪、场景、人声、质感、风格与
energy/tempo/acousticness/danceability 数值；不再提供 customTags 动态标签能力，
历史遗留的非固定维度标签在打开数据库时清理。

## 持久化、取消与重启

`AgentCoordinator` 只把 Runtime event 映射为 UI。`AgentTaskStore` 持久化 Intent、Goal、
预算、状态、token、工具步数、已完成动作和无进展计数。App 重启时仍在运行的任务标记
为 interrupted；已完成副作用不会被自动重放。

取消从 Coordinator 传入结构化 Task，模型请求和工具执行遵循 Swift Task cancellation。
任务失败按超时、认证、限流、瞬时网络、服务不可用、配置、响应兼容与永久错误分类，
只对真正瞬时错误重试。

## 隐私边界

上下文通过 `AgentContextBuilder` 建立。凭据永不进入 prompt、任务状态或诊断；地址、
token、cookie 和 authorization 参数在日志边界统一脱敏。歌词和播放历史受各自隐私
开关约束。上下文只包含任务需要的目录切片，禁止整库、海报、流地址和文件路径外发。

## 自动验证

`AgentRuntimeArchitectureTests` 覆盖 Intent、Policy/Scope、越权拒绝、预算、Evidence、
上下文合法 tool-call 配对、失败分类、结构化 reducer、完成条件、显式 UI Intent、索引
完成事实以及非固定数量队列工作集。该套件当前包含 42 个测试用例（参数化用例展开后）。

MANUAL-VERIFY: 使用真实 OpenAI 原生接口分别执行播放、歌曲鉴赏、完整索引和取消任务，
确认 UI 事件映射、原生 tool_call_id 和首次隐私授权与自动测试一致。
