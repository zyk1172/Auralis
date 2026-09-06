# 离线下载 / 歌词 / 封面 — Apple→Android 迁移规格报告

> 审计对象：Auralis iOS（Swift / OpenSubsonic）。本报告仅引用真实代码，供 Kotlin 实现直接对齐。
> 所有文件路径相对 `Packages/AuralisCore/Sources/`。**Apple 代码只读，本报告未做任何修改。**

---

## 0. 跨链路通用约束（P0-1 / P0-2）

三条链路全部强制「服务器作用域组合键」`serverID:trackID`（`GlobalID.description` 同格式），目的：多服务器同 TrackID（数字 ID 常见）不能串库。

- 音频缓存键：`TrackCacheStore.TrackCacheID`（DownloadManager.swift:499 / TrackCacheStore.swift:16-26）
- 歌词键：`LyricsDiskCache.key`（LyricsDiskCache.swift:46-48）
- 封面键命名空间：`ArtworkStore.cacheKey`（ArtworkStore.swift:272-278）

> **Kotlin 落地**：任何持久化字典/文件命名都必须带 `serverID`。不要沿用「裸 trackID」索引（旧实现曾因此错曲播放，见 Docs/全面审计报告 P0-1）。

---

## 1. DownloadManager（离线下载）

源文件：`OfflineManager/DownloadManager.swift`

### 1.1 最大并发数 = 3（核对一致）

- 默认参数 `maxConcurrentDownloads: Int = 3`（DownloadManager.swift:271, 285），`init` 内 `max(1, …)` 兜底（DownloadManager.swift:293）。
- 限流逻辑在 `resumeNextTasks()`（DownloadManager.swift:807-829）：统计 `tasks` 中 `state == .running` 的数量，`availableSlots = maxConcurrentDownloads - runningCount`；只对 `state == .suspended && status == .queued` 的任务 `resume()`。
- **未达并发上限的任务保留为 `suspended` 的 `URLSessionDownloadTask`**，仍可被后台会话恢复/取消/展示（注释 DownloadManager.swift:805-806）。即：并发=3 是「同时传输」上限，不是「排队任务」上限。

### 1.2 任务身份（serverID + trackID，非裸 trackID）

- 运行时稳定身份 `DownloadTaskID(serverID, trackID)`（DownloadManager.swift:203-211），所有状态/回调/取消均带 serverID（注释 DownloadManager.swift:201-202）。
- 业务身份 `DownloadTaskMetadata(trackID, serverID, codec)`（DownloadManager.swift:9-29）序列化为：
  `taskDescription = "auralis.download.v1:" + base64(JSON(metadata)`（DownloadManager.swift:16-19）。
- 同时写入 `DownloadTaskMetadataStore`（UserDefaults key `com.auralis.player.download-task-metadata.v1`），用于进程被系统终止后从 `task.taskIdentifier` 恢复（DownloadManager.swift:38-150）。
- **不持久化下载 URL 或认证参数**（注释 DownloadManager.swift:36）。URL 在 `start()` 时由调用方传入，构造见 §1.3。

### 1.3 下载 URL 生成（不持久化，运行时构造）

- 调用 `OpenSubsonicClient.makeDownloadURL(trackID:)`（OpenSubsonicClient.swift:457-473）：基于 `/download` 端点，拼接认证参数（`u/t/s` 或 `apiKey`）、`id`、`v`、`c`，返回带认证的 `URL`。
- `DownloadManager.start(trackID:url:codec:serverID:)` 使用该 URL 建 `session.downloadTask(with: url)`（DownloadManager.swift:362-385）。
- 认证参数从 Keychain 读取（仅 `start` 阶段），**不落盘**；进程重启后用同一 `trackID` 重新向 connector 要 URL。

### 1.4 进度上报

- `urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)`（DownloadManager.swift:428-446）：
  - `progress = totalBytesExpectedToWrite > 0 ? written/expected : 0`（clamp 0...1）。
  - 更新 `infos[id].progress / byteCount / expectedByteCount`，`failure = nil`。
  - 通过 `onStateChange(id, info)` 回调上层（DownloadManager.swift:229, 831-836）。

### 1.5 取消

- `cancel(_ id: DownloadTaskID)`（DownloadManager.swift:387-409）：
  - 从 `tasks / taskIdentifiers / codecs / infos` 移除；`task?.cancel()`。
  - 把 `taskIdentifier` 写入 `cancelledTaskIdentifiers` 墓碑集合（上限 256，超界淘汰最旧，DownloadManager.swift:391-397）——防止 `getAllTasks` 异步快照迟到导致已取消任务被 `restore` 重新绑定成 downloading。
  - 清 `metadataStore.remove(taskIdentifier:)` 与 `removeFailure(id:)`，状态置 `.notDownloaded`。
- 旧兼容：`cancel(_ trackID:)` 取消所有匹配服务器的任务（DownloadManager.swift:412-417）；`cancelAll()`（DownloadManager.swift:419-424）。

### 1.6 失败恢复 / 重启

四类恢复路径：

1. **冷启动水合** `hydratePersistedTaskState()`（DownloadManager.swift:625-641）：从 `metadataStore` 读回失败记录（`.failed`）与持久任务（先置 `.queued`，真实 state 等 `getAllTasks` 回）。
2. **staging 文件恢复** `recoverStagedDownloads()`（DownloadManager.swift:645-701）：App 可能在「系统临时文件已交付、尚未写入缓存」的极短窗口被终止。读 `DownloadStaging/*.download`（文件名=taskIdentifier），有 metadata 则重新 `moveDownloadedFile` 落盘；无 metadata 或 0 字节则删。
3. **后台会话重连** `reconnectBackgroundTasks()` → `restore(existingTasks:pruneCandidates:)`（DownloadManager.swift:704-769）：`session.getAllTasks` 回系统任务，用 `taskDescription`/`metadataStore` 重建内存状态；**不在 `getAllTasks` 结果中、也不在恢复中的 stale 任务**标记为 `.failed`，`kind = .interrupted`，「上次下载未完成，请重试」（DownloadManager.swift:744-764）。孤儿任务（无法恢复身份）直接 `cancel`。
4. **后台完成回调** `handleEventsForBackgroundURLSession`（DownloadManager.swift:587-596）：**必须惰性访问 `session`** 触发系统重连，否则 `urlSessionDidFinishEvents` 不触发 → completion 不调用 → 挂起期完成的临时文件无法移入缓存。`takeBackgroundCompletionIfReadyLocked`（DownloadManager.swift:933-942）要求 `backgroundSessionEventsFinished && pendingCacheMoves == 0` 才交还系统 completion。

### 1.7 临时文件 → 缓存移动流程

1. `didFinishDownloadingTo`（DownloadManager.swift:448-516）：
   - `responseFailure(for:)` 先校验 HTTP 状态/MIME（详见 §2）；空文件（0 字节）判 `.invalidResponse`/`.storage`。
   - `stageTemporaryDownload`（DownloadManager.swift:855-864）：同步 `moveItem` 到 `Application Support/Auralis/DownloadStaging/{taskIdentifier}.download`（目录 `isExcludedFromBackup = true`，DownloadManager.swift:842-853）。**原因**：系统临时文件仅在 delegate 回调期有效，先同步挪到 staging 再跨 actor 异步写缓存。
2. 包装 `Task` 调 `store.moveDownloadedFile(at:stagedLocation, for:cacheID, codec:)`（DownloadManager.swift:500-515），cacheID 带 serverID（P0-1）。
3. 成功 `finishSuccess`；若因取消墓碑被拒（`wasCancelled`）则 `store.remove(for:)` 回滚（DownloadManager.swift:503-506）。
4. 失败（存储/移动异常）`finishFailure(kind: .storage)`（DownloadManager.swift:507-513）。

### 1.8 幂等与去重

- `start()` 入口 `guard taskIdentifiers[id] == nil else { return }`（DownloadManager.swift:366-369）：同 serverID+trackID 重复 `start` 直接忽略。
- `bind()`（DownloadManager.swift:771-803）：同一 serverID+trackID 只允许一个系统任务；若已存在不同 `taskIdentifier` 的活跃任务，取消迟到者（DownloadManager.swift:784-793）。
- `finishSuccess/finishFailure` 清 `taskIdentifiers[id]`、`tasks[id]`；`recoveringTaskIdentifiers` 防重复处理（DownloadManager.swift:454-457, 531, 555）。

---

## 2. DownloadError 分类（核对：与预期 8 类完全一致）

枚举 `DownloadFailureKind`（DownloadManager.swift:180-189）：`networkUnavailable / timedOut / authentication / unavailable / invalidResponse / storage / interrupted / unknown`。

映射规则（来源 `responseFailure(statusCode:mimeType:)` DownloadManager.swift:873-900 与 `failureInfo(for:)` DownloadManager.swift:902-922）：

| kind | 触发条件 | 代码位置 |
|---|---|---|
| `networkUnavailable` | `notConnectedToInternet`/`networkConnectionLost`/`cannotFindHost`/`cannotConnectToHost`/`dnsLookupFailed`/`internationalRoamingOff`/`dataNotAllowed` | DownloadManager.swift:910-912 |
| `timedOut` | `URLError.timedOut` | DownloadManager.swift:913-914 |
| `authentication` | HTTP `401/403`；或 `userAuthenticationRequired`/`userCancelledAuthentication` | DownloadManager.swift:878-879, 915-916 |
| `unavailable` | HTTP `404/410`（歌曲已不存在）；`5xx`（服务器暂不可用） | DownloadManager.swift:880-883 |
| `invalidResponse` | 其他状态码（默认分支，含 HTTP 码）；或响应 MIME 为 `json/html/xml`（非音频） | DownloadManager.swift:884-898 |
| `storage` | 下载文件 0 字节；staging 落盘失败；`moveDownloadedFile` 失败 | DownloadManager.swift:464, 472, 477-480, 507-511, 695 |
| `interrupted` | 后台会话重连时 stale 任务（未完成被系统丢弃） | DownloadManager.swift:744-764 |
| `unknown` | 无 error 或无法归类的 `NSError` | DownloadManager.swift:903-904, 921 |

> 设计要点（DownloadManager.swift:178-179）：`DownloadFailureInfo` 仅保存「面向用户的脱敏说明」（`kind + message`），**绝不**暴露带认证的 URL 或系统错误原文。Kotlin 端同样需在 Repository 层脱敏，UI 只消费 `kind`。

---

## 3. TrackCacheStore（缓存文件 / 目录 / 容量 / 查重）

源文件：`OfflineManager/TrackCacheStore.swift`（`actor`，线程安全）。

### 3.1 目录与索引

- 目录：`Application Support/Auralis/TrackCache`；索引 `index.json`（TrackCacheStore.swift:41-69）。
- `index: [String: String]`，key = `"serverID:trackID"`（`TrackCacheID.description`），value = 文件名（TrackCacheStore.swift:44, 91-101）。
- 旧版裸 TrackID 索引（无 `:`）保留不删，待 `migrateLegacyEntries(to:)` 迁移（TrackCacheStore.swift:56-88）——**不要静默丢弃已下载音频**。

### 3.2 文件命名规则

`uniqueFileName(id:codec:)`（TrackCacheStore.swift:257-268）：

```
{readable}-{fnv1a_hex}-{uuid}.{ext}
```

- `readable`：`trackID` 字母数字最长 32 字符，其余 `_`（TrackCacheStore.swift:258-261）。
- FNV-1a（偏移 14695981039346656037，素数 1099511628211）对 `"serverID:trackID"` 求哈希 → 16 进制（TrackCacheStore.swift:262-266）。真正身份由 `index` 的 GlobalID 决定，文件名只防碰撞。
- `ext` 由 `fileExtension(codec:)`（TrackCacheStore.swift:270-280）：`flac→flac`；`aac/m4a/alac→m4a`；`ogg/opus→ogg`；`wav→wav`；`aiff/aif→aiff`；默认 `mp3`。**需保证播放器按扩展名识别容器格式**。

### 3.3 容量统计

- `totalBytes()`（TrackCacheStore.swift:229-231）= `cachedEntries()` 各 `byteCount` 之和。
- `cachedEntries()`（TrackCacheStore.swift:113-136）：遍历 `index`，用文件系统 `fileSizeKey`/`contentModificationDateKey` 取值；读取时顺手剔除失效索引（文件不存在则 `index[key]=nil` 并 `persistIndex`）；按 `modifiedAt` 倒序。**大小永远以磁盘为准，不依赖内存估算**。

### 3.4 删除

- `remove(for:)`（TrackCacheStore.swift:179-193）：删文件 + 清索引 + 原子写回；失败回滚索引。
- `removeAll(forServer:)`（TrackCacheStore.swift:197-208）：按前缀 `"serverID:"` 批量删（删服务器/清本地数据用）。
- `removeAll()`（TrackCacheStore.swift:211-226）：清空所有用户下载音频；调用方需先取消活动任务（注释）。

### 3.5 查重 / 去重

- `isCached(_:)` / `cachedFileURL(for:)`（TrackCacheStore.swift:91-105）：查 `index` 得文件名 → 校验文件确实存在；**文件被外部清理则即时修复索引**，避免 UI 永久幽灵记录。
- `cachedTrackIDs()`（TrackCacheStore.swift:107-109）、`cachedEntries()` 去重依据即 `index` 键。

### 3.6 「已完整下载」判定

- 条件：① `index` 含该 `serverID:trackID`；② 对应文件存在；③ 文件字节数 > 0。
- `moveDownloadedFile` 入口 `guard sourceSize > 0 else { throw .emptyFile }`（TrackCacheStore.swift:159-161）；`store(data:)` 同理拒绝空文件（TrackCacheStore.swift:139-140）。
- **注意**：下载「完成」以 `didFinishDownloadingTo` 后成功 `moveDownloadedFile` 为准，状态 `.downloaded` 才标记成功（DownloadManager.swift:520-537）。

---

## 4. CachePolicy（重要：与任务预期不符，需澄清）

源文件：`OfflineManager/CachePolicy.swift`。**实际内容不含「自动下载条件 / 容量上限 / 蜂窝下载开关」**。该文件仅含：

- `CacheEntry`（CachePolicy.swift:4-16）：`id: TrackID, byteCount, lastAccessedAt, isPinced`。
- `CacheEvictionPolicy.evictions(entries:currentBytes:targetBytes:)`（CachePolicy.swift:18-30）：**LRU 淘汰**——仅对 `!isPinned` 的条目按 `lastAccessedAt` 升序累加，直到释放 `currentBytes - targetBytes`。这是通用缓存淘汰算法，非离线下载专用。
- `DownloadStateStore`（CachePolicy.swift:32-38）：`actor` 内存 `[TrackID: DownloadRecord]` 记录存储。

### 4.1 任务预期规则的真实落点

- **容量上限 / 清理策略**：离线音频缓存本身**没有**自动容量上限逻辑（TrackCacheStore 无上限清理）。仅有 `CacheEvictionPolicy` LRU 模板（按需被调用方集成）与歌词缓存的 64MB 预算（见 §6）。Kotlin 端如需「离线缓存上限自动清理」，需自行在 DownloadManager 层实现（建议：参考 `CacheEvictionPolicy` 的 LRU + `isPinned` 跳过）。
- **蜂窝网络是否允许下载**：**代码中无显式蜂窝门控**。`DownloadManager` 用后台 `URLSession`（DownloadManager.swift:236-243, session id `com.auralis.player.downloads`），下载不检查网络类型，蜂窝下也照常进行。
- **蜂窝 / 质量策略的位置**：实际在 `Application/StreamQualityPolicy.swift`——仅作用于**流播放**质量：`isCellular()` 来自 `NetworkPath`（NWPathMonitor），蜂窝下 `cellularTranscodingAllowed` 为真则 `maxBitRate=320` 转码 MP3，否则原始质量；Wi-Fi 下 `highQualityOnWiFi` 控制（StreamQualityPolicy.swift:64-98）。`NetworkInterfaceType` 枚举（wifi/cellular/ethernet/other/unknown）见 StreamQualityPolicy.swift:7-13。
- **自动下载条件**：代码中未发现「按规则自动触发下载」（如 Wi-Fi 下自动缓存某列表）。下载均为用户显式 `start()` 触发。

> **结论**：CachePolicy.swift 在本仓库是「LRU 淘汰模板 + 下载状态内存存储」，并非离线下载的总控策略。Android 实现若需「自动下载 / 蜂窝开关 / 容量软上限」，应新增对应 Policy 模块并接线到 DownloadManager，而非照搬此文件。

---

## 5. 播放优先本地缓存（无 PlaybackSourceResolver 类，实为 resolvePlayableTrack）

源文件：`AppShell/AuralisAppModel.swift:3026-3054`

> 代码中**不存在名为 `PlaybackSourceResolver` 的类型**。唯一的可播放解析入口是 `resolvePlayableTrack(_:forceRefresh:)`，逻辑如下：

```
private func resolvePlayableTrack(_ track, forceRefresh: Bool = false) async -> Track? {
    // ① 本地下载优先
    if let localURL = await cacheStore.cachedFileURL(for: cacheID(for: track)) {
        var playable = track
        playable.streamURL = localURL
        return playable                       // AuralisAppModel.swift:3030-3036
    }
    // ② 复用仍可用的既有 URL（非强制刷新）
    if !forceRefresh, track.streamURL != nil { return track }   // :3037-3039
    // ③ 跨服务器安全：非活动服务器曲目不得用活动连接器刷新
    guard track.serverID == catalog.activeServerID else {
        return track.streamURL == nil ? nil : track            // :3042-3044
    }
    if let refreshedURL = await connector.refreshStreamURL(serverID: track.serverID, trackID: track.id) {
        playable.streamURL = refreshedURL; return playable     // :3045-3050
    }
    return track.streamURL == nil ? nil : track                 // :3053
}
```

- `cacheID(for:)` = `TrackCacheStore.TrackCacheID(serverID: track.serverID, trackID: track.id)`（AuralisAppModel.swift:3019-3022），与离线键逐字节一致。
- **离线落到本地文件**：命中即把 `streamURL` 设为 `cacheStore.cachedFileURL` 返回的本地文件 URL（AuralisAppModel.swift:3030-3032）。日志仅记「使用本地缓存播放」，不写完整路径（隐私，:3033-3034）。
- 跨服务器保护（P0-1/P1-1，:3040-3044）：旧服务器同 TrackID 不会因活动连接器刷新而被解析成新服务器音频；本地缓存与既有 URL 仍可用。
- 同一组合键也用于下载页：`AppDomainStores.cacheID(for:)`（AppDomainStores.swift:537-539）、`downloadedEntry(for:)`（AuralisAppModel.swift:3382-3384）。

> **Kotlin 落地**：实现 `resolvePlayableTrack(track, forceRefresh)` 同名语义——本地缓存 > 既有 URL > 服务器刷新（带 server 校验）。下载的本地文件 URL 即播放源。

---

## 6. 歌词（获取顺序 / 解析 / 存储 / 翻译）

### 6.1 获取顺序（fetchLyrics）

源文件：`Application/ProductionServerConnector.swift:395-411`

```
1. client.structuredLyrics(trackID: track.id)        // getLyricsBySongId, 带 enhanced 标志
2. 若结构化结果非空：
     优选 isSynced && !lines.isEmpty 的文档；否则第一个 !lines.isEmpty 的文档
3. 若结构化为空 → 回退 client.traditionalLyrics(artist:title:)  // getLyrics (artist+title)
```

- 路由到 `track.serverID` 对应 client（R01，ProductionServerConnector.swift:396, 394）。
- 结构化 `lyricsList` 为空 ≠ 错误：返回 `[]`，由调用方决定回退或记「无歌词」（OpenSubsonicClient.swift:488-493）。
- 服务器明确无歌词（traditional 也空/value 空）→ 返回 `nil`，调用方标记无歌词状态（ProductionServerConnector.swift:389-391, 522-524）。

### 6.2 结构化歌词解析（getLyricsBySongId）

`OpenSubsonicClient.structuredLyrics`（OpenSubsonicClient.swift:481-507）：

- `lyrics.lang` → `LyricsDocument.language`。
- 每行 `line`：`start`（毫秒）→ `TimedLyricLine.startTime = start / 1000`（秒）；`value` → `text`。
- `lyrics.synced ?? false` → `isSynced`。
- 模型 `LyricsDocument(trackID, language, lines, isSynced)`（Models.swift:442-454）；`TimedLyricLine(startTime, text, translation?)`（Models.swift:429-440）。

### 6.3 传统歌词解析（getLyrics artist+title）

`OpenSubsonicClient.traditionalLyrics`（OpenSubsonicClient.swift:512-529）：

- `artist`/`title` 先 `trimmingCharacters`，任一为空返回 `nil`。
- `response.lyrics?.value` 按 `\n` 切分 → 每行一个 `TimedLyricLine(text:)`，无时间轴（`isSynced = false`, `language = nil`）。

### 6.4 LRC / 解析规则要点

- **无独立 LRC 解析文件**：结构化歌词时间轴直接来自 API（`line.start` 毫秒）。传统歌词为纯文本按行。
- **无内嵌 LRC 文本解析器**（grep `.lrc` / `parseLRC` 无命中）。若 Android 需支持服务器返回的 LRC 文本，需自行补 `[mm:ss.xx]text` 解析；当前 Apple 端不走此路径。

### 6.5 本地存储（LyricsDiskCache）

源文件：`LyricsKit/LyricsDiskCache.swift`（`actor`）

- 目录：`Application Support/Auralis/LyricsCache`；负缓存 `misses.json`（LyricsDiskCache.swift:34-44）。
- 键 `key(serverID, trackID) = "serverID:trackID"`（LyricsDiskCache.swift:46-48）。
- 文件名：`fileName`（LyricsDiskCache.swift:311-320）——对 `"serverID:trackID"` 做**无损 percent-encoding**（保留字母数字与 `-._~:`），加 `.json`。保留 `:` 前缀以便按服务器前缀清理。
- 读取：`document(forServer:trackID:)`（LyricsDiskCache.swift:53-57）：`Data(contentsOf:)` → `JSONDecoder.decode(LyricsDocument)`。
- 写入：`store(_:forServer:trackID:)`（LyricsDiskCache.swift:66-86）：`JSONEncoder` + `.atomic` 写；维护 `fileSizes`/`knownTotalBytes` 账本（O(1) 增量）；写成功后清对应 misses 负缓存。
- **负缓存（无歌词）**：`markMissing` 记 `misses["serverID:trackID"] = .now`（LyricsDiskCache.swift:89-96）；`isKnownMissing` 避免重复请求（LyricsDiskCache.swift:60-63）。按服务器隔离（P0-2），否则 A 的「无歌词」会误伤 B 同 ID。
- 容量预算：`maxTotalBytes = 64MB`（LyricsDiskCache.swift:25），超预算按文件大小从大到小淘汰（LyricsDiskCache.swift:192-215）。`maxMissesCount = 20000`，超则裁剪最旧一半（LyricsDiskCache.swift:219-226）。
- 按服务器清理：`removeAll(forServer:)`（LyricsDiskCache.swift:256-283）按前缀删文件 + 负缓存。
- 迁移兼容：`migrateLegacyEntries` / `migrateLegacyFilenames`（LyricsDiskCache.swift:101-165）。

### 6.6 翻译行处理

- 模型 `TimedLyricLine.translation: String?`（Models.swift:433）保留每行翻译字段。
- **当前服务端映射未填充 `translation`**：`structuredLyrics` 只取 `line.value`（OpenSubsonicClient.swift:498-503），`traditionalLyrics` 同样只填 `text`。即 Apple 端翻译字段为预留能力，**无填充逻辑、无合并逻辑**。
- 推断：多语言翻译以「另一条带不同 `language` 的 `LyricsDocument`」形式存在（OpenSubsonic `structuredLyrics` 可含多语言数组），当前 `fetchLyrics` 只返回**首选一条**（ProductionServerConnector.swift:401-402），未做跨语言合并到每行 `translation`。
- 当前行辅助：`LyricTimeline.currentLine(in:at:)`（LyricsRepository.swift:9-13）按 `startTime <= time` 取最后一行，用于歌词跟随高亮。

> **Kotlin 落地建议**：若需逐行翻译，需扩展 `structuredLyrics` 映射（如某些服务器 `line` 含翻译子字段）或在 `fetchLyrics` 中按 `language` 合并多文档填充 `translation`；否则仅照搬现有结构即可保证行为一致。

---

## 7. 封面 ArtworkView（请求 / 缓存键 / 占位 / 尺寸）

源文件：`AppShell/ArtworkView.swift` + `AppShell/ArtworkStore.swift`

### 7.1 请求方式（getCoverArt + size）

- 网络请求：`OpenSubsonicClient.coverArt(id:size:)`（OpenSubsonicClient.swift:429-439）→ `/getCoverArt`，`size` 参数范围 `1...4096`（越界抛错）。
- 加载入口：`ArtworkStore.load(remoteKey:targetPixelSize:serverID:)`（ArtworkStore.swift:129-183）；先查内存（thumbnails/fullSizeImages NSCache），再走 `ArtworkPipeline`（磁盘 + 网络 + ImageIO 下采样）。
- `ArtworkView.body.task(id: requestIdentifier)`（ArtworkView.swift:97-115）：先 `image(...)` 同步取内存；`nil` 则 `await load(...)`。

### 7.2 缓存 key 组成（含 serverID）

- `cacheKey = "\(namespace)|\(remoteKey)@\(targetPixelSize)"`（ArtworkStore.swift:272-278）。
- `namespace` = serverID（无则 `"local"`，ArtworkStore.swift:265-270, 235-237）——**含 serverID → 多服务器同名封面不串扰（R01）**。
- `remoteKey` = `artworkKey`（来自 `Track.artworkKey`，即 coverArt id）。
- 播放器封面显式传 `currentTrack.serverID`（ArtworkView.swift:54-56 注释，ArtworkStore.swift:123-128）：播放 A、浏览 B 时 A 的封面仍从 A 回源，且缓存键落 A 命名空间。

### 7.3 尺寸规格

- 请求像素：`requestedPixelSize = max(64, Int(size * displayScale))`（ArtworkView.swift:64-66）。
- 量化档位 `normalizedPixelSize`（ArtworkView.swift:70-73）：`[64,96,160,256,384,512,768,1024,1536,2048]`，**向上取整**（Retina 宁高勿低），减少尺寸微调造成的 cache miss。
- `targetPixelSize` 最终 clamp `1...4096`（ArtworkStore.swift:131）。
- `fallbackPixelSize = 256`（ArtworkStore.swift:32）：渐进式预缓存磁盘回退尺寸。
- 内存配置（ArtworkStore.swift:20-29）：thumbnails 64MB/480 张；fullSize 48MB/24 张；`fullSizeThreshold=512`（≥512 进 fullSize 缓存）；unavailable 负缓存 2048。

### 7.4 占位策略

- 占位组件由 `placeholderStyle` 决定（ArtworkView.swift:118-126）：
  - `.auralis`（iOS 默认 `platformDefault`）：`AuralisArtwork`（渐变 + 标题占位，ArtworkView.swift:121-122）。
  - `.macMusic`（Mac）：`MacArtworkPlaceholder` 浅灰方块 + 中央 `music.note`（ArtworkView.swift:124, 131-146）。
- 加载中/无封面 → 直接显示占位（ArtworkView.swift:83-95），加载完成淡入（`.transition(.opacity)`）。
- 失败记录：`markUnavailable(key)` 写入 unavailable 负缓存，避免重复网络请求（ArtworkStore.swift:110-112, 191-193）；`clearUnavailable()` 在同库刷新后允许重试（ArtworkStore.swift:220-222）。

---

## 8. Android 落地清单（速查）

| 链路 | 必做 |
|---|---|
| 下载 | `maxConcurrent=3`（传输并发，非排队上限）；任务身份=`serverID:trackID`；URL 运行时构造不持久化；staging 目录 + 原子移入；取消墓碑防重绑；后台会话重连恢复 stale→`.interrupted` |
| 错误 | 8 类 `DownloadFailureKind` 对齐；UI 仅消费 `kind`+脱敏 `message` |
| 缓存 | 目录 `TrackCache/TrackCache`，`index.json` key=`serverID:trackID`；文件名 FNV-1a+UUID+codec 扩展名；容量以磁盘为准；删除支持 `forServer:` |
| 策略 | 注意 CachePolicy.swift 仅 LRU 模板；蜂窝/容量上限需新增 Policy 接线 DownloadManager（当前下载无蜂窝门控，质量门控在 StreamQualityPolicy 且只管流播） |
| 播放优先 | 实现 `resolvePlayableTrack`：本地文件 > 既有 URL > 服务器刷新（带 server 校验） |
| 歌词 | 顺序：`getLyricsBySongId` → 空则 `getLyrics(artist+title)`；结构化 ms/1000 转秒；磁盘 `LyricsCache` 含 misses 负缓存 + 64MB 预算；翻译字段预留未填充 |
| 封面 | `getCoverArt(id, size 1..4096)`；key=`namespace\|remoteKey@size`，namespace=serverID；档位 64→2048 向上取整；占位渐变/音符 |

---

## 引用文件清单

- `OfflineManager/DownloadManager.swift`
- `OfflineManager/TrackCacheStore.swift`
- `OfflineManager/CachePolicy.swift`
- `AppShell/ArtworkView.swift` / `ArtworkStore.swift` / `ArtworkPipeline.swift`（封面管线）
- `AppShell/AuralisAppModel.swift`（resolvePlayableTrack、cacheID、downloadedEntry）
- `AppShell/AppDomainStores.swift`（cacheID、cachedEntry）
- `OpenSubsonicKit/OpenSubsonicClient.swift`（makeDownloadURL / coverArt / structuredLyrics / traditionalLyrics）
- `Application/ProductionServerConnector.swift`（fetchLyrics 编排）
- `Application/StreamQualityPolicy.swift`（蜂窝/质量，非下载）
- `LyricsKit/LyricsDiskCache.swift` / `LyricsRepository.swift`
- `Domain/Models.swift`（LyricsDocument / TimedLyricLine）
