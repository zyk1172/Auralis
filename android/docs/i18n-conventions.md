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
move_up/move_down/add_server，player/server 同义本地 key 一并归一化）/ `feature:settings`（97 处：
根页/播放与音质/数据与备份/主题/AI 助手设置页，协程内提示经 LocalContext context.getString；
保存/测试连接/服务器/歌曲计数提升共享 save/test_connection/servers/count_songs，server
同义本地 key server_save/server_test_action/server_title、home 的 home_count_tracks 一并归一化）/
`feature:library`（204 处：7 scope 分段 `LibraryScope.titleRes()`、浏览详情 `destinationTitle` 全量资源化、
各 scope 加载/空态/服务器未连提示、专辑卡/艺术家行菜单动作与消息、曲目行徽标与菜单、
歌单总览排序/删除确认、歌单管理重命名/复制/去重、常听艺术家/专辑、下载确认与从歌单移除二次确认。
`loadDetail`/`PlaylistAddDialog`/`PlaylistManageMenu`/`TopArtist*` 等非 Composable 场景经
`LocalContext`+`context.getString`；新建/加入歌单对话框簇 14 key 与播放页共享提升共享层
new_playlist_and_add/playlist_name_label/no_playlists_yet/readonly_playlist_hint/server_no_new_playlist/
creating/create_and_add/new_playlist/added_to_playlist/got_it/download_to_local/action_failed/
favorite_failed/download_failed，feature:player 同义 player_* key 一并删除归一化）。
`feature:assistant`（命中 245：其中 ToolHost 工具描述/参数 JSON/executor 返回、GuidedSessions 种子、
SYSTEM_PROMPT 等约 200 处属面向 LLM 的会话/工具文案，按边界规则保留中文；实际迁移 UI 面约 45 处：
Header/输入区/空态/运行阶段行/会话与操作日志弹窗/首次外发与写操作确认/错误与引导消息；
`AssistantRunPhase.displayText` → `labelRes()`、`AssistantToolHost.toolLabel()` → `@StringRes toolLabelRes()`
（31 项工具行标签）、模型层「新会话」fallback 上移 UI；「取消/删除/保存/未知错误」引用共享层）/
`app-mobile`（31 处：一级分区 `AppSection.labelRes`、Dock/MiniPlayer 播放传输描述复用 AuralisR、
Library 占位页 `BrowseDestination.titleRes()` + 标题/引导文案、播放服务启动 Toast）/
`app-tv`（11 处：`TvSection.labelRes`、正在播放条封面/缓冲与传输描述复用 AuralisR、设置入口、Toast）。
剩余：designsystem 12（共享层按需进 core:designsystem）+ 归一化收口轮。

## 归一化待办（跨模块同值 key，建议全部模块迁移完后一次收口到共享层）

| 中文值 | 现 key（重复方） | 建议共享 key |
|---|---|---|
| 最常听 | home:home_quick_most_played / library:library_dest_most_played / app-mobile:mobile_dest_most_played | most_played |
| 最近播放 | home:home_module_recently_played / library:library_dest_recently_played / app-mobile:mobile_dest_recently_played | recently_played |
| 最近添加 | home:home_module_recently_added / library:library_dest_recently_added / app-mobile:mobile_dest_recently_added | recently_added |
| 很久没听 | home:home_module_long_unplayed / library:library_dest_long_unplayed / app-mobile:mobile_dest_long_unplayed | long_unplayed |
| 收藏里随便听 | home:home_module_favorite_random / library:library_dest_favorite_random / app-mobile:mobile_dest_favorite_random | favorite_random |
| 从未播放 | home:home_module_never_played / library:library_dest_never_played / app-mobile:mobile_dest_never_played | never_played |
| 常听艺术家 | home:home_module_top_artists / library:library_dest_top_artists / app-mobile:mobile_dest_top_artists | top_artists |
| 常听专辑 | home:home_module_top_albums / library:library_dest_top_albums / app-mobile:mobile_dest_top_albums | top_albums |
| 随机音乐 | home:home_module_random_songs / library:library_dest_random_music / app-mobile:mobile_dest_random | random_music |
| 下载 | home:home_module_downloads / library:library_dest_downloads、library_download_action / app-mobile:mobile_dest_downloads | downloads |
| 换一批 | home:home_reshuffle / library:library_shuffle_more | shuffle_more |
| %1$d 张专辑 | home:home_count_albums / library:library_album_count_format | album_count_format |
| 设置 | settings:settings_title / library:library_settings_cd / app-mobile:mobile_settings / app-tv:tv_settings | settings |
| 完成 | server:server_stage_done / designsystem:done（历史遗留） | done |
| AI 助手 | assistant:assistant_empty_title / app-mobile:mobile_ai_assistant | ai_assistant |
| 首页 | app-mobile:mobile_home / app-tv:tv_home | home_title |
| 音乐库 | app-mobile:mobile_library / app-tv:tv_library / feature:library 顶栏标题 | library_title |
| 搜索 | app-tv:tv_search | search_title |
| 封面 | app-mobile:mobile_artwork_cover / app-tv:tv_artwork_cover | artwork_cover |
| 缓冲中 | app-tv:tv_buffering | buffering |
| 播放服务启动超时，请重试 | app-mobile:mobile_playback_timeout / app-tv:tv_playback_timeout | playback_start_timeout |
| 播放歌曲/播放专辑/播放歌单/加入队列/暂停/继续播放/下一首播放/收藏歌曲/评分/新建歌单/加入歌单/删除歌单…（工具行标签，31 组） | assistant:assistant_tool_*（与 AuralisR play/pause/next/previous 与歌单簇按钮同值部分收口时直换） | assistant_tool_* → 复用共享动词/按钮词 |
