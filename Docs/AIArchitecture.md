# AI Architecture

## 原则

AI 不在播放可靠性关键路径内，不直接访问数据库，不写音频文件，不生成不存在的 Track ID，
也不能发明 MusicBrainz ID、发行日期或参与人员。

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

Phase 5 默认接入 `/v1/chat/completions`，并保留未来 `/v1/responses` adapter。SSE parser
支持分块和多行 data；网络层将补齐 Task cancellation、指数退避、代理与生产环境证书策略。

## 工具边界

工具集合由 `MusicAssistantTool` 建模。读操作返回最小字段；普通播放、队列、下载、服务器
和标注写操作保持直接执行，只有删除歌单、删除/清空记忆、删除技能文件等不可逆操作生成待
确认 Action Plan。每次输出在展示和执行前分别校验 Track ID。

## Token 和上下文

会话保存结构化条件而不是无限追加完整聊天。每轮保留当前约束、最近决定和候选摘要；超出
Provider 声明的上下文窗口后生成本地摘要。AI 层不再设置固定 256K/16K 上限；默认不含
完整歌词、路径、NAS 地址、令牌或设备标识，隐私数据仍受各自开关约束。
