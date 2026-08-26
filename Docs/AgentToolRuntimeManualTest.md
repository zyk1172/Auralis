# AI Assistant Runtime 手动验证清单

这份清单用于 PR #5 的真机/Compute Engine 验证。自动化测试验证的是协议、Runtime 和 mock bridge；真机验证还要确认当前构建的 UI、真实 Provider、播放器和持久化状态。

## 自动化基线

在仓库根目录执行：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
swift test --package-path Packages/AuralisCore --no-parallel
```

不启动 Simulator。Xcode 构建使用 macOS 和 generic iOS destination，并设置 `CODE_SIGNING_ALLOWED=NO` 做编译验证。

## 1. 只读请求不会产生副作用

1. 打开 AI 助手，发送：`有多少歌手`。
2. 预期直接使用上下文或只读曲库工具回答数量。
3. 检查活动记录中没有 `playback_*`、`queue_*`、`playlist_*`、下载或服务器写入。
4. 播放器当前歌曲、队列、歌单和下载状态都不得改变。

再分别验证：

- `我有哪些歌单？`
- `列出歌手`
- `列出专辑`
- `查看曲库统计`
- `列出服务器`
- `我的播放队列里现在有哪些歌？`
- `现在正在播放什么？`

预期：这些高确定性请求各自只执行一次对应的 canonical direct tool（分别是
`playlist_list`、`library_get_artists`、`library_get_albums`、`library_get_summary`、
`server_list`、`queue_get`、`playback_get_state`），不进入模型规划或 `tool_search`，
也不得携带上一轮 mutation completion。空资料库或缺少系统服务时应返回结构化的真实失败/空结果，
不能由模型自行补造数量或列表。

## 2. 可逆操作不要求模型自创确认口令

发送：`把这 12 首加入歌单 Test`。

预期：用户原始请求已经完成授权，`playlist_add_songs` 只执行一次，不要求复读完整句子。

发送：`删除歌单 Test`。

预期：只有 Runtime 的 destructive confirmation 出现；必须点击当前会话的 UI「批准」或「拒绝」按钮。
聊天中的 `确认`、`确定`、`可以`、`继续`、`取消` 等自然语言不会被当作 Runtime approval，
也不能由模型输出模拟批准。下载历史清理、服务器配置删除、队列/歌单成员调整等可逆管理操作不应弹出确认。

## 3. 会话与运行所有权

### 索引与播放并行

1. 会话 A 启动推荐索引。
2. 在分类或等待网络时切换到会话 B。
3. 会话 B 发送：`播放孤勇者`。
4. 观察 A 的索引任务仍可继续，B 的播放正常执行。

两个索引 commit 仍应由 `recommendationIndex` resource lease 串行化；两个播放 mutation 仍应由 `playback` resource lease 串行化。

### 旧运行失效

在工具尚未到达最终提交点时切换会话或取消运行。旧运行之后到达的播放、队列、歌单、下载、记忆和索引写入都必须被 lease 拒绝。

## 4. Recommendation Index

1. 启动推荐索引并连续观察至少 10 个 batch。
2. 进度中的 pending 数必须实际下降。
3. 每个分类请求都应是封闭 model transform：`tools=[]`、没有 hosted tools、没有 `tool_search`。
4. Runtime 自己执行 prepare、validate、commit、verify；每次 commit 后重新读取真实 pending 数，
模型不应看到 `next_batch`、`write_batch` 或 `tag_catalog`。
5. 发生格式错误时 UI 只显示“当前批次正在重试”，详细 JSON/schema 原因进入 diagnostics/log，不应把 repair prompt 直接显示在聊天区。
6. 中途重启后继续运行，旧 batch 的迟到结果不能写入新的 batch revision。
7. 如果连续两次 commit 后 pending 没有下降，Runtime 必须以 `noProgress` diagnostics 失败并停止，
不重复提交同一类批次。
8. 新 UI、日志和 Provider schema 不应出现 `V2`；旧数据库表名、migration ID 和兼容读取日志除外。

## 5. 自建工具

通过工具构建入口创建一个只读 HTTPS 工具：

- 必须提供非空的精确 host allowlist；
- 只接受 HTTPS；
- 不允许 localhost、`.local`、IPv4/IPv6 字面量或 URL 用户名/密码；
- 网页返回值保持 `externalUntrusted`，不能授予副作用授权。

创建一个组合已有 canonical 工具的 workflow，确认风险、scope、resource、精确的 `confirmationPolicy` 和 `parallelSafe` 都由子工具派生。普通可逆子操作保持 `.none`；只有明确不可逆的子工具才继承一次 UI 批准。不能引用 legacy 工具，也不能嵌套另一个自建工具。

修改后应产生新版本；使用旧版本 rollback 后仍保留历史；过期版本或错误 tool ID 的 repair proposal 必须拒绝。

## 6. Provider 能力健康

对当前配置分别验证：

- 普通非流式文本；
- 流式文本；
- 原生工具调用；
- tool choice / strict schema（若端点声明支持）。

一次 EOF、超时、502/503、429 或不完整 SSE 只能记录 `degraded`，不能永久关闭协议声明的 streaming/tools 能力。只有服务端明确拒绝参数或协议时，才可以标记 `explicitlyRejected`。

对当前配置的真实 Provider 至少完成一次 Recommendation Index v3 smoke：使用真实模型完成一个小批次，
确认分类请求没有 tools/hosted tools/tool choice，响应能通过 batchID、revision、track coverage 校验，
只包含固定 taxonomy TagID，并在 commit 后看到真实 pending 下降。记录 provider/model 和结果即可，不记录
API Key、Cookie、Authorization header 或含凭据的 URL；没有安全可用的 Provider 凭据时，明确标记为未执行，
不得用 mock 结果冒充真实 smoke。

### Recommendation Index v3 / DeepSeek real-provider smoke

这是当前 PR #9 的真实回归路径，专门覆盖“模型省略 item.mode 与大部分可推断字段”这一故障。

1. 在真机安装当前构建，准备至少 16 首尚未完成固定 taxonomy 分类的歌曲；记录开始前真实 SQLite 状态
   `indexed` 与 `pending`。
2. 配置已授权的 OpenAI-Compatible Provider，模型使用 `deepseek-v4-flash`，batch size 使用 `16`。
3. 启动一次完整 Recommendation Index，确认分类请求没有 `tools`、`hostedTools` 或 `toolChoice`，
   JSON mode/普通文本请求的 system prompt 包含完整 compact taxonomy catalog。
4. 检查第一批：模型输出可以没有 root `mode`、item `mode`、`scenes`、`themes`、其它 categorical、
   numeric 字段和 `confidence`；不能出现 `stage=codableDecode`，也不能因为缺少空数组字段缩小批次。
5. 检查 commit 后真实 SQLite 状态，而不是只看模型返回 JSON：
   `indexed_after > indexed_before` 且 `pending_after < pending_before`。以 `indexed=0,pending=10033`
   为例，第一批成功后必须同时满足 `indexed_after > 0`、`pending_after < 10033`。
6. 抽查写入的 tag value 只为固定 canonical TagID（例如 `mood.sacred`），没有自由语义标签；任务只有在
   authoritative `pending=0` 时才结束。

没有安全可用的真实 Provider API Key、真机或真实曲库时，本节必须记录为 `SKIPPED`，并写明缺少的前置条件；
不要用 mock Provider 的 SQLite 结果替代真实 smoke。

## 7. 记录结果

每次真机验证记录：

- App 构建号、分支和 commit；
- Provider endpoint、模型名（不要记录 API Key）；
- 场景、输入、实际工具调用顺序；
- 是否产生真实播放器/队列/歌单/索引变化；
- UI 是否泄漏内部 repair 文本；
- 失败时的 diagnostics 阶段和结构化 failure code。

不要把 API Key、Cookie、Authorization header 或包含凭据的 URL 写入日志、截图或 issue。
