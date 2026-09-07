# Auralis Android — UI 对齐跟踪（ui-parity）

> 页面级对齐清单：每个用户可见入口 → Swift 基准视图文件 → Android 目标模块 →
> 状态（**Done / Partial / Not Started / N/A**）+ 按钮级规格核对勾选。
> 铁律（来自项目规格）：每个用户可见按钮必须有真实 action / loading / disabled /
> success / failure / confirmation，禁止静默 no-op；禁止 Fake 正式数据。
> 填表人在改完一个页面后立即在此打勾，并注明 Android 实现文件与 Swift 基准文件。

## 一级导航壳

| 页面 | Swift 基准 | Android 目标 | 状态 |
|---|---|---|---|
| Bottom Dock（3 Tab：Home/Library/Assistant 圆钮） | AuralisRootView.swift BottomDock | app-mobile/shell | Done（S2：宽屏居中 ≤760dp、图标对齐 house/square.stack/sparkles、悬浮 overlay） |
| Mini Player（Dock 上方胶囊） | AuralisRootView MiniPlayerContent | app-mobile/shell | Partial（S2：真实绑定 playback StateFlow；封面/标题/艺人/播放暂停；展开 Now Playing 待 S5） |
| 分区内容根 + 切换回根 | IOSMusicShell / SectionContent | MobileShell | Partial（S3 已替换 Home 为真实页；Library/Assistant 占位待 S4/S8） |
| 服务器选择/切换入口 | SettingsView「服务器」行 | SettingsPlaceholderPage → ServerList | Partial（S2 起真实可用；完整设置页待 S7） |
| 设置齿轮入口（Library 顶栏） | AppShell Library 顶栏 | LibraryPlaceholderPage 齿轮 | Partial（打开设置占位；S4/S7 完善） |
| 「首页布局」编辑入口（设置→外观） | SettingsView「首页布局」 | SettingsPlaceholderPage → HomeLayoutEdit | Done（S3：入口已接，编辑页真实持久化） |

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
| 首页内容区（顺序 JSON 驱动 + 加载/无服务器/错误/空态） | HomeView/HomeModule.swift | Done（S3：feature:home，模块注册表驱动） | ☑ 模块顺序尊重 HomeLayoutPreference（读写归一化） ☑ 各模块真实数据（SQL 派生） ☑ 目录变化自动刷新 ☑ 模块关闭不渲染不查数据 |
| 「换一批」（random/favoriteRandom 本地重采样） | HomeView reshuffle | Done（S3） | ☑ 点击即换（样本 18，不发网络） ☑ loading/无数据态 |
| 快捷入口行（Playlists/Favorites/MostPlayed，3 列 icon+count） | HomeQuickEntry | Done（S3） | ☑ 点击 → 切 Library 携带 BrowseDestination ☑ 无数据模块暂不渲染（配置保持） |
| 内容 shelf（曲目/艺人/专辑 140dp 卡） | HomeShelfView | Done（S3） | ☑ 曲目卡点击 → playQueue(startIndex) 真播放 ☑ 引擎未就绪先起服务幂等，不假装播放 ☑ 艺人/专辑卡 → BrowseDestination |
| 「数量 ›」整组入口 + 库统计摘要 | HomeView | Done（S3） | ☑ 点击携带对应 BrowseDestination（Downloads 映射 Home 专属） |
| 无服务器/加载失败可见反馈 | HomeView 错误态 | Done（S3） | ☑ 无服务器 → 引导管理服务器入口 ☑ 出错 → 显示错误 + 可重试 |
| 布局编辑（隐藏/排序/恢复默认） | HomeLayoutEditView.swift | Done（S3：HomeLayoutEditScreen） | ☑ 每行 Switch 即时持久化 ☑ 上移/下移排序（按钮替代拖拽） ☑ 恢复默认 → AlertDialog 二次确认 ☑ 「完成」返回 |
| 编辑入口（设置→首页布局） | SettingsView 外观 | Done（S3） | ☑ Library 齿轮 → 设置 → 首页布局行 → 编辑页 |

## Library / Browse

| 页面 | Swift 基准 | 状态 | 按钮级核对 |
|---|---|---|---|
| 库总览（7 scope 分段：专辑/歌曲/艺人/歌单/收藏/流派/分类） | LibraryView.swift | Done（S4） | ☑ scope 切换真实数据 ☑ 空态引导 ☑ 分类=能力说明 |
| 专辑/艺人/歌单/流派列表与网格 | LibraryView.swift | Done（S4） | ☑ ⋮ 播放全部/收藏/下载 ☑ 行尾 ⋯ 菜单全部动作真实 ☑ 只读歌单禁用写操作 |
| 列表页（加载态/错误态重试/空态） | — | Done（S4） | ☑ Loading/Error+重试/Empty |
| Browse Detail 17 目的地（专辑/艺人/歌单/收藏/各统计列表/流派/常听/下载/推荐分类） | BrowseDetailSheet | Done（S4） | ☑ 头图 88+标题 ☑ 播放全部/下载(确认弹窗) ☑ 换一批 ☑ 点行整组从该行起播 ☑ 错误重试 ☑ 推荐分类=能力说明 |
| 歌单详情（排序总览/管理菜单/行移除） | PlaylistTracksView + AuralisAppModel | Done（S4） | ☑ 重命名/复制/去重/删除二次确认 ☑ 从歌单移除二次确认 ☑ 远端先行+失败反馈 |

## 播放器

| 页面 | Swift 基准 | 状态 | 按钮级核对 |
|---|---|---|---|
| Mini Player（Dock 上方 56 胶囊） | MiniPlayerContent | Done（S5） | ☑ 封面/标题/艺人 ☑ 上一首/播放暂停/下一首真实绑定 ☑ 缓冲 spinner ☑ 点击展开 Now Playing |
| Now Playing | NowPlayingView | Done（S5） | ☑ 渐变背景 ☑ 分段：歌词/正在播放/队列 ☑ hero 封面 ☑ 跑马灯标题/艺人 ☑ 进度拖动→松手 seek ☑ 五键传输区（播放模式循环/上一首/播放/下一首/⋯）☑ 收藏 ☑ 下载三态 ☑ 添加到歌单 ☑ 前往专辑/艺术家 ☑ 音量 ☑ 音频信息 |
| Queue | QueueView + PlaybackQueuePresentationStore | Done（S5） | ☑ 点行播放该 occurrence ☑ 编辑：移除/上移/下移 ☑ 大队列窗口计数 ☑ 当前行高亮 |
| Lyrics（同步歌词按位置高亮自动滚动/纯文本降级/空态） | NowPlaying lyrics | Done（S5） | ☑ 位置高亮+滚动 ☑ 无歌词空态 ☑ 加载失败重试 |

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

> 当前状态：**P0 Core 九项（数据/播放/下载/歌词链路）已 Done**；S1 服务器链路
> （feature:server）已接入 app-mobile 路由；S2 Mobile Shell + Bottom Dock 完成；
> **S3 Home 完成**（feature:home 注册表驱动 + HomeLayoutEditScreen + MobileShell 接线，
> Home 分区已是真实页，播放/浏览动作真实；app-mobile-debug.apk 已打包）。
> **S4 Library + Browse Detail 完成**（feature:library：7 scope 音乐库 + 17 目的地
> BrowseDetail 覆盖路由 + 歌单远端先行管理 + insertNext/appendToQueue 接线；APK 已打包）。
> **S5 播放器 UI 完成**（feature:player NowPlaying 三页：hero/同步歌词/队列编辑 + Mini
> Player 展开/切歌 + engine 250ms 位置节拍 + 音量/收藏/下载/加歌单真实动作；APK 已打包）。
> 下一步：S6 Search。
> 最后更新：2026-09-07
