# Android / iOS 播放页同步审核

对照基线：iOS PR [#70](https://github.com/zyk1172/Auralis/pull/70)，合并提交 `f45a35d`。
Android 手机端使用原生 Jetpack Compose；仓库没有独立 Android Web UI。
本次审核覆盖该 PR 对播放页的更新，以及共用的导航、控制区和沉浸歌词行为。

| 项目 | Android 修改前 | 同步后的行为 |
| --- | --- | --- |
| 逐字强调 | 最大 1.12 倍；唱过的字回缩 | 当前句唱过的字累计保持 1.1 倍；下一句开始后上一句恢复普通样式 |
| 歌词排版 | 活跃行逐字符 FlowRow，其他行整行 Text；换行、字重可能变化 | 所有状态共用原生整行 Text 的换行、粗体和可访问文本；强调只改变绘制 |
| 手动浏览 | 每次当前行变化都滚回当前行 | 触摸、拖动和惯性期间暂停跟随；结束后等待 5 秒，再跟随最新行 |
| 歌词动画 | 当前行时钟在滚动或页面离开时仍可能运行 | 仅可见当前行播放时运行约 30fps 绘制时钟；用户滚动、暂停、离开页面或减少动态效果时停止 |
| 倍速播放 | 字符插值默认使用 1 倍速度 | 跟随实际播放速度；预测上限与 iOS 一样为 750ms |
| 沉浸歌词 | 松手即重排；普通点击会显示控制区 | 等惯性结束再应用滑动的显示/隐藏选择；普通点击保持沉浸状态 |
| 横屏封面 | 手机/平板上限 360/520dp；旧宽高比例 | 上限 420/600dp；扣除左右边距和列间距后分配 48%/50%；高度保留 48/64dp |
| 横屏边距 | 左右 16dp；列间距固定 24dp | 手机左右 20dp / 列间距 24dp；平板左右 32dp / 列间距 36dp；系统安全区另行保留 |
| 紧凑横屏关闭入口 | Material 按钮占用较高布局 | 使用轻量拖拽柄，保留原生按钮语义与点击/下拉关闭，避免挤压封面 |

歌词源仍只有逐行时间戳，逐字进度是在相邻行之间均匀插值；无下一行时间戳时使用 1.06 倍整行强调。
横屏尺寸以扣除 Android 系统栏后的可用窗口计算，因此同一物理分辨率下不必等于 iOS 的点数。

共用界面保持：播放时封面 1 倍、暂停 0.82 倍；横屏左封面右歌词/队列；歌词与队列底部按钮再次点击返回封面；沉浸时保留歌曲信息；无歌词、重试、标题跑马灯和播放控制。
平台差异保留：iOS AirPlay 入口对应 Android 原生音频输出选择；Apple Music Haptics 仅由支持它的 Apple 平台提供。

## 验证

`NowPlayingUiPolicyTest` 覆盖累计缩放、插值边界、倍速、窗口尺寸及滚动跟随状态。
`NowPlayingLayoutTest` 检查横屏正方形封面、边距、不重叠和原有导航行为。
共享的 `LyricsUiTestCases` 同时用于 Robolectric 与 Android 原生仪器测试：检查中英文、emoji 和组合字符的整行语义/排版稳定，以及真实触摸浏览后 5 秒恢复到最新歌词。
`LyricsNativeTest` 另在原生设备检查横屏几何并保存截图。

复现命令（在 `android` 目录）：

```sh
./gradlew testDebugUnitTest :app-mobile:assembleDebug :app-tv:assembleDebug :app-mobile:assemblePerf :app-tv:assemblePerf
./gradlew :feature:player:connectedDebugAndroidTest
```

第二条命令需要启动 Android Emulator 或连接设备；本次验证使用软件模拟器，验证渲染与行为，不据此作真机性能结论。
