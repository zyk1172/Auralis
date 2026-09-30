# 12 · Android / Android TV 构建与 UI 全面审查：流畅性与稳定性

> 审查日期：2026-09-30
> 审查范围：`android/`（`app-mobile`、`app-tv`、`core/*`、`feature/*`、Gradle/CI 配置、清单与资源）
> 审查目标：**卡顿 / 掉帧**（性能、渲染、内存、线程）与 **闪退 / 崩溃**（稳定性、并发、异常路径）
> 审查方式：只读逐行源码审查 + 构建产物实证（离线 Kotlin 编译、APK 解包与清单 dump、Android Lint）
> 本文件为新增审查记录，未修改任何既有源码或配置。

---

## 0. 结论先行

1. **测试者拿到的是 debuggable 的 debug APK，且 release 未开启 R8。** 两者叠加意味着：所有真机流畅性反馈都建立在「无 AOT profile、无 R8 优化、带调试开销」的最差形态上；同时交付链路本身就是性能问题的一部分。见 **B-01 / B-02**。
2. **最大的一类卡顿根因不是 Compose，而是仓库层把 DB 查询、JSON 解码、全库排序/分组放在了主线程。** `RoomCatalogRepository` / `UnifiedCatalogRepository` / `CachedCatalogRepository` 三个类**没有任何 `withContext`**（全仓 grep 实证），而 Compose 用 `collectAsState` 在 Main 上收集它们的 Flow。搜索、首页刷新、收藏列表任何一次数据变化，都会在主线程做「全表读 + 逐条 `decode<Track>` + `lowercase` 比较 + `groupBy` + `sortedBy`」。见 **P-01 / P-02 / P-03**。
3. **TV Now Playing 是全项目渲染开销最高的页面，并且每 250ms 整体重组一次。** `position` 4Hz 更新 → 整屏重组 → 连带一个 96dp 全屏 `Modifier.blur` + 4 层全屏渐变 + 10 个 `SubcomposeAsyncImage`。且 `Modifier.blur` 在 Android 12 以下是**空操作**、12 以上是**逐帧 RenderEffect**——低端电视盒子（多数仍是 Android 9/10/11）会看到「设计意图未生效」，Android 12+ 盒子会看到「模糊生效但严重掉帧」。见 **P-05 / V-01**。
4. **播放中的移动端 Now Playing 每帧重组。** `NowPlayingArtworkGlow` 用 `Animatable` 做 `while(true)` 呼吸动画，并在 **composition 里读动画值**（而非在 `graphicsLayer{}` lambda 里读），导致 1.8s 一个来回的持续重组，每帧重建 `SubcomposeAsyncImage` + `Offscreen` 合成 + blur。见 **P-06**。
5. **每个列表行都单独订阅「全部收藏」。** `LibraryTrackRow` 每行调用一次 `rememberFavoriteIds`，每次发射都做一次全量 `map/去重/toSet`。可见 15 行 = 15 份全量收藏集合 + 15 次 O(N) 去重。见 **P-04**。
6. **`Dispatchers.Default` 上跑阻塞式下载，且 `readTimeout = 0`。** 4 核手机上 Default 池只有 3 个线程，3 个并发下载可将其占满；服务器半开连接时该线程永久阻塞，从而饿死同样跑在 Default 上的 `appScope`（承载 bootstrap、hydrate、本地扫描、缓存解码）。见 **T-01**。
7. **前台服务存在真实竞态窗口**：`startForegroundService` 后若 `activeCount` 恰好归零，`DownloadService` 会直接 `stopSelf()` 而**从未调用 `startForeground`**，在部分 OEM 上表现为 `ForegroundServiceDidNotStartInTimeException` 进程崩溃。见 **S-01**。

**严重度分布**：P0 级 9 项、P1 级 17 项、P2 级 14 项。修复优先级路线图见 §9。

---

## 1. 证据与验证边界

### 1.1 已执行的实证（可复核）

| 验证项 | 命令 / 方法 | 结果 |
|---|---|---|
| Kotlin 编译 | `./gradlew --offline :app-mobile:compileDebugKotlin :app-tv:compileDebugKotlin` | **成功**（46s，无错误） |
| Android Lint（TV） | `./gradlew :app-tv:lintDebug` | 完成：**7 errors + 12 warnings** |
| Android Lint（Mobile） | `./gradlew --rerun-tasks :app-mobile:lintDebug` | 完成：**0 errors + 40 warnings + 1 hint** |
| debug APK 清单 | `aapt2 dump xmltree --file AndroidManifest.xml app-mobile-debug.apk` | `android:debuggable=true`、`targetSdk=36`、`extractNativeLibs=false` |
| release APK 清单 | 同上（release-unsigned.apk） | 无 `debuggable` 属性 |
| debug APK 结构 | `unzip -l` | 25 MB，**18 个 dex**，**无** `assets/dexopt/baseline.prof` |
| release APK 结构 | `unzip -l` | 17 MB，4 个 dex，**有** `assets/dexopt/baseline.prof` |
| R8 是否运行 | `find -name mapping.txt`、`strings classes*.dex` | **无 mapping.txt、无 minified_classes/shrunk_classes 中间产物、dex 内保留完整类名** → R8 未运行 |
| 主线程调度器 | `grep -rn "Dispatchers\.\(IO\|Default\)"` | `core/data/repository/*` **零命中** |

### 1.2 未能完成 / 未覆盖的验证

- **无真机/模拟器帧数据**：未使用 `Perfetto`/`gfxinfo`/`JankStats`，所有流畅性结论来自静态代码路径推导与产物证据，**未经实测确认**。建议按 §9 第 0 步先补齐度量。
- **未开启 Compose 编译器 metrics/reports**（`composeCompiler { metricsDestination / reportsDestination }` 未配置），因此**无法给出各 Composable 的 skippable 统计**；§3.2 中关于「不可跳过」的结论基于参数稳定性推断，而非编译器报告。
- **未运行 `assembleRelease` 复现 R8 关闭**，结论来自已有 release 产物的解包证据。
- **未接入设备/网络**：`ProductionServerConnector.syncOnEndpoint` 的串行行为为静态阅读结论，未做真实同步计时。
- 审查期间执行构建产生的副作用：新增未跟踪文件 `core/data/schemas/com.auralis.core.data.db.AuralisDatabase/2.json`（Room schema 导出，见 **B-07**），未删除、未提交。

---

## 2. 构建配置与产物

### B-01 【P0·构建/性能基线】交付给测试者的是 debuggable 的 debug APK

- **表现/复现场景**：任何一次 tag 发布或 CI 运行，测试者下载到的 `Auralis-<tag>-Android-Mobile-debug.apk` / `-TV-debug.apk` 都是 debug 产物。所有「首屏慢、滚动掉帧、切页卡顿」的反馈都可能是 debug 开销造成的假象，也可能掩盖真实的 release 问题。
- **根本原因**：
  - `.github/workflows/release.yml:111-120` 只跑 `:app-mobile:assembleDebug` / `:app-tv:assembleDebug`，`:138-139` 把 `outputs/apk/debug/*.apk` 直接复制为发布资产。
  - `.github/workflows/android.yml:83-97` 同理只构建 debug。
  - 实测 debug APK 清单含 `android:debuggable=true`。
  - debuggable 进程的实际影响：ART 不启用编译期优化（大量方法保持解释/JIT）、Compose 调试期额外校验、`debugImplementation(ui-tooling)` 被打进每个模块的 debug 变体（18 个 dex / 25 MB）、无 baseline profile。
- **影响范围**：移动端 + TV，**影响所有性能结论的可信度**。
- **修改方向**：
  1. 在 `app-mobile` / `app-tv` 显式声明 release 构建类型（见 B-02），CI 至少同时产出 release 及 `-debug` 两个变体；
  2. 若暂不出签名 release，则至少在 CI 里以 `minifyEnabled=true`、`debuggable=false` 的 internal 变体做性能验证；
  3. 在发布说明中明确标注 APK 变体，避免把 debug 结论当作产品结论。

### B-02 【P0·构建】release 未开启 R8（minify/优化/混淆），也没有任何混淆规则文件

- **表现/复现场景**：release APK 17 MB、dex 合计约 54 MB 未压缩，类名完整保留；一旦有人在某天把 `minifyEnabled` 打开而没有规则文件，会因为反射/序列化路径被裁剪而**大面积运行时崩溃**。
- **根本原因**：
  - `app-mobile/build.gradle.kts:9-42` 与 `app-tv/build.gradle.kts:9-47` **都没有 `buildTypes {}` 块**，AGP release 默认 `minifyEnabled=false`；
  - 仓库内不存在 `proguard-rules.pro`；
  - 实证：无 `build/outputs/mapping/`、无 `intermediates/minified_classes|shrunk_classes`、dex 内可见 `Lcom/auralis/core/ai/AiMessage$Role;` 等完整 FQN。
- **影响范围**：移动端 + TV（包体、冷启动方法数、内存页驻留）。
- **修改方向**：
  1. 加 `buildTypes { release { isMinifyEnabled = true; isShrinkResources = true; proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro") } }`；
  2. 规则文件必须包含：`kotlinx.serialization`（`@Serializable` 类的 `Companion.serializer()`、`$$serializer`）、Room 生成实现、`androidx.media3.session` 的可序列化 `Bundle` extras、Compose 反射相关 keep；
  3. 打开 R8 后必须跑一遍**真机全链路回归**（连接服务器 / 播放 / 下载 / AI 工具调用 / TV 焦点），并把 mapping 归档用于符号化崩溃栈。

### B-03 【P0·构建】没有应用自身的 Baseline Profile

- **表现/复现场景**：冷启动进入首页后首次滚动、首次打开 Now Playing 会明显掉帧；重启应用后改善（系统后台 dexopt 完成后）。TV 上更明显（CPU 弱、无 AOT 机会）。
- **根本原因**：
  - release APK 中确实存在 `assets/dexopt/baseline.prof`，但内容**完全来自 androidx 依赖自带的 profile**（`META-INF/androidx.profileinstaller_profileinstaller.version`）；
  - 项目没有任何 `baselineprofile` 模块、没有 `src/main/baseline-prof.txt`、没有 `mergeStartupProfile` 产物；
  - debug APK **完全没有** `baseline.prof`（实测 unzip 结果）——即当前交付给测试者的产物连依赖 profile 都没有。
- **影响范围**：移动端 + TV。
- **修改方向**：新建 `:baselineprofile` 模块（Macrobenchmark + `BaselineProfileRule`），覆盖冷启动、首页首屏、Library 滚动、Now Playing 进入、TV 遥控器导航五条路径；产物并入 release 变体。

### B-04 【P1·构建】`targetSdk`/`compileSdk` 三套并存且 TV 落后两代

- **表现/复现场景**：Android TV 14/15 上部分新行为不生效（前台服务类型强制、通知权限行为、edge-to-edge 强制等）；Lint 已直接报错提示。
- **根本原因（Lint 实证）**：
  - `app-tv/build.gradle.kts:11` `compileSdk = 34`、`:28` `targetSdk = 34`；
  - `app-mobile` 为 36/36；
  - 全部 `core/*`、`feature/*` 模块 `compileSdk = 34`；
  - Lint: `app-tv/build.gradle.kts:11 Warning: A newer version of compileSdkVersion than 34 is available: 36 [GradleDependency]`、`:28 Warning: Not targeting the latest versions of Android [OldTargetApi]`。
- **影响范围**：TV（兼容性与平台行为一致性）。
- **修改方向**：把 libs/约定统一到 `compileSdk=36`（或在 `build.gradle.kts` 用 convention 统一），`targetSdk` 按平台策略单独决策；升级后必须回归 TV 的前台服务与通知路径。

### B-05 【P1·构建】未配置 Compose 编译器指标与稳定性策略，无量化依据

- **表现/复现场景**：无法回答「哪些 Composable 每次重组」这个本审查的核心问题，只能靠读代码推断。
- **根本原因**：两个 app 模块均无 `composeCompiler { metricsDestination / reportsDestination }`，也没有 `composeCompiler { stabilityConfigurationFile }`；同时 `gradle.properties` 中没有相关开关。
- **影响范围**：工程效能（长期）。
- **修改方向**：接入 `-P plugin:androidx.compose.compiler.plugins.kotlin:reportsDestination=<dir>` 与 `metricsDestination`，在 CI 归档 `*-composables.txt` / `*-classes.txt`；用报告驱动 §3.2 的修复，而不是靠猜。

### B-06 【P2·构建】`app-mobile` 无启动图标（App icon）

- **表现/复现场景**：桌面/启动器显示系统自带的 `ic_media_play`；无自适应图标；上架或正式分发不可用。
- **根本原因**：`app-mobile/src/main/AndroidManifest.xml:23` `android:icon="@android:drawable/ic_media_play"`；`app-mobile/src/main/res/` 下**没有 `mipmap-*` / `drawable/ic_launcher_*`**，也没有 `android:roundIcon`。TV 侧有 `@drawable/ic_tv_logo` 与 `tv_banner`，相对完整。
- **影响范围**：移动端（品牌、上架合规）。
- **修改方向**：补 `mipmap-anydpi-v26/ic_launcher.xml` + 各密度 PNG/WebP，`android:roundIcon`；`android:icon` 不再引用系统 drawable。

### B-07 【P2·构建】Room schema 导出不完整（v2 未入库）

- **表现/复现场景**：本次执行构建后工作树新增未跟踪文件 `core/data/schemas/com.auralis.core.data.db.AuralisDatabase/2.json`（40 KB）；仓库中只跟踪了 `1.json`。
- **根本原因**：数据库版本已升到 2，但 v2 的导出 schema 未提交；`migration` 正确性无法通过 Room 的 schema 校验，未来写 `Migration` 时缺少基线。
- **影响范围**：移动端 + TV（数据迁移安全）。
- **修改方向**：确认 `AuralisDatabase` 版本与 migration 后，提交 `2.json`；在 CI 增加「构建后 `git diff --exit-code -- 'core/data/schemas'`」防止再次漂移。

### B-08 【P2·构建】构建缓存与资源优化开关未打开

- **表现/复现场景**：增量/冷构建偏慢；资源 ID 非 final 导致部分内联优化失效。
- **根本原因**：`android/gradle.properties`：`android.nonFinalResIds=false` 显式关闭了 non-final res IDs 优化；未启用 Gradle configuration cache（`org.gradle.configuration-cache` 缺失）；未开启 `android.enableResourceOptimizations`（默认已开，但与 nonFinalResIds 组合语义需确认）。
- **影响范围**：CI/开发者构建时间（不直接影响运行时）。
- **修改方向**：评估开启 configuration cache（AGP 8.12 支持）；重新评估 `nonFinalResIds`；为 library 模块移除 `debugImplementation(libs.androidx.compose.ui.tooling)`（只有 app 模块需要）。

---

## 3. 流畅性：卡顿与掉帧

### 3.1 主线程重活（最高优先级）

#### P-01 【P0·性能】仓库层零 `withContext`：DB 读取、JSON 解码、全库排序全部跑在收集者线程（= Compose Main）

- **表现/复现场景**：
  - 打开「资料库」任一 TAB（歌曲/专辑/艺术家/流派）时白屏后卡顿一下；
  - 搜索页每敲一个字（debounce 后）掉帧；
  - 首页任意数据变化（收藏一首歌、下载完成、播放一首）后首页「顿一下」；
  - 本地曲库越大越明显（1 万首以上可到秒级）。
- **根本原因（逐条实证）**：
  1. `UnifiedCatalogRepository.kt:58-63`、`:42-48`、`:50-56`、`:65-71`、`:200-207` 的 `combine{...}` / `map{...}` transform **在收集者上下文执行**，而收集者是最末端的 `collectAsState`（`AndroidUiDispatcher.Main`）。以 `observeTracks` 为例：每次发射都执行 `remote + localTracks`（新建 N+M 的 `ArrayList`）+ `TrackQuality.deduplicatedPreferringQuality`（对每个曲目生成归一化 key 字符串）。
  2. `RoomCatalogRepository.kt:190-205`（`search`）内 `observeAll(...).first()` 之后立刻做 `.filter{ contains }` + `.map { decode<Album/Artist/Playlist>(payload) }`；`:207-212`（`stats`）为取计数把 **artists/albums 全表读进内存再 `.size`**；`:386-393`（`genreTracks`）解码**全部曲目**。
  3. `RoomCatalogRepository.kt:378-383` `observeFavoriteTracks` 用 `flow { emit(resolveTrackGids(...)) }`，**没有 `flowOn`**；`resolveTrackGids`（`:733-737`）做 `getMany` + `associateBy` + 逐条 `decode<Track>`。
  4. 全仓 grep 实证：`core/data/repository/` 下**没有任何** `Dispatchers.IO` / `Dispatchers.Default`。
- **为什么会造成掉帧**：`decode<Track>` 是 kotlinx.serialization JSON 反序列化；万级曲目时单次调用包含数万次字符串分配 + HashMap 构建，落在主线程即产生 16ms 以上的帧预算超支（成百上千毫秒）。
- **影响范围**：移动端 + TV（完全共用 `AuralisGraph`）。
- **修改方向**：
  1. 在 `RoomCatalogRepository` 的每个 `suspend` 读取方法内包 `withContext(Dispatchers.Default)`（或 IO），并在 Flow 上加 `.flowOn(Dispatchers.Default)`；
  2. `stats` 改走 SQL `COUNT(*)`（DAO 已存在 `count` 方法，见 `Daos.kt` 中 `trackDao.count` / `playlistDao.count`），不要 `observeAll().first().size`；
  3. `search` 的 albums/artists/playlists 改为 `LIKE`/FTS 查询 + `LIMIT`，不要在内存过滤全表；
  4. `UnifiedCatalogRepository` 的合并/去重移到 `flowOn(Dispatchers.Default)`，并缓存归一化 key（`recordingKey` 结果随 Track 一起 memo）。

#### P-02 【P0·性能】本地曲库的「全库扫描 + SharedPreferences 逐项读」在 Main 上执行

- **表现/复现场景**：设置本地音乐目录后，首页/资料库首次进入卡顿；「不喜欢」状态变化时整页卡顿。
- **根本原因**：
  - `AndroidLocalMusicLibrary.kt:124-125` `dislikedIds()` 对**每个本地曲目**调用 `isDisliked` → 一次 `statePrefs.getBoolean(stateKey(...))`，而 `stateKey`（`:172`）每次都新建字符串；
  - 该方法由 `UnifiedCatalogRepository.kt:200-207` 的 `combine(...){ local.dislikedIds().toList() }` 触发，最终在 Main 收集；
  - `AndroidLocalMusicLibrary.kt:96-98` / `:108-110` 每次收藏/评分都 `_tracks.value.map { ... }` 复制**整库 List**；
  - `UnifiedCatalogRepository.kt:224` `longUnplayed` 对整库 `sortedBy`、`:230-233` `recentlyPlayed` 整库 `mapNotNull + sortedByDescending`、`:239` `randomTracks` 整库 `shuffled()`、`:286-297` `localSearch` 全库 3 次 `lowercase()` + `contains` 并再跑 `localAlbums`/`localArtists` 两次 `groupBy`。这些都被 `HomeState`（运行在 `rememberCoroutineScope` = Main）与 `SearchScreen`（`LaunchedEffect` = Main）直接调用。
- **影响范围**：移动端 + TV（本地曲库功能为共用运行时）。
- **修改方向**：本地库维护 `dislikedIds` 的内存索引（写入时同步更新，读时 O(1)）；`setFavorite/setRating` 改为局部更新（`mutableStateListOf` 或按 id 索引的持久结构）；所有全库排序/分组/洗牌移入 `Dispatchers.Default` 并在 use site 用 `remember`/`derivedStateOf` 去重计算。

#### P-03 【P0·性能】首页每次信号变化都重查 9 类模块，含整库重洗牌与全库排序

- **表现/复现场景**：首页「随机歌曲」货架在播放/收藏/下载任一动作后**内容整批变化**（卡片 key 变化 → 封面重新请求）；首页刷新期间出现 4–5 次可见重组与中间态闪动。
- **根本原因**：
  - `HomeState.kt:76-84`：`combine(prefs.homeLayoutFlow, repo.homeChangeSignals(serverId)).collect { refresh(serverId) }`；
  - `RoomCatalogRepository.kt:462-471` `homeChangeSignals` 由 5 路 COUNT Flow 合并，任一变化即发射；`UnifiedCatalogRepository.kt:272-276` 还并入 `local.revision`；
  - `HomeState.kt:156-175` `buildContentModules` 对**所有开启模块**重新查询，其中 `RandomSongs` 走 `randomTracks`（本地路径 = 整库 `shuffled()`）、`RecentlyPlayed`/`LongUnplayed` 走全库排序；
  - `HomeState.kt:110-133` `refresh` 内连续 4–5 次状态写入（`stats`、`quickModules`、`contentModules`、`refreshing`、`loaded`），其中若干之间有挂起点，导致多次可见重组。
- **影响范围**：移动端 + TV。
- **修改方向**：
  1. `refresh` 先在局部变量组装完再一次性提交（单次状态写入）；
  2. `homeChangeSignals` 拆细：曲目数变化才重查列表类模块，收藏数变化只更新收藏相关模块与徽标；
  3. `RandomSongs` 在非「换一批」动作下保持上次采样结果（不要因无关信号重洗）；
  4. 整库排序放 `Dispatchers.Default`，并对 `lastPlayedMillis` 预先建 Map 而不是每元素查一次 SP。

### 3.2 Compose 重组与稳定性

#### P-04 【P0·性能】每个列表行各订阅一次「全部收藏」，并做全量去重/物化

- **表现/复现场景**：进入歌曲列表（可见 ~10–15 行）后滚动明显掉帧；点一次收藏，整个列表重排一次重组。
- **根本原因**：
  - `LibraryTracks.kt:104` `LibraryTrackRow` **每行**调用 `rememberFavoriteIds(graph, serverId)`；
  - 该函数 `LibraryTracks.kt:80-84`：`remember(serverId){ observeFavoriteTracks(serverId) }` + `collectAsState` → **每行一条订阅**；且 `remember(tracks) { mutableStateOf(tracks?.map{...}?.toSet()) }` 在数据变化时返回**新的 State 实例**给所有调用方；
  - 上游 `UnifiedCatalogRepository.kt:144-150` 每次发射都执行 `deduplicatedPreferringQuality(remote + localItems)`（O(N) 去重 + HashMap 建表），本地路径还要 `local.tracks.map{ filter{ isFavorite } }`（对整库 filter）；
  - 叠加 `LibraryTracks.kt:103` 每行第二条 Flow `observe(track.globalId)`（`downloadDao.observe`）。
  - 即：**100 行可见 ≈ 200 个活跃 Room 观察者 + 100 份全量收藏集合**。
- **影响范围**：移动端 + TV（`LibraryTrackRow` 被 `LibraryScreen`、`BrowseDetailScreen` 共用，详情页上限 `DETAIL_TRACK_CAP = 1000`）。
- **修改方向**：把收藏集合提升为**页面级单一订阅**（在 `LibraryScreen`/`BrowseDetailScreen` 顶层 `remember` 一次，用 `CompositionLocal` 或参数下传）；行内只做 `Set.contains`；用 `derivedStateOf` 避免新建 State 实例。

#### P-05 【P0·性能/TV】TV Now Playing 每 250ms 整屏重组，并携带全屏模糊与多层渐变

- **表现/复现场景**：TV 进入「正在播放」后整体不顺滑；拖动进度、切歌、开歌词面板时明显掉帧；低端盒子上画面撕裂感明显。
- **根本原因**：
  - `TvNowPlayingScreen.kt:138` `val positionMs by controller.position.collectAsState()`，`position` 由 `AuralisPlaybackEngine.kt:143-149` 每 250ms 更新 → **读取点在整个 `TvNowPlayingScreen` 函数体内**，故 4 次/秒整屏重组；
  - 该重组会重新执行 `BoxWithConstraints` 内容（`:184-322`），并向 `TvPlaybackColumn`（`:214-249`）与 `TvPrimaryControlLayer`（`:294-321`）传入**每次新建的 lambda**（如 `onTrackChangingAction = { index -> pendingPrimaryRestore = index }`、`ofToggleInfo = { ... }`）与新建的 `Modifier` 链，导致这些子树无法跳过；
  - `TvPlayerAmbience`（`:209-212` → `:326-392`）在每次重组时重建：1 个全屏 `AuralisArtwork(targetSizeDp = 1024)` + `graphicsLayer{ scale 1.15 }` + **`.blur(96.dp)`**（`:360`）+ 3 层全屏渐变 Box（`:364-390`）。
- **`Modifier.blur` 的双重问题**：Compose 的 `Modifier.blur` **仅 Android 12+ 生效**，API<31 为静默空操作；12+ 上它转为逐帧 `RenderEffect`，对 1080p/4K 全屏图层做 96dp 半径模糊对 TV SoC 的 GPU 是重负载。
- **影响范围**：TV 为主（移动端另见 P-06）。
- **修改方向**：
  1. 把 `position` 的读取下移到最小范围：只让 `TvSeekBar` 订阅 `position`（例如把 `positionMs` 的 `collectAsState` 放进 `TvSeekBar` 内部），或改用 `Modifier.drawBehind{}/graphicsLayer{}` lambda 读取；
  2. 用 `remember` + `derivedStateOf` 把 `TvPlaybackColumn`/`TvPrimaryControlLayer` 的稳定参数固定下来，回调用 `rememberUpdatedState` 或 `remember { { ... } }`；
  3. 环境模糊**不要逐帧重建**：把模糊封面在 `track` 变化时预渲染成一张低分辨率 Bitmap（`RenderScript`/`BitmapShader` 或一次性 `RenderEffect`），或直接用预先模糊好的极小图（如 64px 放大）替代运行时 blur；
  4. 若必须保留 `Modifier.blur`，在 API<31 上走「无模糊但仍叠加半透明渐变」的降级分支，避免视觉与预期不一致。

#### P-06 【P0·性能/移动端】Now Playing 的呼吸动画在 composition 里读值 → 播放中每帧重组

- **表现/复现场景**：移动端打开 Now Playing 播放时，整屏持续掉帧、发热、耗电；暂停后立刻变顺（因为动画停）。
- **根本原因**：
  - `NowPlayingArtworkGlow.kt:66-76`：`Animatable` + `while (true) { animateTo(1f); animateTo(0f) }`（各 1.8s），`isPlaying && !reduceMotion` 时持续运行；
  - `:78-79` 在 **composable 函数体**里由 `pulse.value` 计算 `glowScale` / `glowAlpha` → 这是 **composition 阶段读取**，因此每个动画帧都使 `NowPlayingArtworkGlow` 重组；
  - 重组时其子节点 `AuralisArtwork`（`:87-120`）收到**新构建的 `Modifier` 链**（`requiredSize + graphicsLayer + blur + drawWithCache`），无法跳过；`AuralisArtwork` 内部是 `SubcomposeAsyncImage`（子组合，见 P-07），并且 `graphicsLayer{ compositingStrategy = Offscreen }` + `blur(blurRadius)` 意味着每帧一次离屏图层合成；
  - 同一屏还有 `NowPlayingScreen.kt:140-142` 的 `playback` + `queue` + `position` 三个 `collectAsState`（position 4Hz 触发整屏重组），与上面的 60fps 叠加。
- **影响范围**：移动端（TV 用另一套 `TvPlayerAmbience`）。
- **修改方向**：
  1. 把动画值改成在 `graphicsLayer { scaleX = 0.99f + 0.05f * pulse.value; alpha = ... }` **lambda 内**读取，这样只重跑 layer block，不触发重组；
  2. 模糊封面同样应从「每帧带 blur 的图层」改为「预模糊位图 + 静态图层」；
  3. 呼吸动画应当在与「非播放态」相同的静态外观上做（暂停时 `snapTo(0)` 已正确），并确保不可见/后台时不跑帧。

#### P-07 【P0·性能】封面统一使用 `SubcomposeAsyncImage`，单屏可达 40–90 个实例

- **表现/复现场景**：首页/专辑网格/队列快速滑动时掉帧与明显的内存抖动；返回列表后再次进入仍有解码抖动（同图不同尺寸）。
- **根本原因**：
  - `core/image/src/main/java/com/auralis/core/image/ArtworkView.kt:109` 使用 `SubcomposeAsyncImage`。Coil 官方说明 `SubcomposeAsyncImage` 因使用子组合而**显著慢于 `AsyncImage`**，应仅在需要按状态切换布局时使用；
  - 每个 `AuralisArtwork` 还有 `produceState`（`:66-80`）每次执行一次 `withContext(Dispatchers.IO){ provider.url(...) }`（跨线程往返）；
  - 缓存键包含 `requestSize`（`:82-86`），而各页请求的 tier 不同：`LibraryScreen.kt:728` 280→512、`LibraryScreen.kt:871` 48→64、`BrowseDetailScreen.kt:415` 176→256、`:954/:1026` 88→128、`SearchRows.kt:78` 96→128、`AppleParityHomeScreen.kt:326` 140→256 → **同一 `artworkKey` 在内存中存在多份不同尺寸 Bitmap**；
  - TV 专辑网格用 `GridCells.Adaptive(142.dp)`（`LibraryScreen.kt:676`）但请求固定 280→512：1080p TV 上约 13 列时过度解码，4K 下反而偏小。
- **影响范围**：移动端 + TV。
- **修改方向**：
  1. 用 `AsyncImage` + `placeholder`/`error` painter（或 `onState` 回调）替代 `SubcomposeAsyncImage`；
  2. 统一封面 tier 策略：同一 `artworkKey` 只请求 1–2 个 tier（列表 128、网格 512），并把 `targetSizeDp` 与实际布局尺寸绑定（用 `Modifier.onSizeChanged` 或按列宽计算）；
  3. 显式配置 Coil `ImageLoader`（内存缓存上限、`BitmapFactory` 采样、`crossfade` 关闭），而不是依赖默认值；
  4. 检查 `clearArtworkCaches`（`ArtworkView.kt:160-165`，调用点 `SettingsScreens.kt:592-595`）在 Coil 持有 `DiskLruCache` 时直接删除 `cacheDir/image_cache` 下的文件，可能造成 journal 与实际文件不一致（建议改用 `ImageLoader.diskCache?.clear()`）。

#### P-08 【P0·性能】主题切换期间整棵树逐帧重组（`staticCompositionLocalOf` + 11 个颜色动画）

- **表现/复现场景**：在设置里切换主题时，界面在 200–420ms 内明显卡顿；低端设备上切换瞬间可感知掉帧。
- **根本原因**：
  - `AuralisTokens.kt:130` `val LocalAuralisTheme = staticCompositionLocalOf { BuiltInThemes.default }`；
  - `AuralisTheme.kt:50-76` 用 **11 个 `animateColorAsState`** 组装 `resolvedTheme = theme.copy(colors = AuralisColors(...))`，动画时长来自 `motion.standardDurationSeconds`（`BuiltInThemes.kt` 各主题为 **0.20–0.42 秒**）；
  - 动画期间 provider 的 value **每帧都是新对象**；`staticCompositionLocalOf` 的语义是「值变即失效整棵子树」，因此主题过渡全过程中，所有读 `LocalAuralisTheme.current` 的 Composable（几乎是全部）都逐帧重组，且因 `colors` 逐帧变化，子级也无法跳过；
  - 同一次重组还每次重新构造 `darkColorScheme(...)` / `lightColorScheme(...)`（约 30 个 Color 字段）与 `appleLikeTypography(...)`（`AuralisTheme.kt:79-119`）。
- **影响范围**：移动端 + TV（仅主题切换期间，但影响面是全屏）。
- **修改方向**：
  1. 把 `LocalAuralisTheme` 改为普通 `compositionLocalOf`（可做读取追踪，避免全树失效），或
  2. 只在**真正需要的 token** 上做动画：把颜色动画下沉到消费点（背景/文字各自 `animateColorAsState`），provider 只提供静态 `theme`；
  3. `ColorScheme`/`Typography` 用 `remember(theme)` 缓存，避免每帧分配；
  4. 或接受「主题硬切」+ 一个短暂的透明度过渡（成本远低于全树颜色动画）。

#### P-09 【P0·性能】领域模型未标 `@Immutable`，且大量不稳定 lambda/Modifier 作为参数 → 子树无法跳过

- **表现/复现场景**：任何父级重组（playback 状态变化、Dock 动画、首页刷新）都会连带整片可见列表重组。
- **根本原因**：
  - 全仓 `@Immutable`/`@Stable` 只出现在 `AuralisTokens.kt:71/90/99/108/117`（designsystem token），**`core:domain` 一个都没有**；
  - `Models.kt:86-105` `Track` 含 `val genres: List<String>`，`Album`/`Artist`/`PlaybackSnapshot`/`QueueSnapshot` 同理 → Compose 稳定性推断为 **unstable**，所有以它们为参数的 Composable 默认不可跳过（除非启用 strong skipping 且实例同一）；
  - 典型不稳定参数：
    - `MobileShell.kt:236-243 / 249-262 / 277-283`：把**局部函数的绑定引用** `::playShelf` / `::playNextShelf` / `::appendQueueShelf` / `::openBrowse`（捕获 `scope`、`graph`、`context`，每次重组都是新对象）传给 `AppleParityHomeScreen`/`LibraryScreen`/`AssistantScreen`；
    - `AppleParityHomeScreen.kt:170` `onReshuffle = { state.reshuffle(module.id) }`（`HomeScreens.kt:175` 同）；
    - `LibraryScreen.kt:106` 把**构建期高频变化的 `recommendationIndexState`** 提升为整屏参数（构建索引时每批推进都会产生新对象 → 整屏重组，而进度卡片根本不在当前 TAB）。
- **影响范围**：移动端 + TV。
- **修改方向**：
  1. 给 `core:domain` 的领域模型加 `@Immutable`（前提：确认所有集合字段真正只读；`genres` 用 `List` + `@Immutable` 约定即可，或改用 `kotlinx.collections.immutable`）；
  2. 把 shell 层的回调改成 `remember` 出来的稳定 lambda（`val playShelf = remember { { tracks, idx -> ... } }`）或改成 `interface`/`ViewModel` 方法引用；
  3. `recommendationIndexState` 不要从 shell 顶层下传，改为 `CompositionLocal` 或只在 Categories TAB 内部订阅；
  4. 用 B-05 的 Compose 报告验证 `skippable` 比例变化。

#### P-10 【P1·性能】逐帧动画值经普通参数注入 `contentPadding` → 每帧 LazyLayout 重新 measure

- **表现/复现场景**：上滑收起底部 Dock、或在 Assistant 页收键盘回弹时，列表在 560ms 内明显抖动/掉帧；长列表更明显。
- **根本原因**：
  - `MobileShell.kt:117-132`：`animateFloatAsState(560ms)` → `dockProgress` → `scrollBottomClearance` 在 **composition 中计算**，作为 `bottomChromeClearance` 传入三个页面（`MobileShell.kt:241 / 260 / 271`）；
  - 消费点是 `LazyColumn/LazyGrid` 的 `contentPadding`：`AppleParityHomeScreen.kt:148-153`、`LibraryScreen.kt:460-465 / 645 / 679-684 / 827 / 957-962 / 1011-1016`、`BrowseDetailScreen.kt:395-397` 等；
  - `contentPadding` 每帧变化 → 每帧强制 LazyLayout 重新 measure；同时 `DockBottomReservation.kt:26-41` 的 `rememberDockBottomReservation` 检测到 padding delta 会 `scrollBy(delta)`，触发**第二次 measure**。即 560ms × 60fps ≈ 34 帧内每帧两次 measure。
  - 同类模式：`AssistantScreen.kt:334-344`（`horizontalInset`/`bottomInset` 由 `collapseProgress` 每帧计算后进 `Modifier.padding`）；`TvNowPlayingScreen.kt:197-201`（`animateDpAsState` 的 `playerLeading` 通过 `.offset(x = playerLeading)` 传入 —— Lint 已就此报 **`UseOfNonLambdaOffsetOverload`**）。
- **影响范围**：移动端（TV 传常量 `24.dp`，见 `TvShell.kt:302/316`，不受此条影响）。
- **修改方向**：动画值只在**两端取值**（`progress < 阈值 ? A : B`），或用 `Modifier.drawBehind`/`Layout` 在测量阶段读取；`Modifier.offset` 改 `Modifier.offset { IntOffset(...) }` lambda 版本；把「底部预留」实现为固定的最大高度 + 不可见占位（spacer），而不是把动画值喂给 `contentPadding`。

#### P-11 【P1·性能】列表索引用 `indexOfFirst` 反向查找（O(n²) + 大量字符串分配）

- **表现/复现场景**：首页每个横向货架在重组时做一次 O(n²) 扫描；TV 版本更贵。
- **根本原因**：
  - `AppleParityHomeScreen.kt:231-234`：`items(module.tracks, ...) { track -> val index = module.tracks.indexOfFirst { it.globalId == track.globalId } ... }`；
  - `HomeScreens.kt:343-348`（TV 首页）：`indexOfFirst { it.globalId.serialized == track.globalId.serialized }` —— 每次比较调用 `serialized` getter，而 `Identity.kt:40-41` `GlobalId.serialized` 是**计算属性**，每次访问新建 `"${serverId.value}:$remoteId"` 字符串。24 项货架 × 24 次比较 × 2 个字符串 × 9 个货架 ≈ 每次首页重组上万次字符串分配；
  - `items(...)` 的 `key = { it.globalId.serialized }`（`AppleParityHomeScreen.kt:231/240/250`、`HomeScreens.kt:343/360/373`、`LibraryScreen.kt:647/687/829/965/1019`、`BrowseDetailScreen.kt:655/940/1012`）也每次求 key 都新建字符串。
- **影响范围**：移动端 + TV。
- **修改方向**：改用 `itemsIndexed` 直接拿 index；`key` 用廉价稳定值（如已有 string id，或缓存 `serialized`）；`GlobalId` 把 `serialized` 改为 `val`（在构造时算一次）或加 `@Transient` 缓存字段。

#### P-12 【P1·性能】字符串格式化在热路径上使用 `String.format`

- **表现/复现场景**：TV 播放页时间标签每秒刷新 4 次；曲目列表每行一次；滚动时逐行触发。
- **根本原因**：
  - `TvNowPlayingScreen.kt:1177-1182` `formatTvClock` 用 `"%d:%02d".format(...)`；调用点包括 `:574`、`:580`（每帧/每次 position 更新 × 2）与 `:1102`（队列每行）；
  - `LibraryCommon.kt:50-53` `formatDurationSeconds` 同样用 `String.format`，消费点在 `LibraryTracks.kt:150`（每行）。
  - `String.format` 每次新建 `java.util.Formatter` 并解析格式串，是公认的高开销路径。
- **对比**：移动端 `PlayerUi.kt:44-49` 的 `formatClock` 已用字符串模板（正确做法）。
- **修改方向**：统一为字符串模板 + `padStart`（或预计算并缓存时间字符串），删除 `String.format`。

#### P-13 【P1·性能】`BoxWithConstraints` 参与高频重组路径

- **表现/复现场景**：TV Now Playing 每 250ms 重组一次时，`BoxWithConstraints` 需要额外一次子组合 + 测量。
- **根本原因**：`TvNowPlayingScreen.kt:184`、`NowPlayingScreen.kt:218/327`、`BottomDock.kt:90`、`AppleBottomChrome.kt:186` 使用 `BoxWithConstraints`（内部为 `SubcomposeLayout`，会在测量阶段再次组合内容），而 `TvNowPlayingScreen` 与 `NowPlayingScreen` 都位于高频重组路径上。
- **修改方向**：改为在父级用 `Layout`/`onSizeChanged` 获取尺寸，或把尺寸相关的计算集中到一处 `remember`，避免 `BoxWithConstraints` 出现在每帧路径。

#### P-14 【P1·性能】常驻无限动画与流式输出驱动的整屏重组

- **表现/复现场景**：
  - TV：只要有已加载曲目，导航 rail 的 `TvEqualizer` 就在跑（即使暂停）；
  - AI 对话：助手输出过程中整屏抖动、自动滚动发抖。
- **根本原因**：
  - `TvShell.kt:487-522` `TvEqualizer` 用 `rememberInfiniteTransition()` + 3 个 `animateFloat`（`:490-507`）**无条件创建**；`active=false` 时 target 等于 initial，动画循环仍在跑（持续占用 Choreographer 帧回调，阻止进入空闲）；
  - `NowPlayingArtworkGlow.kt:67-76` 的 `while(true)` 循环（见 P-06）；
  - `AssistantScreen.kt:81-89` 顶层收集 **9 个 StateFlow**，其中 `run`（`AssistantRunPresentation`）在流式输出时每个 token/事件都变 → 整个 `AssistantScreen` 重组；`:121-128` 的 `LaunchedEffect(scrollTarget)` 在每个 token 都重启 `animateScrollToItem`（取消上一次动画），表现为滚动发抖；
  - `AssistantScreen.kt:104-119` 还有一条 `snapshotFlow` 持续观察 `layoutInfo`。
- **修改方向**：
  1. `TvEqualizer` 在 `active=false` 时不创建 `rememberInfiniteTransition`（条件分支里创建，或用 `Animatable` + `LaunchedEffect(active)` 控制）；
  2. 助手流式内容用独立的小 Composable 承接（`run.liveItems` 单独订阅），并把「自动滚动」改为节流（如 120ms 合并一次）或在内容高度变化时用 `scrollBy` 而非重启动画；
  3. `snapshotFlow` 的 `Triple` 可加 `distinctUntilChanged()`。

### 3.3 渲染与图片（其余项）

#### P-15 【P1·性能】TV Now Playing 的过度绘制

- **表现/复现场景**：TV 播放页 GPU 负载高、风扇/发热（盒子无风扇则降频掉帧）。
- **根本原因**：`TvNowPlayingScreen.kt:335-390` 在同一全屏区域依次绘制：基础 `linearGradient`、被 `graphicsLayer(scale=1.15)` 放大的全屏封面（1024 tier）、`radialGradient` 叠加层、再一层 `linearGradient` 遮罩；加上 `:360` 的 96dp 模糊。全屏 4–5 层合成。
- **修改方向**：把背景合成为**单张预渲染位图**（封面降采样 → 模糊 → 叠加渐变与暗角 → 缓存），track 变化时才重建。

#### P-16 【P2·性能】`TextStyle.copy()` 在 composition 中构造，破坏 `remember`/跳过

- **根本原因与证据**：
  - `PlayerUi.kt:97-99` `remember(text, style) { textMeasurer.measure(text, style, ...) }`，而调用方传入的 `style` 是 `MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)`（`NowPlayingScreen.kt:684`）——**每次重组都是新 `TextStyle`**，导致 key 变化 → **每次重组都重新测量（字形整形）**；
  - 同类：`NowPlayingScreen.kt:431`（歌词行）、`:532`、`:581`、`:590-594`；`TvNowPlayingScreen.kt:1021-1031` 等。
- **修改方向**：把这类 `copy()` 结果提升为顶层 `val` 或用 `remember(theme) { ... }` 缓存。

#### P-17 【P2·性能】Lint 已报的 Compose 规范问题

- **实证（`app-tv/lint-results-debug.txt`）**：
  - `TvNowPlayingScreen.kt:247`、`:318` `Warning: State backed values should use the lambda overload of Modifier.offset [UseOfNonLambdaOffsetOverload]`；
  - `TvShell.kt:95`、`MobileShell.kt:71`、`ShellPages.kt:40` `Warning: Modifier parameter should be the first optional parameter [ModifierParameter]`；
  - `MainActivity.kt:82` `Information: Prefer mutableIntStateOf instead of mutableStateOf [AutoboxingStateCreation]`。
- **修改方向**：`offset{ IntOffset(...) }`；调整参数顺序；`mutableIntStateOf`。

---

## 4. 稳定性：闪退与崩溃

### S-01 【P0·稳定性】前台服务竞态：可能从未 `startForeground` 直接 `stopSelf`

- **表现/复现场景**：用户点「下载」后立刻取消/极快完成，或下载任务瞬时归零；在部分 OEM（以及 Android 12+ 的严格 FGS 校验）上进程崩溃：`android.app.RemoteServiceException$ForegroundServiceDidNotStartInTimeException`。
- **根本原因（时序推演，代码位置）**：
  - `AuralisGraph.kt:272-275` `startDownloadService()` 调 `startForegroundService(...)`；
  - `AuralisApp.kt:40-50` / `AuralisTvApp.kt:33-43` 的收集器：`activeCount > 0 && !serviceRequested` → 发起 `startForegroundService`；
  - 系统要求约 5s 内调用 `startForeground`。`DownloadService.onCreate`（`DownloadManager.kt:313-318`）在 `manager == null` 时**直接 `stopSelf()`**；`onStartCommand`（`:320-334`）用 `mgr.activeCount.value` 调 `updateForegroundState`，而 `:345-358` 在 `count == 0` 分支（`:357`）执行 `stopSelf()`——**整条路径没有 `startForeground`**。
  - 竞态窗口：收集器读到 `count>0` 并发出 `startForegroundService` 之后、`onStartCommand` 执行之前，若最后一个下载完成使 `count` 回到 0，则服务在被提升为前台之前就被 `stopSelf`。此外 `AuralisApp.kt:41` 的 `serviceRequested` 只在 `count == 0` 时复位，若服务被系统回收而 `count` 仍 > 0，收集器不会再次拉起服务（通知消失但 UI 仍显示下载中）。
- **影响范围**：移动端 + TV。
- **修改方向**：
  1. `onStartCommand` 内**先无条件 `startForeground(NOTIFICATION_ID, notification)`**，随后再按 `activeCount` 决定是否 `stopForeground + stopSelf`；
  2. 用 `startForegroundService` 的 `intent` 传递「本次是否需要前台」的显式意图，或在服务内维护 `pendingStart` 标记；
  3. `serviceRequested` 增加「服务存活」校验（`ActivityManager.getRunningServices` 不可靠，建议改为 `DownloadService` 主动广播/`StateFlow` 心跳），并在 `onDestroy`/`onTaskRemoved` 复位。

### S-02 【P0·稳定性】`getMany` 的 `IN (...)` 未分块 → `too many SQL variables`

- **表现/复现场景**：收藏数或歌单曲目数超过 SQLite 变量上限时（旧 Android 999，部分 32766），打开收藏列表/歌单详情/触发 `resolveTrackGids` 直接抛 `SQLiteException: too many SQL variables`，协程失败 → 列表空白或崩溃。
- **根本原因**：
  - `Daos.kt:88-89` `@Query("SELECT * FROM tracks WHERE global_id IN (:globalIds)") suspend fun getMany(globalIds: List<String>)`，Room 会展开为具体个数的占位符，**不分块**；
  - 调用点：`RoomCatalogRepository.kt:735`（`resolveTrackGids`，由 `favoriteTrackIds` 全量结果驱动）、`:178`、`:689`（`commitCatalogSnapshot` 内逐歌单点查）。
  - 对照：同文件写路径**已经分块**（`WRITE_CHUNK = 800`、`FTS_DELETE_CHUNK`），说明该限制已知但读路径漏了。
- **影响范围**：移动端 + TV（崩溃）。
- **修改方向**：`getMany` 在仓库层按 `chunked(800)` 调用并合并；或改用 JOIN 临时表方案。

### S-03 【P0·稳定性】`Dispatchers.Default` 承载阻塞下载 + `readTimeout = 0` → 全局饿死

- **表现/复现场景**：下载几个大文件或服务器卡流时，整个应用变卡甚至假死：首页不刷新、本地扫描停止、bootstrap 卡住。
- **根本原因**：
  - `DownloadManager.kt:59` `CoroutineScope(SupervisorJob() + Dispatchers.Default)`，而 `:193` 使用 **阻塞式** `okHttp.newCall(request).execute()`；
  - `Dispatchers.Default` 并行度 = `max(2, CPU-1)`，4 核手机仅 3 线程；`MAX_CONCURRENT_DOWNLOADS = 3`（`:277`）恰好能把池占满；
  - `:299-303` `defaultOkHttpClient()` 设置 `readTimeout(0, MILLISECONDS)` = **无读超时**，服务器半开连接/卡流时该线程永久阻塞；
  - 同一 `Dispatchers.Default` 被 `AuralisGraph.kt:66` 的 `appScope` 使用（承载 `bootstrapFromLocal`、`downloads.hydrate`、`localMusicLibrary.scanAll`、`CachedCatalogRepository` 的解码协程）。
- **影响范围**：移动端 + TV。
- **修改方向**：
  1. 下载改到 `Dispatchers.IO`（阻塞 IO 的正确归属），或把 `execute()` 改成 `withContext(Dispatchers.IO)` 包裹；
  2. `readTimeout` 设为有限值（如 60s）+ 大文件用 `callTimeout` 或读空闲超时（`.readTimeout` 对流式响应不适用，应改用 `OkHttp` 的 `EventListener` 或自己实现空闲检测）；
  3. `appScope` 与下载器分离调度器，避免互相饥饿。

### S-04 【P0·稳定性】`HomeState.reshuffle` 无异常保护 → 未捕获异常冒到组合作用域

- **表现/复现场景**：点首页某个货架的「换一批」，若 DB/查询失败，进程崩溃（而非弹出错误）。
- **根本原因**：`HomeState.kt:96-108` `reshuffle()` 内的 `scope.launch { ... repo.randomTracks(...) ... }` **没有 try/catch**；而同一文件的 `refresh()`（`:122-132`）有 `try/catch(Throwable)` 包裹。`scope` 来自 `rememberCoroutineScope()`（父 Job 未挂 `SupervisorJob`），未捕获异常会向上冒泡为未捕获异常 → 进程崩溃。
- **影响范围**：移动端 + TV。
- **修改方向**：与 `refresh` 一致地包裹 `runCatching`/`try-catch` 并写入 `lastError`；或将 `HomeState` 的 scope 改为带 `SupervisorJob` 的独立 scope。

### S-05 【P1·稳定性】Flow 内的 `valueOf` / `parse` 无保护

- **表现/复现场景**：数据库中一旦出现历史/外部写入的非法枚举值或非法 `global_id`，下载状态流抛异常，收集协程失败 → 相关列表永久不刷新（或崩溃）。
- **根本原因**：`RoomCatalogRepository.kt:748-754` `toDownloadRecord` 内直接 `GlobalId.parse(e.globalId)` 与 `DownloadStatus.valueOf(e.state)`；被 `:475-479` 的 `observe(...)`/`observeAll(...)` 的 `.map` 调用，**在收集线程抛出**，未包裹 `runCatching`。对比 `:292-295` `observeDislikedIds` 对 `GlobalId.parse` 做了 `runCatching`（正确做法）。
- **修改方向**：`toDownloadRecord` 返回可空 / 用 `runCatching`，非法行降级为「忽略 + 日志」。

### S-06 【P1·稳定性】`requireNotNull` / `require` / `error` 在未兜底路径上

- **根本原因与位置**：
  - `ServerClientRegistry.kt:72 / :83 / :100` `requireNotNull(account.baseUrl / externalBaseUrl / credentialReference)`；`AuralisGraph.kt:151`（`registerAccount` 的 else 分支）与 `ProductionServerConnector.kt:158 / 192-197` 直接调用而未包裹（`clientFor`（`:116-122`）已用 `runCatching`，说明作者知道会抛，但覆盖不全）；
  - `RecommendationIndexStore.kt:53 / :165 / :240` 的 `require(...)` / `error(...)`，输入来自 AI 模型输出，任一条非法即整体抛；
  - `AndroidLocalMusicLibrary.kt:168-170` `requireLocal` 的 `require`；
  - `GlobalId.parse`（`Identity.kt:44-48`）的 `require(index > 0)`；
  - `LibraryCommon.kt:132-137` 的 `fromHex` `require`：**主题色 hex 非法即启动期抛异常**，无兜底。
- **影响范围**：移动端 + TV。
- **修改方向**：对「来自持久化/外部输入」的值一律使用可空解析 + 降级；在 UI 触发路径统一包 `runCatching` 并提示；`fromHex` 对非法值回退到默认主题色。

### S-07 【P1·稳定性】`runCatching` 吞掉 `CancellationException`

- **根本原因**：`kotlin.runCatching` 捕获 `Throwable`。多处（如 `HomeState.kt:119/148/160`、`LibraryTracks.kt:298/358`、`BrowseDetailScreen.kt` 多处、`SearchScreen.kt:137/162/174/178`）在 `LaunchedEffect`/`collect` 内使用，会把「页面已离开导致的取消」当作普通失败并继续写状态（`lastError`、`loaded = true`），破坏结构化并发，出现「回到页面先闪一次旧错误/旧数据」。
- **修改方向**：统一改为 `catch (e: CancellationException) { throw e } catch (e: Throwable) { ... }`，或封装 `runCatchingCancellable`。

### S-08 【P1·稳定性】TV 播放失败会被静默吞掉

- **根本原因**：`TvShell.kt:527-532`：
  ```kotlin
  private fun List<Track>.stableTrackCopy(): List<Track> {
      repeat(3) { runCatching { return toList() } }
      return emptyList()
  }
  ```
  `playShelf/playNextShelf/appendQueueShelf`（`:177-209`）在结果为空时直接 `return`，**用户点击没有任何反馈**（也不 Toast）。这个「重试 3 次再返回空」的写法本身是对某类并发修改异常的兜底，说明 `List<Track>` 可能在跨线程被改写。
- **修改方向**：找出并修复导致 `toList()` 抛异常的真正并发源（大概率是 `SnapshotStateList`/可变 List 跨线程）；失败时给出可见反馈而不是静默返回。

### S-09 【P1·稳定性】下载队列的协程无上限 + 竞态

- **根本原因**：
  - `DownloadManager.kt:156-179` `submit()` 每次调用都 `scope.launch`，仅在 `semaphore.withPermit` 处排队；**排队协程数无上限**。下载「整张专辑/整个歌单」会一次性创建成百上千协程，各自持有 `Track`，`activeTasks` 与 `_activeCount` 同步膨胀——与 `AuralisApp.kt:17-18` 注释声称的「不会同时 launch 上百任务」不符；
  - `pendingQueue`（`:68`）只有 `add`（`:159`）与 `removeAll`（`:177`），**从未被消费**，是死结构；
  - `:158` `activeTasks.containsKey(key)` 与 `:172` `activeTasks[key] = job` 非原子（两个线程并发提交同一 key 可能重复入队）；`:157` `tombstones.remove(key)` 与 `:87` `tombstones.add(key)` 存在「刚取消又被重新提交」的竞态。
- **影响范围**：移动端 + TV。
- **修改方向**：用 `activeTasks.computeIfAbsent` 做原子去重；用固定大小的 `Channel`/`Flow` 替代「无界 launch + Semaphore」；删除或实现 `pendingQueue`。

### S-10 【P1·稳定性】本地曲库读改写无同步

- **根本原因**：`AndroidLocalMusicLibrary.kt`：`scanAll`（`:60-87`，IO 线程）整体替换 `_tracks.value`（`:78`）并 `bumpRevision()`（`:79`）；而 `setFavorite`（`:96-98`）、`setRating`（`:108-110`）、`removeSource`（`:56`）在调用线程（可能 Main）对 `_tracks.value` 做 **read-modify-write**。并发时后写覆盖前写；`_tracks` 与 `_revision` 是两次独立写入（`:78-79`），观察者可能先看到 revision 变化而看不到新 tracks。
- **修改方向**：改用 `MutableStateFlow.update {}`（原子），或加 `synchronized`/`Mutex`；`_revision` 与 `_tracks` 合并为单一状态对象。

### S-11 【P2·稳定性】通知权限未在运行时请求

- **实证**：`grep -rn "POST_NOTIFICATIONS\|requestPermissions" core feature app-mobile app-tv` → **无命中**；但 `app-mobile/src/main/AndroidManifest.xml:8` 与 `app-tv/.../AndroidManifest.xml:8` 都声明了 `POST_NOTIFICATIONS`。
- **影响**：Android 13+ 上媒体播放/下载前台服务通知可能不显示，用户无法从通知栏控制播放/看到下载进度；也不会崩溃（Media3 有降级路径），但属于明显功能缺失。
- **修改方向**：在主 Activity 首帧后请求 `POST_NOTIFICATIONS`（并在拒绝时给出说明）。

### S-12 【P2·稳定性】`EncryptedSharedPreferences` 写入使用 `apply()`

- **根本原因**：`KeystoreCredentialVault.kt:38-48` `store`/`delete` 用 `prefs.edit().apply()`（异步落盘）。若在写入后进程立即被杀，凭据可能未落盘，下次启动 `retrieve` 返回 null；`ProductionServerConnector.connect` 的先 `store` 再认证顺序会使补偿逻辑依赖 `previousSecret`，留下不一致。
- **修改方向**：凭据写入改用 `commit()`（或写入后 `await` 落盘），并保证认证成功后再提交账户；失败时回滚。

---

## 5. 内存

### M-01 【P1·内存】进程级全量 List 缓存无上限、无低内存驱逐

- **根本原因**：`CachedCatalogRepository.kt:46-51` 为每个 server 键（含 `<all-servers>`）保留**完整解码后的** `CachedList<Artist/Album/Track/...>`，底层是 `MutableSharedFlow(replay = 1)`（`:113`）**永久持有**。数万曲目时 `artists/albums/tracks/favorites` 常驻，且 `<all-servers>` 与单服务器键可能各存一份。`evict` 只在 `forgetServer` 时调用，**没有 `onTrimMemory` / 低内存回调**。
- **影响范围**：移动端 + TV。
- **修改方向**：引入 `ComponentCallbacks2.onTrimMemory` 驱逐非活跃 server 缓存；对超大规模库改用分页/窗口化（`QueueWindowing` 已是同类思路）；评估 `replay = 1` 是否必要。

### M-02 【P1·内存】三处无界增长的集合

| 位置 | 结构 | 说明 |
|---|---|---|
| `LyricsServiceImpl.kt:32/36` | `cachedMisses: Set<String>` | 任何「远端也无歌词」的曲目永久写入，仅 `clearCache()` 清空；数万曲目后持续驻留 |
| `DownloadManager.kt:71/259` | `_failures: MutableStateFlow<Map<...>>` | 每次失败 `value + (key to failure)`（整表复制）且**永不清除**，重试成功后也不移除 |
| `AndroidLocalMusicLibrary.kt:96-98/108-110` | `_tracks` 整体复制 | 每次收藏/评分复制整库 List（短命大对象 → GC 抖动） |

- **修改方向**：负缓存改为有界 LRU（或加 TTL）；`_failures` 用 `MutableStateFlow` 的 `update {}` + 成功时移除 + 上限；本地库改按 id 索引的持久结构。

### M-03 【P2·内存】封面多 tier 并存

- 见 P-07：同一 `artworkKey` 因 `requestSize` 不同在内存中存在 64/128/256/512 多份 Bitmap。
- **修改方向**：固定 tier 集合（列表 128、网格 512），或在 `ImageLoader` 层做 `memoryCachePolicy` 与尺寸归一。

### M-04 【P2·内存】TV 播放页的 1024 tier 封面

- 见 P-05/P-15：`TvNowPlayingScreen.kt:351` `targetSizeDp = 1024` 的环境封面（解码后 4 MB 级 ARGB_8888，再被放大 1.15× 后模糊），与主封面（320–520dp）同时驻留。

---

## 6. 线程与并发（其余项）

### T-02 【P1·线程】服务端同步声称「6 并发」实为完全串行

- **根本原因**：`ProductionServerConnector.kt:456-469`：
  ```kotlin
  albums.chunked(6).forEachIndexed { index, chunk ->
      val details = chunk.mapNotNull { album -> runCatching { client.album(album.id.value) }.getOrNull() }
      ...
      if (index % 10 == 9) delay(1)
  ```
  注释写「Apple：专辑列表 + 6 并发专辑详情补全曲目」，但 `chunk.mapNotNull { ... }` 是**顺序阻塞**执行，没有 `async/awaitAll`。对数千专辑的大库，首次连接/重同步是 O(专辑数) 次串行往返，期间 `_stage` 长时间停在 `LoadingLibrary`。
- **影响范围**：移动端 + TV（表现是「首次连接非常慢」，用户感知为卡住）。
- **修改方向**：用 `coroutineScope { chunk.map { async { ... } }.awaitAll() }` 实现真正的 6 并发；加进度回调与可取消。

### T-03 【P2·线程】闲置/死代码与调度器职责混杂

- `ProductionServerConnector.kt:107` `private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)`：全文件无任何引用，随连接器常驻进程且无 `cancel()` 入口（死作用域）。
- `AuralisGraph.kt:243-246`：`ArtworkUrl.provider` 内 `runBlocking { client.coverArtUrl(...) }`。当前唯一调用方 `ArtworkView.kt:76-78` 已包在 `withContext(Dispatchers.IO)`，因此阻塞的是 IO 线程；但 `ArtworkUrl.provider` 是全局可变单例，**任何未来在 Main 调用它的路径都会直接阻塞主线程**，且 `coverArtUrl → authParams` 会走 Keystore 解密。
- **修改方向**：删除死作用域；`ArtworkUrlProvider` 改为 `suspend` 接口，去掉 `runBlocking`。

### T-04 【P2·线程】每请求重复 Keystore 解密与新建 OkHttpClient

- **根本原因**：`OpenSubsonicClient.kt:64-88` `authParams()` 在**每次请求**（`:106`）与**每次 URL 构造**（`:362`，用于 stream/download/coverArt）都调用 `vault.retrieve` → 每次一次 AES-GCM 解密；而 `KeystoreCredentialVault.kt:42-44` 每次 `withContext(Dispatchers.IO)` 无内存缓存。另 `OpenSubsonicClient.kt:118-121` 每次请求 `http.newBuilder().callTimeout(...).build()` 新建 OkHttpClient 对象。
- **修改方向**：解密结果做带失效的短 TTL 内存缓存；OkHttpClient 复用（只改 `Call` 级超时）。

### T-05 【P2·线程】下载进度写库节流仍会造成整表刷新风暴

- **根本原因**：`DownloadManager.kt:219-227` 节流为「进度变化 ≥1% 或距上次 ≥250ms」，最坏 4 次/秒/任务 × 3 任务 = 12 次 Room upsert/秒；每次 upsert 都 invalidate `downloads` 表 → 触发 `Daos.kt` 中 `observeAll` / `observe` / `observeDownloadedCount` 重新发射 → `LibraryTracks.kt:103` 每行一个 `observe(globalId)` 全部重建。
- **修改方向**：进度写库频率降到 1 次/秒或改为内存态 + 结束时落库；下载状态用单一「批量快照 Flow」替代逐行 Room 订阅。

---

## 7. Android TV 专项

### V-01 【P0·TV】全屏模糊在 TV 上是「要么没效果、要么掉帧」的二选一

- **表现/复现场景**：
  - 官方 Android TV（Android 9/10/11 盒子）：播放页背景**看不到模糊**（设计与移动端不一致）；
  - Android 12/13 TV：模糊出现但播放页整体掉帧、发热。
- **根本原因**：`TvNowPlayingScreen.kt:360` `.blur(96.dp)`。Compose 的 `Modifier.blur` **仅在 Android 12(API 31) 及以上生效**，以上版本通过 `RenderEffect` 实现（逐帧 GPU 全屏模糊）；API < 31 静默无效。`app-tv` minSdk = 26。
- **修改方向**：改为「一次性预模糊位图」（track 变化时在 `Dispatchers.Default` 生成一张 64–128px 的模糊缩略图，再 `drawImage` 放大 + 渐变遮罩），既保证 API<31 视觉一致，又把逐帧成本降为一次绘制。

### V-02 【P1·TV】Activity 无 `configChanges`，且根 `route` 用 `remember` → 任何配置变化都回到启动流程

- **表现/复现场景**：
  - TV：切换系统语言、分辨率/HDR 变化、或某些盒子的 HDMI 重协商 → Activity 重建 → `AppRoot` 的 `route` 重置为 `Route.Boot` → 重新 `bootstrapFromLocal()`，用户被弹回启动画面；
  - 移动端：`app-mobile/src/main/AndroidManifest.xml:31` 只有 `orientation|screenSize|keyboardHidden`，**缺 `uiMode|density|screenLayout|smallestScreenSize|keyboard|navigation`**；系统切换深色模式会重建 Activity（虽然产品主题不跟随系统，但重建代价与状态丢失仍发生）。
- **根本原因**：`TvMainActivity.kt:87` `var route by remember { mutableStateOf<Route>(Route.Boot) }`（非 `rememberSaveable`），`shellReady`（`:88`）同理；`TvMainActivity` 清单无 `configChanges`。
- **修改方向**：TV 加 `android:configChanges="keyboard|keyboardHidden|navigation|uiMode|density|screenLayout|smallestScreenSize|screenSize|orientation"`；`route` 相关的最小信息用 `rememberSaveable`（或 `onSaveInstanceState`）保留；避免在配置变化时重新 bootstrap。

### V-03 【P1·TV】四个共享屏幕零焦点代码，TV 交互只能依赖全局兜底

- **事实（grep 实证）**：`feature/home`、`feature/library`、`feature/search`、`feature/server` 下**没有任何** `FocusRequester` / `focusGroup` / `focusProperties` / `onFocusChanged` / `focusable`。仅 `feature/assistant`（`AssistantScreen.kt:332/391`、`AssistantDialogs.kt:133/160`）与 `feature/settings`（`SettingsScreens.kt:253-261`、`AiSettingsPage.kt:458/459`）做了显式焦点处理。`app-tv` 自身有 `TvFocus.kt`、`TvShell.kt:125-155` 的焦点恢复逻辑。
- **焦点视觉实际是有的**：`TvMainActivity.kt:65` 的 `ProvideTvIndication`（`TvFocus.kt:174-219`）把 `LocalIndication` 换成 `TvIndication`，因此共享屏幕里所有 `Modifier.clickable(onClick = ...)` 默认会拿到 3dp 焦点描边 + 11% 填充；`indication = null` 的地方（`AssistantScreen.kt:366`、移动 shell 的 `AppleBottomChrome.kt:359/389/438`、`BottomDock.kt:199`、`MiniPlayerBar.kt:76/195`）没有默认焦点视觉——但这些文件除 `AssistantScreen` 外都是移动端专用，且 `AssistantScreen` 已用 `assistantTvFocus` 自定义（`AssistantTvFocus.kt:39-65`）。
- **真正缺口**：
  1. TV 上 Home/Library/Search/Server 页**没有初始焦点请求**，进入页面后焦点落点依赖系统默认搜索；
  2. **没有 `focusGroup` 边界**：`TvShell.kt:268-274` 只给内容区加了 `focusGroup()`，各货架/网格之间没有分组，跨 rail/content 与货架间跳转行为不可控；
  3. **尺寸仍是手机规格**：`LibraryScreen.kt:127` `AuralisChrome.minTouchTarget` = 44dp、行高约 56dp、标签 11–12sp（`SearchRows.kt:51`、`SearchScreen.kt:470`）——10 英尺观看距离下偏小；项目自己的旧审查文档 `docs/audit/10-android-tv.md:75/85` 已记录「焦点可见性（主要缺口）」「复用页面控件为触摸尺寸」。
- **修改方向**：为 TV 提供一层「TV 尺寸/焦点策略」：给每页加初始 `FocusRequester`、给货架/网格加 `focusGroup`、用 `focusProperties` 明确 rail↔content 的上下左右边界；通过 `LocalConfiguration.uiMode` 判断 TV 并放大字号/命中区（不要用 `Resources.getSystem()`，见 V-04）。

### V-04 【P2·TV】`assistantIsTelevision()` 读取系统资源而非应用配置

- **根本原因**：`AssistantTvFocus.kt:25-28` `Resources.getSystem().configuration.uiMode`。`Resources.getSystem()` 返回的是**系统默认资源**的配置（不含应用覆盖），在多显示/开发者覆盖设置下可能与实际应用配置不一致。
- **修改方向**：改用 `LocalConfiguration.current.uiMode`（Compose）或在 `Activity` 中读取 `resources.configuration`。

### V-05 【P2·TV】overscan / 安全区未统一处理

- **表现/复现场景**：部分电视因 overscan 导致导航 rail 左侧、内容底部、播放页控件被裁掉一部分。
- **根本原因**：`TvMainActivity.kt:57` `enableEdgeToEdge()`（TV 场景应做安全区而非 edge-to-edge），而 `TvShell` 只在 rail 上用 `padding(horizontal = 12.dp, vertical = 20.dp)`（`TvShell.kt:361`），`TvNowPlayingScreen` 用 `maxHeight * 0.055f` 近似（`TvNowPlayingScreen.kt:185`），`TvSplash` 无内边距 —— 各页面各自估算，没有统一的安全区（TV 惯例约 5% 边距 / `WindowInsets.safeDrawing`）。
- **修改方向**：在 TV 根容器统一套用安全区内边距（可用 `WindowInsets.systemBars` + 平台 overscan 常量），去除无意义的 `enableEdgeToEdge`。

### V-06 【P2·TV】TV 首页底部预留按手机 Dock 常量计算

- **根本原因**：`HomeScreens.kt:146-151` 用 `AuralisChrome.dockHeight + dockBottomPadding + xLarge`（=90dp）作为 `contentPadding.bottom`，而 `HomeScreen` **只被 TV 使用**（`TvShell.kt:277`），TV 侧根本没有浮动 Dock（用的是 138dp 侧栏）。同时 `LibraryScreen`/`BrowseDetailScreen` 在 TV 传的是常量 `24.dp`（`TvShell.kt:302/316`），两处语义不一致。
- **修改方向**：TV 首页改用与 Library 一致的常量；把「底部预留」参数化并统一由 shell 提供。

### V-07 【P2·TV】TV 队列/歌词面板的列表规模与键策略

- **事实**：
  - `TvNowPlayingScreen.kt:1056-1058` 队列用 `itemsIndexed(key = { _, entry -> entry.id.value })`（正确）；
  - `:936-938` 歌词用 `key = { index, _ -> index }`（歌词为只增不改，可接受）；
  - 但歌词每行创建 2 个 `animateFloatAsState`（`:941-950`，label 含 index），滚动长歌词时每行 2 个动画状态；
  - `:151-156` `LaunchedEffect(track?.serverId)` 订阅 `observeFavoriteTracks`（**全表**）只为渲染一个收藏心形。
- **修改方向**：收藏状态改为单曲查询（`isFavorite(track.globalId)`）或页面级一次订阅；歌词行的动画改为只对「当前行 + 相邻行」生效（其余用静态样式）。

### V-08 【P2·TV】无 `keepScreenOn`

- **实证**：全仓 `grep keepScreenOn|FLAG_KEEP_SCREEN_ON` 无命中。
- **影响**：长时间只是听歌（不操作遥控器）时，部分设备会进入屏保/待机，导致播放页状态与投屏体验异常（播放本身在前台服务，不受影响，但用户回到界面需重新唤醒）。
- **修改方向**：仅在 TV Now Playing 可见时设置窗口 `FLAG_KEEP_SCREEN_ON`（或用 Compose `keepScreenOn` 修饰符）并按播放状态开关。

### V-09 【P2·TV】列表 `contentPadding` 与 `LazyRow` 嵌套在 TV 上的测量假设

- 事实：TV 首页为 `LazyColumn` + 每模块一个 `LazyRow`（`HomeScreens.kt:144` / `:342`），未设置 `userScrollEnabled = true`（默认 true）。TV 上 D-pad 左右移动焦点时 `LazyRow` 会自动把目标滚入视野，但**没有 `focusGroup` 时会先触发竖向 2D 搜索**，可能出现「右移焦点跳到下一行」的怪异行为。
- **修改方向**：给货架加 `focusGroup()`，必要时用 `focusProperties { right = ... }` 明确边界。

---

## 8. 兼容性

| 编号 | 问题 | 证据 | 影响 |
|---|---|---|---|
| C-01 | `Modifier.blur` 在 API<31 无效果 | `TvNowPlayingScreen.kt:360`、`NowPlayingArtworkGlow.kt:102`；minSdk=26 | 移动 + TV 视觉不一致（见 V-01/P-06） |
| C-02 | mobile `targetSdk=36`（Android 16 行为）但 TV `targetSdk=34` | 两个 build 文件；Lint `OldTargetApi` | TV 平台行为不统一（见 B-04） |
| C-03 | mobile 无 Android 12+ splash 主题 | `app-mobile/src/main/res/values/` 下无 `values-v31/themes.xml`；只有 `android:windowBackground=@android:color/black` | Android 12+ 冷启动出现纯黑闪屏（TV 侧已正确使用 `windowSplashScreenBackground` 等） |
| C-04 | 固定横屏被平台弱化 | Lint：`app-tv/src/main/AndroidManifest.xml:41 Warning: Fixed screen orientations will be ignored in most cases, starting from Android 16 [DiscouragedApi]` | Android 16 TV/大屏上 `screenOrientation="landscape"` 可能失效 → 需要适配多方向（当前 TV 布局对竖屏无处理） |
| C-05 | `usesCleartextTraffic="true"` 全局放开 | 两个清单 `:20` / `:28` | 安全（非性能）；建议改用 `networkSecurityConfig` 仅放行私网地址 |
| C-06 | 导出的 MediaSessionService 未加权限 | Lint：`ExportedService`（mobile `AndroidManifest.xml:40`、tv `:49`） | 任何应用可绑定该服务触发播放会话交互（安全） |
| C-07 | `android:allowBackup="true"` + 凭据排除规则 | `backup_rules.xml` / `data_extraction_rules.xml` 均排除 `auralis_credentials.xml` | **已验证正确**（避免了 EncryptedSharedPreferences 恢复后无法解密的经典崩溃） |
| C-08 | 缺失的运行时权限请求 | 见 S-11 | Android 13+ 通知不可见 |

---

## 9. 修复路线图（按性价比排序）

### 第 0 步（先建立度量，1–2 天）
1. 打开 Compose 编译器 reports/metrics（B-05）；
2. 真机 + TV 上采集 `Perfetto` 或 `adb shell dumpsys gfxinfo <pkg> framestats`，先用 **release 变体**（B-02）建立基线；
3. CI 同时产出 release 与 debug 两种 APK，并明确「性能结论只在 release 上成立」（B-01）。

### 第 1 批（P0，预期收益最大）
| 项 | 动作 | 预期效果 |
|---|---|---|
| B-02 | 开启 R8 + 规则文件 | 包体/启动/运行时全面改善；为 release 性能交付铺路 |
| B-03 | Baseline Profile | 冷启动与首屏滚动直接改善 |
| P-01 | 仓库层加 `Dispatchers.Default/IO` + `flowOn` | 消除首页/搜索/列表的主线程阻塞 |
| P-05 | TV `position` 读取下移 + 环境背景预渲染 | TV 播放页从「每 250ms 整屏重组 + 全屏 blur」变为静态合成 |
| P-06 | 移动 Now Playing 动画值移入 `graphicsLayer` lambda + 预模糊 | 播放中不再每帧重组 |
| P-07 | `SubcomposeAsyncImage` → `AsyncImage`，统一 tier | 列表/网格滚动帧率显著改善 |
| P-04 | 收藏集合提升到页面级单订阅 | 列表行重组与 Room 观察者数量下降 1–2 个数量级 |
| S-01 | `onStartCommand` 先 `startForeground` | 消除 FGS 崩溃类 |
| S-03 | 下载移出 `Dispatchers.Default` + 设置读超时 | 消除全局卡死 |

### 第 2 批（P1）
P-02、P-03、P-08、P-09、P-10、P-11、P-13、P-14、S-02、S-04～S-10、T-02、M-01、M-02、V-02、V-03。

### 第 3 批（P2）
P-12、P-15、P-16、P-17、B-04～B-08、C-02～C-06、M-03、M-04、T-03～T-05、V-04～V-09。

### 必须在同一批一起做的「配套动作」
- 打开 R8 与打开 Baseline Profile 必须一起做（否则 R8 会改变 profile 匹配）；
- 修 P-01（调度器下移）后必须重新审视 M-01（缓存无界）——因为解码压力从主线程转移到后台后，内存增长会变成主要瓶颈；
- 修 V-03（TV 焦点/尺寸）前先补一台真机 TV 的可用性走查清单，避免盲改。

---

## 附录 A：已验证为「正确」的实现（避免误伤）

| 项 | 证据 | 说明 |
|---|---|---|
| 凭据不随备份导出 | `backup_rules.xml`、`data_extraction_rules.xml` 排除 `auralis_credentials.xml` | 避免 EncryptedSharedPreferences 恢复后解密崩溃 |
| Keystore 初始化位置正确 | `KeystoreCredentialVault.kt:25-36` 使用 `by lazy`，首次访问发生在 IO 上下文 | 无主线程加解密、无重复生成主密钥 |
| 注册表线程安全 | `ServerClientRegistry` 使用 `ConcurrentHashMap` | 并发注册/读取安全 |
| 写路径分块 | `RoomCatalogRepository.commitCatalogSnapshot` 使用 `WRITE_CHUNK = 800`、FTS 删除分块 | 与 S-02（读路径未分块）形成对照 |
| `LinearProgressIndicator(progress = { ... })` | `LibraryScreen.kt:532-536` | 使用 lambda 版本，进度推进不引起每帧重组 |
| 时间格式化（移动端） | `PlayerUi.kt:44-49` | 使用字符串模板 + `padStart`，未使用 `String.format` |
| TV 焦点指示 | `TvFocus.kt:174-219` 通过 `LocalIndication` 提供 | 共享屏幕的 `clickable` 自动获得焦点描边 |
| TV 服务端表单 IME/焦点 | `TvServerFormScreen.kt:95-127/325-330` | 明确的「选中 ≠ 编辑」状态机与焦点恢复 |
| 无宿主级阻塞 | 全仓无 `runBlocking`（除 `ArtworkUrl.provider`，见 T-03）、无 `GlobalScope`、无 `Thread.sleep` | 基础纪律良好 |
| 数据库单例 | `AuralisDatabaseProvider` 双重检查锁 | 避免 catalog split-brain |

## 附录 B：TV Lint 原始结论（7 errors / 12 warnings）

**Errors（全部为 i18n）**：`app-tv/src/main/res/values/strings.xml:18-24` 的 7 个字符串（`tv_close_player`、`tv_volume`、`tv_shuffle`、`tv_repeat`、`tv_up_next`、`tv_clear_up_next`、`tv_queue_empty`）缺少 `values-en` 翻译（`[MissingTranslation]`）；同时这 7 个字符串中多数在代码里**未被使用**（`[UnusedResources]`，见 `:13/14/15/18/19`）。

**Warnings（节选，与本审查相关）**：
- `app-tv/build.gradle.kts:11`：`compileSdkVersion` 落后（34 → 36 可用）；
- `app-tv/build.gradle.kts:28`：`targetSdk = 34` 非最新（`[OldTargetApi]`）；
- `app-tv/src/main/AndroidManifest.xml:41`：固定横屏在 Android 16 起基本被忽略（`[DiscouragedApi]`）；
- `TvNowPlayingScreen.kt:247 / :318`：`Modifier.offset` 应使用 lambda 版本（`[UseOfNonLambdaOffsetOverload]`，对应 P-10）；
- `TvShell.kt:95`、`MobileShell.kt:71`、`ShellPages.kt:40`：`Modifier` 参数应为第一个可选参数（`[ModifierParameter]`）；
- `MainActivity.kt:82`：`mutableStateOf(0)` 应用 `mutableIntStateOf`（`[AutoboxingStateCreation]`）；
- `AndroidManifest.xml:40/49`：导出服务未声明权限（`[ExportedService]`，对应 C-06）。

## 附录 B-2：Mobile Lint 原始结论（0 errors / 40 warnings / 1 hint）

**无任何性能或崩溃类 error。** 40 条 warning 中：
- 34 条为依赖版本提示（`[GradleDependency]` / `[NewerVersionAvailable]` / `[AndroidGradlePluginVersion]`）：Gradle 8.13（可升 8.14.5）、AGP 8.12.2（可升 8.12.3/9.4.1）、Compose BOM 2024.09.03（可升 2026.09.00）、Kotlin 2.0.21（可升 2.4.20）、media3 1.4.1（可升 1.11.1）、Room 2.6.1（可升 2.8.5）、Coil 2.6.0（可升 2.7.0）、`androidx.security:security-crypto` 仍在使用 `1.1.0-alpha06`（已发布 1.1.0 稳定版）等；
- `AppleBottomChrome.kt:155 / :288`：`Modifier` 参数应命名为 `modifier`（`[ModifierParameter]`）；
- `MobileShell.kt:72`、`ShellPages.kt:40`：`Modifier` 参数位置（`[ModifierParameter]`）；
- `AndroidManifest.xml:40`：导出服务未声明权限（`[ExportedService]`）；
- `MainActivity.kt:77`：应用 `mutableIntStateOf`（`[AutoboxingStateCreation]`）。

> 注：本审查首次读取 `app-mobile` lint 文本报告时，其中显示的 AGP 版本为 `8.5.2`，与仓库当前的 `8.12.2` 不一致 —— 判定为上一次构建遗留的**陈旧报告**，故用 `--rerun-tasks` 重新生成后才采信。此处结果与当前的 `gradle/libs.versions.toml`、`gradle-wrapper.properties` 一致。

---

## 附录 C：文件索引（本报告引用的关键位置）

- 构建/CI：`app-mobile/build.gradle.kts`、`app-tv/build.gradle.kts`、`android/gradle.properties`、`android/gradle/libs.versions.toml`、`.github/workflows/android.yml`、`.github/workflows/release.yml`
- 组合根与入口：`AuralisApp.kt`、`AuralisTvApp.kt`、`MainActivity.kt`、`TvMainActivity.kt`、`AuralisGraph.kt`
- Shell：`MobileShell.kt`、`AppleBottomChrome.kt`、`BottomDock.kt`、`MiniPlayerBar.kt`、`DockScrollReporter.kt`、`TvShell.kt`、`TvFocus.kt`
- 播放：`AuralisPlaybackEngine.kt`、`PlaybackController.kt`、`PlaybackSnapshots.kt`
- 播放 UI：`NowPlayingScreen.kt`、`NowPlayingArtworkGlow.kt`、`PlayerUi.kt`、`AuralisThinSlider.kt`、`TvNowPlayingScreen.kt`
- 数据：`RoomCatalogRepository.kt`、`UnifiedCatalogRepository.kt`、`CachedCatalogRepository.kt`、`Daos.kt`、`AndroidLocalMusicLibrary.kt`、`RecommendationIndexStore.kt`
- 下载：`DownloadManager.kt`、`DownloadPromotionStore.kt`
- 图像/主题：`ArtworkView.kt`、`AuralisTheme.kt`、`AuralisTokens.kt`、`BuiltInThemes.kt`
- 功能页：`AppleParityHomeScreen.kt`、`HomeScreens.kt`、`HomeState.kt`、`LibraryScreen.kt`、`LibraryTracks.kt`、`BrowseDetailScreen.kt`、`SearchScreen.kt`、`AssistantScreen.kt`、`AssistantTvFocus.kt`、`TvServerFormScreen.kt`
