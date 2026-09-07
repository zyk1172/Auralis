# Android 文案本地化规范（R5）

审查 P1「中文硬编码」的落地规则。目标：用户可见 UI 文案一律走 Android 资源，
与 Apple `String(localized:, bundle:)` 对齐；默认开发语言 = 中文（与 Swift 源码一致），
英文副本放 `values-en`。

## 资源分层（避免合并冲突）

1. **跨模块共享文案** → `core:designsystem/res/values*/strings.xml`
   任何模块都依赖 `core:designsystem`。引用写法：
   ```kotlin
   import com.auralis.core.designsystem.R as AuralisR
   Icon(..., contentDescription = stringResource(AuralisR.string.back))
   ```
   **规则：同一个 key 只允许定义一次**（Android 多模块资源合并对重名冲突直接报错）。
2. **模块独有文案** → 各 feature 自己的 `res/values/strings.xml`，key 一律带模块前缀
   （`search_*` / `player_*` / `library_*` / `settings_*` / `assistant_*` / `server_*` / `home_*`…），
   本模块代码直接 `stringResource(R.string.search_xxx)`（同包 R，无需 import）。
3. 每个 values 目录都配 `values-en/` 英文副本。

## 代码侧规则

- **Composable 内**：`Text("中文")` → `Text(stringResource(R.string.x))`；
  `contentDescription = "中文"`、按钮/菜单/DropdownMenuItem 文案同理。
- **运行时（协程/非 Composable）错误兜底文案**：不能直接 stringResource。
  在 Composable 顶部取 `val context = LocalContext.current`，
  协程内用 `context.getString(R.string.x)`。
- **带参数文案**：资源写 `%1$s` 等占位符，调用
  `stringResource(R.string.x, arg1, arg2)`（Compose 自动 format）。
- **范围边界（有意保留为字面中文，不迁移）**：
  - 助手/Agent 的**会话与工具文案**（SYSTEM_PROMPT、工具种子引导、工具返回给模型的
    结构化消息、`AssistantToolHost` executor 内文案）——这是面向 LLM 的产品内容语言，
    不是 UI 本地化面，Swift 端同样是开发语言中文写死在工具层；
  - 日志、单元测试、`@Suppress` 注释。
- **排雷**：资源文件名/占位符数量必须与调用参数匹配；lint 会在 assemble 阶段
  校验 `%d/%s` 数量（用 `%1$s` 并传参即可通过）。

## 迁移节奏

每模块：抽词 → values + values-en → 替换 → 该模块 `compileDebugKotlin` + `:app-mobile:assembleDebug`。
已完成：`feature:search`（22 处，零插值，样板）/ `feature:server`（52 处：表单/列表/删除确认/连接
阶段 `ConnectionStage.titleRes()` + 模型层注入 Context）/ `feature:player`（61 处：播放页/歌词/
队列/传输/菜单 + `PlayerTab.titleRes()`、`PlayMode.modeTitleRes()`、`audioTechnicalLabel(context,…)`；
共享层新增通用动作动词 play/pause/previous/next/favorite/unfavorite/dislike/undislike/edit/done/
retry/add_to_playlist）/ `feature:home`（44 处：模块标题 `HomeModuleId.titleRes`/`HomeQuickEntry.titleRes`、
货架计数/空态/布局编辑页 + `HomeState` 注入 Context；上移/下移/添加服务器提升共享层
move_up/move_down/add_server，player/server 同义本地 key 一并归一化）。
待迁移（按量）：library 204 / settings 97 / assistant 245（其中大量为工具/会话文案属
边界，实际 UI 面更小）/ app-mobile 31 / app-tv 11 / designsystem 12（共享层按需进 core:designsystem）。
