# Apple 平台规范化审计

审计范围：iPhone 紧凑布局、iPad 分栏布局、macOS 独立主窗口、正在播放页、AI 助手与设置页。

参考基准：

- Apple Human Interface Guidelines：Accessibility、Motion。
- SwiftUI `NavigationStack` / `NavigationSplitView`。
- SwiftUI `tabViewBottomAccessory`、`tabBarMinimizeBehavior`。
- SwiftUI Liquid Glass（`glassEffect`）。

## Navigation

- iPhone 的专辑、艺术家、歌单、流派和分类详情已由 modal sheet 改为 `NavigationStack` 的 `navigationDestination(item:)`。返回手势、标题层级和 VoiceOver 导航语义由系统承接。
- 添加到歌单、歌曲信息、服务器配置、编辑首页、确认对话框与正在播放页仍是 modal task，继续使用 sheet / dialog。
- iPhone 与 iPad 共用 `IOSMusicShell` + `NavigationStack`；iPad 通过可读宽度、浮动 Dock
  和尺寸自适应承接 regular / compact / Stage Manager，而不是维护第二套 Pad 信息架构。
  macOS 仍保留独立的资料库侧边栏与专辑内容页。
- `BrowseDestination` 现在是稳定的 `Hashable & Sendable` 导航值；新增测试覆盖 ID 唯一性。

## Bottom navigation 与 Mini Player

项目最低 iOS 版本为 26，系统具备 `tabViewBottomAccessory` 与 `tabBarMinimizeBehavior`。本轮没有替换现有 Dock，原因不是兼容性，而是系统 API 不能同时完整表达以下现有产品行为：

1. 同一 Mini Player 在双层栏与三件式紧凑栏之间连续形变；
2. AI 助手输入框占用同一附件位置；
3. 首页入口在紧凑态承担“展开 Dock”而非简单切换 Tab；
4. 播放器、AI 输入、键盘避让共用同一安全区高度。

因此只保留当前单一自定义实现，没有增加第二套系统 TabView 路径。手势阈值、固定时长、Reduce Motion 路径已有自动测试。

## Accessibility 修复

- 首页设置、AI 发送、AirPlay、搜索清除等控件的 iOS 点击区域提升到至少 44 pt。
- 资料库歌曲、专辑、艺术家与搜索歌曲结果从裸 `onTapGesture` 改为语义化 `Button`，并补充 VoiceOver 动作说明。
- 首页快捷入口补充“模块名称 + 数量”的 VoiceOver 标签，避免只读出数字。
- Dock、播放控制与 AI 标题栏已有明确 `accessibilityLabel`；播放进度和音量保留 `accessibilityValue` / 系统 Slider 语义。
- Reduce Motion 继续使用较短、无弹跳的端点动画；Reduce Transparency 现在会移除 Dock 的 Liquid Glass 和大阴影，改用不透明系统背景。

## Liquid Glass

- Glass 仅用于底部导航、Mini Player、紧凑入口等控制层；正文卡片与资料库列表不叠加 Glass。
- 正常模式保留连续形变所需的玻璃表面；Reduce Transparency 下不再渲染 glass-on-glass。
- 无障碍模式将 12 pt 阴影降为 4 pt，避免高对比设置下产生厚重浮层。

## MANUAL-VERIFY

1. Xcode Beta 用 iPhone 真机分别开启 VoiceOver、放大字体、Reduce Motion、Reduce Transparency、Increase Contrast。
2. 从首页依次进入专辑 → 艺术家 → 其他专辑，验证边缘返回手势、返回标题和当前内容状态。
3. 使用 VoiceOver 顺序遍历首页、音乐库、AI 助手、正在播放页；确认每个图标按钮能读出动作而不是只读 SF Symbol 名。
4. 在键盘显示/隐藏、旋转、Split View 尺寸变化时检查 Dock 和输入框安全区。
5. 在真实歌曲播放期间反复展开/收拢 Dock，确认 Liquid Glass 手感、Reduce Motion 路径与 Reduce Transparency 实色路径。
6. macOS 使用键盘、VoiceOver 与 Full Keyboard Access 遍历侧边栏、内容、Inspector 和底部播放条。

自动构建/测试不能替代上述真机辅助功能与动画手感检查。
