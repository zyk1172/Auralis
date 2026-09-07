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
| 服务器列表（已存服务器/切换/编辑/删除） | MacServerPage.swift | Partial（feature:server 已建，壳期占位入口） | ☑ 点行切换当前服务器 ☑ 编辑入口 ☑ 删除二次确认（只删本地，文案对齐） ☑ 空状态引导添加 |
| 添加服务器（显示名/内网地址/用户名/密码/外网地址） | ServerConnectionSheet.swift | Partial | ☑ 保存 action/loading/阶段进度 ☑ canSave（必填齐全才可点） ☑ 成功→登记注册表+目录同步 ☑ 失败→回滚+分类错误可折叠详情 |
| 编辑服务器（密码留空沿用旧凭据、身份稳定） | SettingsView 编辑页 | Partial | ☑ 保存走 core edit()（不新建重复服务器/不删已同步目录） ☑ 密码留空沿用已存凭据 ☑ 失败恢复旧账户+旧凭据 |
| 测试连接（不保存凭据、不同步） | ServerConnectionSheet.runTest | Partial | ☑ 测试中 loading ☑ 成功/用户名或密码错误/无法连接 状态行 ☑ 地址策略前置（http 公网/内嵌凭据被拒） |
| 恢复链路（冷启动已存服务器不联网出界面） | restoreLastConnection | Partial | ☑ bootstrapFromLocal 恢复账户+端点登记 ☑ 无服务器→空状态引导；有→进主界面 |
| URL 策略（embedded creds / http 公网拒绝） | ServerURLPolicy | Done（core:data 层，UI 复用） | ☑ 单测覆盖（IPv4/IPv6/公网/内嵌凭据） |

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

> 当前状态：**P0 Core 九项（数据/播放/下载/歌词链路）已 Done**；S1 服务器添加/恢复链路
> （feature:server）已落地并接入 app-mobile 路由（Boot→列表/添加→主界面占位）；
> 待 Mobile Shell（S2）接入后替换占位主界面。
> 最后更新：2026-09-07
