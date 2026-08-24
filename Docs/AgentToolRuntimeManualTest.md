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
- `我的播放队列里现在有哪些歌？`
- `现在正在播放什么？`

这些请求只允许建立 read lineage，不得携带上一轮 mutation completion。

## 2. 可逆操作不要求模型自创确认口令

发送：`把这 12 首加入歌单 Test`。

预期：用户原始请求已经完成授权，`playlist_add_songs` 只执行一次，不要求复读完整句子。

发送：`删除歌单 Test`。

预期：只有 Runtime 的 destructive confirmation 出现；在 UI 中回复 `确认`、`确定` 或 `可以` 应归一成批准，回复 `取消`、`不要` 或 `不` 应归一成拒绝。不要要求用户输入精确确认句。

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
4. Runtime 自己执行 prepare、validate、commit、verify；模型不应看到 `next_batch`、`write_batch` 或 `tag_catalog`。
5. 发生格式错误时 UI 只显示“当前批次正在重试”，详细 JSON/schema 原因进入 diagnostics/log，不应把 repair prompt 直接显示在聊天区。
6. 中途重启后继续运行，旧 batch 的迟到结果不能写入新的 batch revision。
7. 新 UI、日志和 Provider schema 不应出现 `V2`；旧数据库表名、migration ID 和兼容读取日志除外。

## 5. 自建工具

通过工具构建入口创建一个只读 HTTPS 工具：

- 必须提供非空的精确 host allowlist；
- 只接受 HTTPS；
- 不允许 localhost、`.local`、IPv4/IPv6 字面量或 URL 用户名/密码；
- 网页返回值保持 `externalUntrusted`，不能授予副作用授权。

创建一个组合已有 canonical 工具的 workflow，确认风险、scope、resource、`requiresConfirmation` 和 `parallelSafe` 都由子工具派生。不能引用 legacy 工具，也不能嵌套另一个自建工具。

修改后应产生新版本；使用旧版本 rollback 后仍保留历史；过期版本或错误 tool ID 的 repair proposal 必须拒绝。

## 6. Provider 能力健康

对当前配置分别验证：

- 普通非流式文本；
- 流式文本；
- 原生工具调用；
- tool choice / strict schema（若端点声明支持）。

一次 EOF、超时、502/503、429 或不完整 SSE 只能记录 `degraded`，不能永久关闭协议声明的 streaming/tools 能力。只有服务端明确拒绝参数或协议时，才可以标记 `explicitlyRejected`。

## 7. 记录结果

每次真机验证记录：

- App 构建号、分支和 commit；
- Provider endpoint、模型名（不要记录 API Key）；
- 场景、输入、实际工具调用顺序；
- 是否产生真实播放器/队列/歌单/索引变化；
- UI 是否泄漏内部 repair 文本；
- 失败时的 diagnostics 阶段和结构化 failure code。

不要把 API Key、Cookie、Authorization header 或包含凭据的 URL 写入日志、截图或 issue。
