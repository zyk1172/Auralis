# Apple 平台卡片圆角

iOS / iPadOS 与 macOS 的自定义卡片、封面、消息气泡及圆角面板统一使用 Apple
原生的连续曲率圆角（continuous corners）。普通圆角把直线与固定半径圆弧相接，
连接处曲率从 0 跳变；连续圆角会让曲率逐渐变化，使直线进入圆角的过渡更自然。
只增加圆角半径不能替代这种过渡。

## 实现约定

SwiftUI 明确指定 `.continuous`，省略 `style` 的 `RoundedRectangle` 默认使用
`.circular`。背景、内容裁剪和描边应使用相同的半径与曲线类型：

```swift
let shape = RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous)

content
    .background(theme.colorTokens.surface.color, in: shape)
    .clipShape(shape)
    .overlay(shape.strokeBorder(theme.colorTokens.separator.color))
```

尺寸沿用 `AuralisRadius` 或 Mac 的 `MacUIVisualTokens`；本次统一曲线类型，
保留现有布局及各类卡片的半径。封面加载完成与占位状态应保持相同轮廓。
圆形头像、胶囊控件、系统管理的列表/窗口和半径为 0 的拼图内部单元保持其语义形状。

未来若直接用 UIKit / AppKit 图层实现圆角，应同时设置 `cornerRadius` 和
`layer.cornerCurve = .continuous`，避免使用默认圆弧。

## 本次检查与修正

- iOS：首页、资料库、主题卡片、封面及主要播放面板已使用连续圆角。
  补齐搜索框、播放队列编辑控件、分类进度卡片、AI 助手和 Live Activity 封面。
- macOS：原生专辑/歌单/流派 tile、拼图外框、搜索、设置、下载和播放器圆角已显式
  使用 `.continuous`；共享 AI 助手界面随本次修正统一。
- AI 助手包括会话搜索、思考状态、普通/流式消息、联网来源、歌单提案、操作预览，
  以及歌曲/专辑/歌单/艺术家结果卡片。

## 参考资料

- [Apple：RoundedCornerStyle.continuous](https://developer.apple.com/documentation/swiftui/roundedcornerstyle/continuous)
  将此样式定义为连续曲率圆角。
- [Apple：CALayerCornerCurve.continuous](https://developer.apple.com/documentation/quartzcore/calayercornercurve/continuous)
  说明图层圆角使用连续变化的曲率。
- [Figma 工程分析：Desperately seeking squircles](https://www.figma.com/blog/desperately-seeking-squircles/)
  解释直线和圆弧连接处的曲率跳变、连续过渡及 Bézier 曲线构造。
- [Figma：Adjust corner radius and smoothing](https://help.figma.com/hc/en-us/articles/360050986854-Adjust-corner-radius-and-smoothing)
  提供 iOS 的 60% smoothing 预设。这是 Figma 的设计参数，不是 SwiftUI 的参数，
  也不代表所有尺寸下与 Apple 原生曲线逐像素一致；原生 App 使用系统实现。
