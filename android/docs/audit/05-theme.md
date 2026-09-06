# Auralis 主题系统审计（苹果 → Android Compose 迁移）

> 代码优先。本文件所有数值逐字抄自源码，未做任何重新配色或概括。
> 主要源文件：`Packages/AuralisCore/Sources/DesignSystem/ThemeContracts.swift`、`
Packages/AuralisCore/Sources/ThemeEngine/BuiltInThemes.swift`、`.../AppShell/AuralisRootView.swift`。

---

## 0. 重要更正（与用户预期不符）

| 用户预期 | 代码真实值 | 说明 |
|---|---|---|
| ThemeColors 有 **12 个**颜色字段 | **11 个** | `ThemeColors` 实际只有 11 个 `ColorToken`，无第 12 个 |
| Motion = 0.56s / reduce-motion 0.18s linear | 0.56/0.18 是 **`BottomDockMotion`**（Dock 专属），**不是**主题 `MotionTokens` | 主题的 `motion.standardDuration` 为每主题 **0.18–0.42s**，主题切换用 `easeInOut`，reduce-motion 时为 `nil`（完全无动画，非 0.18s） |
| Spacing xSmall4/small8/medium12/large20/xLarge28/huge40 | **完全一致** | 无需改动 |
| Radius small8/medium14/large22/artwork18 | **完全一致** | 无需改动 |
| 存在字体家族 / 字号 token | **不存在** | 代码里没有字号/字族 token 表；`ThemeTypography` 仅含字重与等宽开关 |

---

## 1. 完整类型定义

### 1.1 ColorToken
```swift
public struct ColorToken: Codable, Hashable, Sendable {
    public let hex: String            // 默认 alpha=1；仅 8 位 hex 才含 alpha
}
```
- 解析：`Color(hex:)` → sRGB；6 位 hex `alpha=1`，8 位 hex 末两位为 alpha。本审计全部 12 主题均使用 **6 位 hex，alpha 恒为 1**。
- 提供 `relativeLuminance`、`contrastRatio(against:)`（WCAG）用于可读性回归测试。

### 1.2 ThemeColors（**11 字段**，顺序固定）
```swift
public struct ThemeColors: Codable, Hashable, Sendable {
    public let background:      ColorToken   // 1
    public let elevated:        ColorToken   // 2
    public let surface:         ColorToken   // 3
    public let primaryText:     ColorToken   // 4
    public let secondaryText:   ColorToken   // 5
    public let accent:          ColorToken   // 6
    public let accentSecondary: ColorToken   // 7
    public let success:         ColorToken   // 8
    public let warning:         ColorToken   // 9
    public let error:           ColorToken   // 10
    public let separator:       ColorToken   // 11
}
```

### 1.3 ThemeTypography
```swift
public struct ThemeTypography: Codable, Hashable, Sendable {
    public let displayWeight: Font.WeightToken   // 默认 .bold
    public let bodyWeight:    Font.WeightToken   // 默认 .regular
    public let usesMonospacedMetrics: Bool       // 默认 false
}
```

### 1.4 Font.WeightToken（枚举，字符串可编码）
```swift
public enum WeightToken: String, Codable, Hashable, Sendable {
    case regular, medium, semibold, bold
    // value 映射：regular→.regular, medium→.medium, semibold→.semibold, bold→.bold
}
```

### 1.5 ThemeMaterialStyle（枚举）
```swift
public enum ThemeMaterialStyle: String, Codable, Hashable, Sendable {
    case solid          // 实色，opacity=1
    case subtleGlass    // 弱玻璃
    case luminousGlass  // 发光玻璃
    case paper          // 纸张
}
```

### 1.6 ThemeMaterials
```swift
public struct ThemeMaterials: Codable, Hashable, Sendable {
    public let navigation:      ThemeMaterialStyle
    public let floatingControls: ThemeMaterialStyle
    public let opacity:         Double   // solid→1，其余→0.82
}
```
> 重要：构建时 `navigation` 与 `floatingControls` **恒等于**传入的 material 参数，`opacity` 由 material 决定（solid=1，其它=0.82）。不存在「导航栏用 A、悬浮控件用 B」的混搭。

### 1.7 ArtworkStyle（枚举）
```swift
public enum ArtworkStyle: String, Codable, Hashable, Sendable {
    case softShadow   // 柔影
    case crisp        // 锐利
    case framed       // 框装
    case luminous     // 发光
}
```

### 1.8 MotionTokens
```swift
public struct MotionTokens: Codable, Hashable, Sendable {
    public let standardDuration: Double   // 主题切换/标准动画时长（秒），每主题不同
    public let ambientDuration:  Double   // 环境动画循环时长（秒），10–32
    public let glowIntensity:    Double   // 发光强度，0–0.42
}
```

### 1.9 VisualizerStyle（枚举）
```swift
public enum VisualizerStyle: String, Codable, Hashable, Sendable {
    case fluidBars     // 流体柱
    case lineSpectrum  // 线性频谱
    case vuMeter       // VU 表
    case minimal       // 极简（或无）
    case disabled      // 禁用（本审计 12 主题未使用）
}
```

### 1.10 AuralisTheme 协议（主题需实现的字段）
`id:String` · `name:String` · `colorScheme:ColorScheme`(light/dark) · `colorTokens:ThemeColors` · `typography:ThemeTypography` · `materials:ThemeMaterials` · `artworkStyle:ArtworkStyle` · `motion:MotionTokens` · `visualizer:VisualizerStyle`

### 1.11 间距与圆角 token
```swift
public enum AuralisSpacing {                 // 单位：pt
    static let xSmall: CGFloat = 4
    static let small:  CGFloat = 8
    static let medium: CGFloat = 12
    static let large:  CGFloat = 20
    static let xLarge: CGFloat = 28
    static let huge:   CGFloat = 40
}
public enum AuralisRadius {
    static let small:   CGFloat = 8
    static let medium:  CGFloat = 14
    static let large:   CGFloat = 22
    static let artwork: CGFloat = 18
}
```

---

## 2. 12 个内置主题完整数据

> `material.scheme/opacity` 由 `theme()` 工厂按规则推导：`opacity = material==.solid ? 1 : 0.82`。
> 所有主题 `typography` 均为 `displayWeight=.bold, bodyWeight=.regular`，仅 `usesMonospacedMetrics` 在 `visualizer==.vuMeter` 时为 `true`。

### 主题逐项色值表（十六进制，alpha 全为 1）

| 主题 id / 名称 | scheme | material (nav=fc) / opacity | artwork | standard / ambient / glow | visualizer | mono |
|---|---|---|---|---|---|---|
| aurora-glass / 极光玻璃 | dark | luminousGlass / 0.82 | softShadow | 0.34 / 18 / 0.42 | fluidBars | false |
| midnight-oled / 午夜 OLED | dark | solid / 1 | crisp | 0.22 / 30 / 0.08 | minimal | false |
| analog-hifi / 模拟 Hi-Fi | dark | subtleGlass / 0.82 | framed | 0.28 / 24 / 0.18 | vuMeter | **true** |
| minimal-paper / 极简纸张 | light | paper / 0.82 | crisp | 0.20 / 30 / 0.0 | minimal | false |
| neon-city / 霓虹都市 | dark | luminousGlass / 0.82 | luminous | 0.28 / 10 / 0.40 | lineSpectrum | false |
| zen-nature / 禅意自然 | light | paper / 0.82 | softShadow | 0.42 / 22 / 0.10 | minimal | false |
| cloud-village-red / 云村红 | light | subtleGlass / 0.82 | crisp | 0.24 / 26 / 0.06 | minimal | false |
| vinyl-night / 黑胶之夜 | dark | subtleGlass / 0.82 | framed | 0.30 / 20 / 0.22 | fluidBars | false |
| peach-mist / 蜜桃粉雾 | light | luminousGlass / 0.82 | softShadow | 0.30 / 24 / 0.12 | fluidBars | false |
| solar-studio / 日光唱片室 | light | paper / 0.82 | framed | 0.32 / 28 / 0.04 | vuMeter | **true** |
| polar-frost / 冰川透镜 | light | luminousGlass / 0.82 | crisp | 0.26 / 20 / 0.16 | lineSpectrum | false |
| forest-terminal / 森林终端 | dark | solid / 1 | framed | 0.18 / 32 / 0.05 | vuMeter | **true** |

### 12 主题逐色表（按顺序：background, elevated, surface, primaryText, secondaryText, accent, accentSecondary, success, warning, error, separator）

| 主题 | background | elevated | surface | primaryText | secondaryText | accent | accentSecondary | success | warning | error | separator |
|---|---|---|---|---|---|---|---|---|---|---|---|
| aurora-glass | #07131D | #102435 | #193247 | #F5FBFF | #A9C5D6 | #50D5C8 | #8D7CF4 | #5DD39E | #F6C85F | #FF6B7A | #315166 |
| midnight-oled | #000000 | #080808 | #121212 | #FFFFFF | #9A9A9A | #D8FF4F | #7A8BFF | #64D98B | #FFC857 | #FF5C73 | #242424 |
| analog-hifi | #17120F | #251B16 | #33251D | #F4E6CE | #BFAE94 | #C79655 | #8E5B3A | #80B192 | #D2A44B | #D86F5D | #574236 |
| minimal-paper | #F4F1EA | #FFFDF8 | #EAE5DB | #211F1B | #6F6A61 | #294B72 | #B96545 | #2D7A55 | #A16916 | #B23B42 | #D2CDC4 |
| neon-city | #100817 | #1C102B | #27183B | #FFF7FF | #C5AFCB | #FF4FA3 | #5D74FF | #56D89B | #FFAA4A | #FF5C6A | #482957 |
| zen-nature | #E9EEE8 | #F7F7F0 | #DDE6DE | #1D2B24 | #637168 | #3D7055 | #A7835D | #3C8160 | #B68436 | #B44F4F | #C7D1C9 |
| cloud-village-red | #FFFFFF | #FAFAFA | #F3F3F3 | #1A1A1A | #737373 | #EC4141 | #B83242 | #237A43 | #9B6500 | #C9303E | #D8D8D8 |
| vinyl-night | #121212 | #1E1E1E | #292929 | #FFFFFF | #9C9C9C | #EC4141 | #8E354A | #5DD39E | #F6C85F | #FF6B7A | #383838 |
| peach-mist | #FFF7F8 | #FFFFFF | #FBE9EC | #33242A | #826873 | #C92E63 | #A33E78 | #2F7454 | #986313 | #B93249 | #E4C8CF |
| solar-studio | #F9E4BF | #FFF5E4 | #EAC89C | #2F211B | #705446 | #B83C28 | #2F6685 | #2B704A | #855B0B | #A72C35 | #C9A878 |
| polar-frost | #EAF4FA | #F8FCFF | #D7EAF5 | #15252F | #526A78 | #176DA3 | #5661A8 | #24734E | #8A5C00 | #B22E47 | #B8D1DE |
| forest-terminal | #061711 | #0C241A | #123226 | #E8F5EC | #9BB9A6 | #4BE28A | #E2B84B | #5CDB95 | #F0C85A | #FF7581 | #28513B |

---

## 3. Spacing / Radius / Typography token（Kotlin 实现要点）

- **Spacing**：`4 / 8 / 12 / 20 / 28 / 40`（dp，与 iOS pt 1:1 映射）。✅ 与预期完全一致。
- **Radius**：`small=8 / medium=14 / large=22 / artwork=18`（dp）。✅ 与预期完全一致。
- **字体家族 / 字号**：**代码中没有字号 token 表与字族枚举**。Kotlin 端需自行定义一套默认 type scale。已知事实：
  - 作品占位字标（AuralisArtwork）用 `.system(size: max(18, size*0.19), weight:.bold, design:.rounded)` —— 即 **圆体（rounded）**、字重 bold。
  - 通用文本用系统字体；胶囊标签 `AuralisPill` 用 `.caption.weight(.medium)`。
  - 主题字重由 `ThemeTypography` 规定：display=**bold**、body=**regular**；`usesMonospacedMetrics` 仅 `vuMeter` 三主题（analog-hifi / solar-studio / forest-terminal）为 `true`。
  - **建议 Android 映射**：字族 `sans-serif`（display 用 `sans-serif-medium/bold`，mono 主题用 `monospace`）；字号表需另立常量（源码未给出，不可臆造，应沿用设计稿或后续补充审计）。

---

## 4. Motion token（Kotlin 实现要点）

### 4.1 主题级 MotionTokens（每主题，见上表）
- `standardDuration`：0.18–0.42 秒（不是 0.56）。
- `ambientDuration`：10–32 秒（环境动画循环周期）。
- `glowIntensity`：0–0.42。
- 应用位置（`AuralisRootView.swift:220`）：主题切换动画
  `.animation(reduceMotion ? nil : .easeInOut(duration: motion.standardDuration), value: selectedID)`
  → **曲线 `easeInOut`；reduce-motion 时为 `nil`（无动画），并非 0.18s linear**。

### 4.2 全局 BottomDockMotion（用户所说的 0.56/0.18，与主题无关）
```swift
enum BottomDockMotion {
    static let duration: TimeInterval = 0.56
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.18) : .smooth(duration: duration)
    }
}
```
- 用于 Dock / 输入框 / 页面避让空间的固定节奏；曲线为 `.smooth`（非 `easeInOut`）。
- **Kotlin 端须区分两套动画**：主题切换走 `easeInOut(主题.standardDuration)`，Dock 走 `smooth(0.56)` / reduce-motion `linear(0.18)`。

### 4.3 其它动画曲线（散落各处，供参考）
- 歌词高亮/卡片：`reduceMotion ? nil : .smooth(duration:0.22, extraBounce:0)`
- Mac 播放浮层：`reduceMotion ? nil : .spring(duration:0.30, bounce:0.08)` / `.easeInOut(0.25)`
- Mac 窗口：`reduceMotion ? .easeOut(0.14) : .spring(0.34,0.05)` 或 `.easeInOut(0.22)`

---

## 5. 主题如何被应用 / 持久化

- **存储**：`ThemeStore`（`BuiltInThemes.swift:127`）持 `selectedID:String`。
- **持久化键**：`UserDefaults` 键 `"auralis.selected-theme"`，仅存主题 **id 字符串**（如 `"aurora-glass"`）。
- **默认选中**：初始化时若 `UserDefaults` 无值 → 取 `themes[0].id` = **`aurora-glass`**。
- **读取/切换**：
  - `current`：按 `selectedID` 在 `BuiltInThemes.all` 中查找。
  - `select(id:)`：先经 `canonicalID(for:)` 做旧 ID 迁移，再写入 `UserDefaults`。
- **旧 ID 兼容映射**（`legacyIDMappings`，迁移到最接近的现视觉语言）：
  `album-adaptive→aurora-glass`、`cyber-pulse→neon-city`、`deep-sea-blue→aurora-glass`、`adaptive→aurora-glass`、`aurora→aurora-glass`、`cyber→neon-city`、`midnight→midnight-oled`、`neon→neon-city`、`paper→minimal-paper`、`zen→zen-nature`。
- **无障碍降级**：
  - `accessibilityReduceMotion`：主题切换动画置 `nil`；发光/循环动画停止（见 `NowPlayingArtworkGlow.animates = isPlaying && !reduceMotion`）。
  - `accessibilityReduceTransparency`：玻璃材质降级为不透明表面（`MorphingGlassCapsule` 等 `if reduceTransparency` 分支直接用 `.background`）。
  - 低电量 / 后台：停止环境（ambient）动画、降低频谱刷新（文档约束，Phase 4/8）。

### Android Compose 落地建议
- 用 `DataStore`/`SharedPreferences` 存 `selected-theme` 字符串；默认 `aurora-glass`。
- 颜色直接映射为 `Color(0xFFxxxxxx)`（注意大写 hex、加 `FF` alpha）。
- 材质映射：Compose `Surface` 的 `alpha` 用 `0.82`（玻璃）/ `1.0`（solid）；玻璃模糊可用 `blur`+半透明背景近似。
- reduce-motion 读取 Android `android.provider.Settings.Global` 动画缩放；reduce-transparency 取 `isUiEnhancementTypeEnabled`/对应用设置开关。
- **务必实现两套动画时长**：主题切换 `easeInOut(主题.standardDuration)`；Dock/浮层 `smooth(0.56)`，reduce 时 `linear(0.18)`。
