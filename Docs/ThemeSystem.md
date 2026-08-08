# Theme System

主题实现 `AuralisTheme`，只改变 ThemeColors、Typography、Materials、ArtworkStyle、Motion
和 VisualizerStyle。业务页面只读 Token，不为主题复制 View。

Phase 0 内置：Aurora Glass、Midnight OLED、Analog Hi-Fi、Cyber Pulse、Minimal Paper、
Album Adaptive、Neon City、Zen Nature。

高阶动效遵循三个降级信号：Reduce Motion 禁用转场；Reduce Transparency 使用不透明表面；
低电量和后台状态在 Phase 4/8 停止环境动画与降低频谱刷新。播放按钮保持唯一最强焦点。

后续的 Album Adaptive 会在后台降采样封面，生成受亮度/饱和度/对比度约束的调色板，并只把
结果写入主题 Token。主题 JSON 导入必须做版本、范围和对比度校验。
