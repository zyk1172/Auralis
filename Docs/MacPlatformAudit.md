# macOS 平台规范化审计

目标：把 Mac 端从“iOS 组件 + 自定义窗口 workaround + 桌面页面”整理成符合 macOS 使用方式的原生桌面播放器。
Deployment Target 保持 macOS 15.0；macOS 27 独占 API 一律使用 `#available`。

## 窗口 / 场景

- 恢复系统窗口 chrome（删除 `.windowStyle(.hiddenTitleBar)`），使用标准 `WindowGroup` + `Settings` Scene。
- 播放快捷键（上一首 Command-Left / 下一首 Command-Right）走 `CommandMenu("播放")`；Space 播放/暂停的唯一入口为根视图 `.onKeyPress(.space)`——菜单不再注册裸 Space 快捷键，避免 AppKit 菜单 key-equivalent 在文本输入框抢键；输入框内由 firstResponder 文本检测（NSTextView / 可编辑 NSTextField）放行，空格正常输入。
- Command-F 聚焦侧边栏搜索、Command-L 定位当前歌曲、Command-Option-I 切换 Inspector。

## Sidebar / Toolbar / Inspector

- `MacAuralisRootView` 改为 `NavigationSplitView`：侧边栏（资料库 / 分类 / 服务器 / 设置入口），主内容 `NavigationStack`，`Inspector` 用系统 `.inspector(isPresented:)` + `.inspectorColumnWidth`。
- 内容路由 `MacContentRoute`：album / artist / genre / playlist / nowPlaying 进主内容栈；sheet 只保留首次服务器配置。
- Inspector 上下文优先级：多选摘要 > 选中单曲 > 正在播放 > 空状态；不再每次切歌强制弹出。
- 删除了旧自绘 `contentActionBar` 与 `.toolbarVisibility(.hidden)`。

## 表格 / 多选 / 右键

- `MacSongTable` 统一使用 `GlobalID` 作为 selection 类型；支持表头排序（年份 / 编码 / 收藏稳定投影）。
- 右键菜单：播放 / 下一首 / 加队列 / 前往专辑 / 前往艺术家 / 收藏 / 不喜欢 / 下载 / 歌曲鉴赏 / 歌曲信息。
- 专辑 / 艺术家 / 歌单详情页复用同一套 `MacSongTable` 与尺寸常量。

## 搜索

- 搜索结果歌曲按 `GlobalID`（serverID + remoteID）双键解析，禁止只按 remoteID 匹配。
- 搜索结果专辑显示真实封面（解析本地 album.artworkKey）；艺术家卡片与“最近播放的艺术家”可点击进入艺术家路由。

## 设置窗口（Settings Scene）

- `MacSettingsWindow` 顶部分类：通用 / 服务器 / 音乐库 / 缓存 / 下载 / AI 助手 / 快捷指令与 Siri / 高级 / 关于。
- AI 助手页：AI 与隐私、OpenAI 兼容接口、高级设置（上下文窗口 / 单次输出上限，各一份）、公开音乐数据（总开关 + 三来源独立开关 + 清缓存 + 重置身份）、推荐索引 V2（状态 / 开始或继续 / 导出 / 导入 / 刷新）、Agent 记忆、音乐下载（MoviePilot）。
- 版本号从 `Bundle.main` 读取（`AppVersionInfo.display`），不硬编码。

## 服务器页 / 本地网络

- 常驻“局域网访问”提示横幅已从正常使用主流程移除；仅在连接错误信息包含“本地网络”时显示“打开本地网络设置”直达入口。
- 保留正确的 `NSLocalNetworkUsageDescription` 与沙盒网络配置。

## 播放器

- Desktop Player 前 / 后使用 `canGoPrevious` / `canGoNext`；左侧显示当前歌曲收藏 / 不喜欢状态；点击封面仅导航到主内容 `MacNowPlayingPage`（不再设置 iOS 式 `isNowPlayingPresented`，也无 `.onTapGesture` 双重触发）。

## 构建与测试

- macOS 与 iOS target 均通过 `xcodebuild build`（strict concurrency complete、warnings-as-errors）。
- AppShell 逻辑测试（含共享播放能力、GlobalID 跨服务器、Siri 排除）在 macOS destination 上全部通过；不依赖 Simulator。
