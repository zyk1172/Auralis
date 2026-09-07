# Auralis Android — UI 对齐跟踪（ui-parity）

> 页面级对齐清单：每个用户可见入口 → Swift 基准视图文件 → Android 目标模块 →
> 状态（**Done / Partial / Not Started / N/A**）+ 按钮级规格核对勾选。
> 铁律（来自项目规格）：每个用户可见按钮必须有真实 action / loading / disabled /
> success / failure / confirmation，禁止静默 no-op；禁止 Fake 正式数据。
> 填表人在改完一个页面后立即在此打勾，并注明 Android 实现文件与 Swift 基准文件。

## 一级导航壳

| 页面 | Swift 基准 | Android 目标 | 状态 |
|---|---|---|---|
| Bottom Dock（3 Tab：Home/Library/Assistant 圆钮） | AppShell/*.swift | feature:home/library/assistant | Not Started |
| Mini Player（Dock 上方胶囊） | AppShell/MiniPlayer*.swift | feature:player | Not Started |
| 服务器选择/切换（Dock 左侧） | AppShell/ServerPicker*.swift | feature:server | Not Started |
| 设置齿轮入口（Library 顶栏） | AppShell/*.swift | feature:settings | Not Started |

## 服务器

| 页面 | Swift 基准 | 状态 | 按钮级核对 |
|---|---|---|---|
| 添加服务器（内网/外网双地址 + 用户名/口令 + 探测） | ProductionServerConnector.swift + ServerOnboarding | Not Started | ☐ 连接按钮 action/loading/disabled ☐ 成功→注册表登记 ☐ 失败→回滚 + 错误显示 ☐ 编辑/恢复 ☐ 忘记服务器二次确认 |
| 恢复服务器（扫描历史/凭据已存） | — | Not Started | ☐ |

## Home

| 模块 | Swift 基准 | 状态 | 按钮级核对 |
|---|---|---|---|
| 首页内容区（顺序 JSON 驱动） | HomeView/HomeModule.swift | Not Started | ☐ 模块顺序尊重 HomeLayoutPreference ☐ 每模块 reshuffle 按钮 |
| 快捷入口行（Playlists/Favorites/MostPlayed） | — | Not Started | ☐ |
| 布局编辑（隐藏/排序/恢复默认） | HomeLayoutStore.swift | Not Started | ☐ |

## Library / Browse

| 页面 | Swift 基准 | 状态 | 按钮级核对 |
|---|---|---|---|
| 库总览（歌曲/专辑/艺人/播放列表/收藏） | LibraryView.swift | Not Started | ☐ |
| 列表页（分页/加载态/错误态） | — | Not Started | ☐ |
| Browse Detail（专辑/艺人详情、收藏/评分、播放） | BrowseDetail*.swift | Not Started | ☐ 收藏按钮 action/loading ☐ 播放全部 ☐ 队列加入反馈 |

## 播放器

| 页面 | Swift 基准 | 状态 | 按钮级核对 |
|---|---|---|---|
| Mini Player | MiniPlayer*.swift | Not Started | ☐ 播放/暂停 ☐ 进度 ☐ 点击展开 |
| Now Playing | NowPlayingView.swift | Not Started | ☐ 播放/暂停/上一首/下一首 ☐ 进度拖动 ☐ 收藏 ☐ 歌词入口 |
| Queue | QueueView.swift | Not Started | ☐ 移除/清空/重排（若 Swift 有） |
| Lyrics（逐行高亮/纯文本降级） | LyricsView.swift | Not Started | ☐ |

## Search

| 页面 | Swift 基准 | 状态 | 按钮级核对 |
|---|---|---|---|
| 搜索（sheet 拉起、FTS 中文） | SearchView.swift | Not Started | ☐ 输入防抖 ☐ 结果点击→播放 |
| 搜索历史/清空 | — | Not Started | ☐ |

## Settings

| 页面 | Swift 基准 | 状态 | 按钮级核对 |
|---|---|---|---|
| 主题选择 | SettingsView.swift | Not Started | ☐ |
| 服务器管理（编辑/忘记） | SettingsView.swift | Not Started | ☐ 忘记二次确认 |
| 流质量/下载/历史开关 | SettingsView.swift | Not Started | ☐ |

## Assistant

| 页面 | Swift 基准 | 状态 | 按钮级核对 |
|---|---|---|---|
| Assistant 对话页（含工具授权 UI） | AgentKit/App 侧 | Not Started | ☐ 副作用确认绑定 run ☐ |
| 搜索音乐库 sheet | — | Not Started | ☐ |

## Android TV

| 页面 | Swift 基准 | 状态 | 按钮级核对 |
|---|---|---|---|
| TV 壳（Leanback，无 Assistant） | — | Not Started | ☐ |

> 当前状态：**P0 Core 九项（数据/播放/下载/歌词链路）已 Done**；所有页面 UI 尚未开始，
> 按序先做 Server 添加/恢复链路（feature:server）。
> 最后更新：2026-09-07
