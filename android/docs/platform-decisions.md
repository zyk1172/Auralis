# Auralis Android — 平台决策记录

> 迁移过程中与 Apple 实现不同的决策、理由与范围裁剪。每条都给出差异与原因，
> 供后续维护者（或反向往 iOS 回灌改进）参考。

## 1. core:data 全表带 `server_id` 列（相对 Apple catalog.sqlite）

**差异**：Apple 的 `favorites/ratings/play_history/downloads/lyrics` 只靠 `global_id`
前缀（`"{serverId}:{remoteId}"`）隔离服务器，无独立 `server_id` 列。Android Room 版本
**所有表都带 `server_id` 列并建索引**。

**理由**：
- 按服务器批量清理（删除服务器 → 清除其全部本地痕迹）只需一次索引查询，
  不需要 LIKE `'{sid}:%'` 扫描；
- 索引可为将来跨服务器统计/去重提供列级支持；
- 审计报告 03-local-catalog.md 明确建议补列。

**代价**：写入需冗余维护该列；由 DAO 层在 `upsert` 时统一从 `global_id` 前缀推导，调用方无感。

## 2. core:data 搜索：Room FTS4 + LIKE 退化

Room 的 FTS 在纯 Kotlin + KSP 管线可用，但对 `external content` FTS 的 schema 导出
配置较繁琐。实现采用 **`tracks` 表带索引的 `LIKE` 查询**（title/artist_name/album_title
三列 OR），查询一次性下发 SQL，**不在内存中 filter 全库**。

**后续升级路径**：若目录规模需要 FTS，可加 `@Fts4` 影子表并用触发器回填，DAO 接口不变。

## 3. core:ai 只实现 Chat Completions（相对 Swift AIKit 双协议）

**差异**：Swift `OpenAICompatibleProvider` 同时支持 Chat Completions、Responses API 与
Anthropic Messages。Android 子集**只实现 Chat Completions**（`/v1/chat/completions`）。

**理由**：
- 本 App 主要对接 Navidrome 生态用户自建的 OpenAI 兼容网关（LM Studio / Ollama /
  DeepSeek / OpenRouter 等），全部走 Chat Completions；
- Responses API 的 hosted web 工具依赖不同请求结构，Android 首版不承诺。

**行为**：`apiPath` 命中 `/responses` 或 Anthropic `/messages` 时抛出
`AiProviderException`（IncompatibleRequest），不静默降级。

## 4. AI 工具循环语义与 Swift AgentKit 对齐但规模裁剪

Android `AgentToolLoop` 保留了审计 §5.2/5.3 的**三条不变式**：
1. 副作用唯一边界 = `AgentToolRegistry.execute`（先校验后执行，无第二套执行系统）；
2. 最小授权：`SideEffectAuthorizationContext` 只来自用户请求解析出的 canonical
   operation；未授权写操作 `fail closed`；
3. 仅 `Destructive` 工具（playlist/memory/skill 删除）在副作用前挂起等 UI 确认，
   确认绑定具体 run（由上层 Coordinator 负责）。

**裁剪**：`tool_search` 动态发现、RecommendationIndex Skill、`AgentRuntime` 工作流、
`AgentActionLog`（undo/clear）放到 feature/assistant 或后续迭代，不进 core:ai。

## 5. 流式工具调用：按 index 跨 chunk 拼接，流末统一产出

对齐 Swift `chatStream`：`delta.tool_calls` 的 id/name/arguments 分片按 `index` 累积，
到 `[DONE]` / `finish_reason` / 自然结束才 flush 完整 `AiToolCall`，避免参数截断。
`reasoning_content` → `ReasoningDelta`（绝不持久化）；无法分类的正文 → `UnknownDelta`
（保持可见，绝不静默丢弃）。

## 6. 400/422 参数降级边界

仅当服务端 detail 提到 `temperature` / `max_tokens` 时做字段名适配重试一次；
**绝不删除 tools/tool_choice**——网关不支持原生工具时保留原错误，让上层报告原生协议失败。

## 7. Gradle / SDK 基线

- Gradle 8.9（本地 wrapper 分发网络受限，用同版本本地 Gradle 驱动；`gradle-wrapper.properties`
  已就位，联网环境 `./gradlew` 可直接用）
- JDK 17（`$HOME/Library/Java/JavaVirtualMachines/jdk-17.0.20.1+1`）
- compileSdk 34 / minSdk 26 / targetSdk 34，Kotlin jvmTarget 17
- 模块：11 core + 7 feature + app-mobile + app-tv（TV 不含 feature:assistant 与 core:ai）

## 8. 测试策略

- core:data：Room in-memory（`room-testing`），无 Robolectric 时兜底纯 JVM 逻辑测试。
- core:ai：MockWebServer 集成（非流式/SSE 碎片拼接/参数降级/错误分类）+ FakeProvider
  循环语义测试，`testDebugUnitTest` 全绿。
- 单测跑在 Android library 模块的 `testDebugUnitTest`（JVM），无需设备。

## 9. App 壳与页面导航规划（对齐 audit 06）

- 底部一级导航只有 **3 个**：Home / Library / Assistant（Dock 圆按钮）。
- **Settings 不在 Dock**：Library 顶栏齿轮入口。
- **Search 不在 Dock**：由 Assistant 页以 sheet 拉起「搜索音乐库」。
- Android 不把 Search/Settings 做成底部 Tab。

## 10. 状态：2026-09-07 快照

- core 全部 11 模块编译通过；core:ai 11 项单测通过。
- `app-mobile-debug.apk` / `app-tv-debug.apk` 可打包（23MB）。
- feature/* 七个模块为空壳，待填充页面（下一步）。
