# 11 · 2026-09-10 Android 最新 APK 验证记录

> 验证对象：已合并到 `main` 的 Android Dock、AI 输入和播放生命周期修复。
> 本记录只保存可复现的构建与运行结果，不保存服务器地址、账号密码、API key、token 或其他用户凭据。

## 1. 代码与产物

- 验证提交：`d120d57`（`fix(android): align mobile dock and playback lifecycle with iOS (#45)`）。
- 验证分支：`codex/android-latest-apk-test-20260910`，与 `origin/main` 同提交。
- 构建环境：仓库 Gradle Wrapper、JDK 17、Android API 34。
- 测试设备：已有 `Auralis_API_34` 模拟器；整个验证过程只运行这一台模拟器。
- 构建命令：

  ```bash
  cd android
  ./gradlew --no-daemon --max-workers=1 \
    -Dkotlin.compiler.execution.strategy=in-process \
    testDebugUnitTest :app-mobile:assembleDebug :app-tv:assembleDebug
  ```

- 构建结果：`BUILD SUCCESSFUL`；500 个任务中 3 个执行、497 个复用缓存。
- Mobile APK：`android/app-mobile/build/outputs/apk/debug/app-mobile-debug.apk`
  - SHA-256：`8de12670cef77af6a4c4f1871780b204e093dfdf8fe9d6d74745b45421261eba`
- TV APK：`android/app-tv/build/outputs/apk/debug/app-tv-debug.apk`
  - SHA-256：`266f6ca18ba10a82bf05dba102818d075dd73f64145feb3a0093c05fdc8296f1`

## 2. Mobile 验证

### 2.1 Dock 与 Assistant 输入

- Mobile APK 安装、启动和页面切换正常。
- Dock 可在完整态和紧凑态之间切换；Assistant 输入栏同步从完整布局切换为紧凑布局，再恢复完整布局。
- 点击 Assistant 输入框后，输入框获得焦点，系统输入法显示，Compose 输入连接正常。
- 发送无敏感内容的测试消息成功，已配置的 AI Provider 返回正常响应。
- 本次没有复现「Dock 外层手势拦截输入框点击」或「输入框无法获得焦点」。

### 2.2 底部安全区与播放

- Home 滚动到最底部后收起 Dock，统计区保持在 Dock 上方。
- 展开 Dock 后，统计区上移到 mini-player 上方，统计文字与播放控件没有重叠。
- Home 卡片播放成功，应用保持前台。
- MediaSession 状态为 `PLAYING`，没有发现 `ForegroundServiceDidNotStartInTimeException`、`RemoteServiceException` 或应用进程崩溃。

### 2.3 Library 与详情页

- Library 页面可正常打开并显示服务器同步的本地目录。
- 专辑详情页可以打开，歌曲列表、播放全部、下载和底部播放控件正常显示。

## 3. TV 验证

TV 端使用与 Mobile 相同的音乐服务器配置，不创建独立的音乐服务器。

- TV APK 安装、启动和返回操作正常。
- TV 端添加同一服务器配置后，首页出现服务器音乐库数据、统计信息和专辑封面。
- Library 页面可以加载 Albums、Songs、Artists、Playlists、Favorites、Genres 和 Categories。
- 专辑详情页可以打开并显示歌曲列表、播放全部和下载操作。
- TV 底部播放控件验证通过：
  - 播放状态从 `PAUSED` 切换为 `PLAYING`；
  - 播放进度持续增加；
  - 暂停与恢复均正常。
- TV 方向键焦点移动正常，返回操作正常。
- 本次没有发现 TV 的 `FATAL EXCEPTION`、`RemoteServiceException`、播放服务异常或应用进程崩溃。

## 4. 结论与边界

**结论：通过。** 在最新 `main` 的 Mobile 和 TV APK 上，Dock、Assistant 输入、底部安全区、播放服务，以及 TV 复用同一音乐服务器后的同步与播放流程均通过验证。

本次验证为 Android API 34 Debug APK 的模拟器验收，不等同于签名 Release 包或实体电视硬件验收。Gradle 仍提示既有的 `kotlin.incremental.useClasspathSnapshot=false` 弃用警告，本次未修改该无关配置。

测试结束后已关闭 `Auralis_API_34`；`adb devices` 为空，qemu/netsimd 进程均已退出，仓库没有遗留本次测试生成的未跟踪文件。
