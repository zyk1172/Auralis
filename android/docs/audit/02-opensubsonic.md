# Auralis OpenSubsonic 网络层审计规格报告

> 目标：为 Apple（Swift）Auralis → Android（Kotlin）原生迁移提供可直接落地的网络层规格。
> 所有结论均引用真实源码，未做任何猜测。
> 源文件：`Packages/AuralisCore/Sources/OpenSubsonicKit/{OpenSubsonic.swift, OpenSubsonicClient.swift, Models.swift, Authentication.swift}`
> 以及 `Packages/AuralisCore/Sources/Application/{StreamQualityPolicy.swift, ApplicationComposition.swift, OpenSubsonicLibrarySyncSource.swift}`。

---

## 1. 协议基础

### 1.1 Base path 拼接规则
所有请求统一为 **POST `application/x-www-form-urlencoded`**，即使只读操作也是 POST（见 `OpenSubsonic.swift:6-7` 注释）。URL 由 `endpointURL(baseURL:endpoint:)` 构造（`OpenSubsonic.swift:329-346`）：

```swift
public static func endpointURL(baseURL: URL, endpoint: OpenSubsonicEndpoint) throws -> URL {
    guard
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
        let scheme = components.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        components.host != nil
    else {
        throw OpenSubsonicClientError.invalidBaseURL
    }

    var path = components.path
    if path.hasSuffix("/") { path.removeLast() }
    components.path = "\(path)/rest/\(endpoint.rawValue).view"   // 关键拼接
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw OpenSubsonicClientError.invalidBaseURL }
    return url
}
```

- 拼接格式：`<scheme>://<host>[:port]<basePath>/rest/<endpoint>.view`
- `endpoint.rawValue` 即 `OpenSubsonicEndpoint` 枚举的 case 名（见 1.4）。
- 若 `baseURL` 无 scheme/http(s)/无 host → 抛 `invalidBaseURL`。
- 注意：`baseURL` 的 query/fragment 被忽略（`components.query = nil`）。

### 1.2 client 名称与 API 版本参数
由 `makeURLRequest`（`OpenSubsonicClient.swift:605-644`）注入，全局保留参数 `c` / `v` / `f`：

```swift
let global = Set(["c", "v", "f"])
var items = descriptor.parameterItems.filter { !global.contains($0.name.lowercased()) }
items.append(.init("c", configuration.clientName))
items.append(.init("v", configuration.protocolVersion))
items.append(.init("f", "json"))
items.append(contentsOf: try await authenticationParameters())
```

- `c` = `configuration.clientName`，默认值 `"Auralis"`（`OpenSubsonic.swift:98` `init` 默认参数 `clientName: String = "Auralis"`）。
- `v` = `configuration.protocolVersion`，默认值 `"1.16.1"`（`OpenSubsonic.swift:99`）。
- `f` = `"json"`（请求工厂也会重复加一次，见 1.5）。
- 关键约束（`OpenSubsonicClient.swift:619-622`）：调用方**禁止**在参数里传入保留认证字段 `u` / `p` / `t` / `s` / `apikey`，否则抛 `invalidParameter("authentication")`。

请求头设置（`:640-641`）：
```swift
request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
request.setValue("application/json, application/octet-stream;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
```
`cachePolicy = .reloadIgnoringLocalCacheData`，`timeoutInterval = configuration.requestTimeout`（默认 30s）。

### 1.3 响应信封格式
外层由 `OpenSubsonicEnvelope` 解码（`Models.swift:145-151`）：

```swift
struct OpenSubsonicEnvelope: Decodable {
    let response: OpenSubsonicResponseDTO
    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}
```

`OpenSubsonicResponseDTO`（`Models.swift:153-177`）：

```swift
struct OpenSubsonicResponseDTO: Decodable {
    let status: String?
    let version: String?
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: OpenSubsonicErrorDTO?
    // ... 各 endpoint 数据字段（见第 3/4 节）
}
```

- 信封根键为 `subsonic-response`。
- `status`：期望小写 `"ok"`，否则视为失败（`OpenSubsonicClient.swift:758-765` `validate`）。
- `version` / `type` / `serverVersion`：服务器协议版本、类型（如 `navidrome`）、具体版本号，由 `serverInfo()` 取出（`:108-116`）。
- `openSubsonic`：Bool，标记是否 OpenSubsonic 服务器；`serverInfo` 中以 `response.openSubsonic ?? false` 读取。
- `error`：结构见 1.4。

错误结构 `OpenSubsonicErrorDTO`（`Models.swift:179-191`）：
```swift
struct OpenSubsonicErrorDTO: Decodable {
    let code: Int
    let message: String?
    let helpUrl: String?
    var domainValue: OpenSubsonicServerError {
        OpenSubsonicServerError(code: code, message: message ?? "Server request failed", helpURL: helpUrl.flatMap(URL.init(string:)))
    }
}
```

### 1.4 Endpoint 枚举（`.view` 路径名）
`OpenSubsonicEndpoint`（`OpenSubsonic.swift:8-45`）—— 即实际 URL 的 `<endpoint>` 部分：

```swift
case ping
case getOpenSubsonicExtensions
case getMusicFolders
case getArtists
case getArtist
case getAlbum
case getSong
case getGenres
case getAlbumList2
case getRandomSongs
case getStarred2
case search3
case getPlaylists
case getPlaylist
case createPlaylist
case updatePlaylist
case deletePlaylist
case stream
case download
case getCoverArt
case getLyrics
case getLyricsBySongId
case star
case unstar
case setRating
case scrobble
case getPlayQueue
case savePlayQueue
case getPlayQueueByIndex
case savePlayQueueByIndex
case reportPlayback
case getSimilarSongs2
case getSonicSimilarTracks
case findSonicPath
case getTranscodeDecision
case getTranscodeStream
```

**注意（可疑点 A）**：`getPlayQueueByIndex` / `savePlayQueueByIndex` / `reportPlayback` / `getSonicSimilarTracks` / `findSonicPath` / `getTranscodeDecision` / `getTranscodeStream` 在枚举中声明、且出现在 retry 策略的“不可重试”列表里（`:776-778`），但 **`OpenSubsonicClient` 没有任何对应方法实现**。Android 端需确认这些 endpoint 是否真正需要（很可能为预留/未接线能力）。

---

## 2. 认证

认证模式由 `OpenSubsonicAuthentication` 配置（无密码明文常驻，`OpenSubsonic.swift:82-85`）：

```swift
public enum OpenSubsonicAuthentication: Hashable, Sendable {
    case token(username: String, credentialID: CredentialID)
    case apiKey(credentialID: CredentialID)
}
```

凭据实际值通过 `CredentialVault.retrieve(id:)` 从 Keychain 异步读取（`OpenSubsonicClient.swift:701-724` `authenticationParameters`）。

### 2.1 token + salt 算法（密码 + salt 的 MD5，小写十六进制）

**逐字引用 token 生成源码（`Authentication.swift:3-9`）：**
```swift
public enum OpenSubsonicTokenSigner {
    /// Generates the lowercase MD5 token required by Subsonic 1.13+.
    /// The password is consumed in memory and is never retained or logged.
    public static func token(password: String, salt: String) -> String {
        MD5.hexDigest(Data((password + salt).utf8))
    }
}
```

要点（精确）：
- 输入顺序：**先 password 再 salt，直接字符串拼接** `password + salt`，无分隔符。
- 编码：UTF-8 字节。
- 哈希：标准 MD5（自实现于 `Authentication.swift:37-146`，与系统实现语义一致）。
- 输出格式：`hexDigest` 输出**小写**十六进制（`:139` `String(format: "%02x", $0)`）。

salt 生成器（`OpenSubsonicClient.swift:23-25`，默认实现）：
```swift
saltGenerator: @escaping SaltGenerator = {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}
```
- 默认 salt = 去横线小写 UUID（32 字符，满足 ≥6 字符约束）。
- 约束（`OpenSubsonicClient.swift:709-711`）：`salt.count >= 6`，否则抛 `invalidConfiguration("salt must have at least six characters")`。

token 模式请求参数（`:712-716`）：
```
u = username
t = <小写 MD5(password + salt)>
s = salt
```

### 2.2 apiKey 模式

`apiKey` 模式（`:717-722`）：
```swift
case let .apiKey(credentialID):
    let apiKey = try await credentialVault.retrieve(id: credentialID)
    guard !apiKey.isEmpty else {
        throw OpenSubsonicClientError.invalidConfiguration("API key is empty")
    }
    return [.init("apiKey", apiKey)]
```
- 参数名：`apiKey`（单参数）。
- apiKey 也不得为空。

### 2.3 plaintextPassword 是否支持

**不支持。** `OpenSubsonicAuthentication` 仅两种情形：`.token` 与 `.apiKey`。没有 `.password`/`plaintext` 分支，也没有在 `authenticationParameters` 中拼装 `p=...` 明文参数（保留字 `p` 仅作为“禁止传入”的保留字段出现在 `:619`）。即 Auralis **从不发送明文密码**，仅 MD5 token 或 apiKey。

### 2.4 参数名汇总

| 模式 | 参数名 | 取值 |
|------|--------|------|
| token | `u` | 用户名 |
| token | `t` | `md5(password + salt)` 小写十六进制 |
| token | `s` | salt（≥6 字符） |
| apiKey | `apiKey` | API key 字符串 |

外加全局参数 `c` / `v` / `f=json`（见 1.2）。

### 2.5 表单编码（POST body）
`OpenSubsonicFormEncoder.encode`（`Authentication.swift:11-35`）：

```swift
static func encode(_ items: [OpenSubsonicParameter]) -> Data {
    let value = items
        .map { "\(escape($0.name))=\(escape($0.value))" }
        .joined(separator: "&")
    return Data(value.utf8)
}
```

转义规则（`escape`，`:19-34`）：
- 保留字符（不转义）：`A-Z a-z 0-9 - . _ ~`（ASCII 0x41–0x5A, 0x61–0x7A, 0x30–0x39, 0x2D, 0x2E, 0x5F, 0x7E）。
- 空格 `0x20` → `+`。
- 其它字节 → `%XX`（**大写** 十六进制，`String(format: "%%%02X", byte)`）。
- 注意：此编码**不是标准** `percent-encoding`（标准应把空格转成 `%20` 而非 `+`，且标准允许更多保留字符）。Android 端需**逐字复刻**该转义，避免签名/解码不一致。

---

## 3. 完整 endpoint 清单（OpenSubsonicClient 已实现方法）

> HTTP 方法统一 POST（`makeURLRequest` 强制 POST，其它方法抛 `invalidConfiguration("Only form POST is supported")`）。返回 DTO 指经 `mapper` 映射后的 Domain 类型；原始 DTO 见第 4 节。

| # | 方法 | 对应 endpoint | 参数 | 返回 |
|---|------|--------------|------|------|
| 1 | `ping()` | `.ping` | 无 | `Void`（内部走 `serverInfo`） |
| 2 | `serverInfo()` | `.ping` | 无 | `OpenSubsonicServerInfo` |
| 3 | `extensions()` | `.getOpenSubsonicExtensions` | 无 | `[OpenSubsonicExtension]` |
| 4 | `capabilities()` | `.getOpenSubsonicExtensions` | 无 | `ServerCapabilities`（经 CapabilityRegistry） |
| 5 | `musicFolders()` | `.getMusicFolders` | 无 | `[OpenSubsonicMusicFolder]` |
| 6 | `artists(musicFolderID:)` | `.getArtists` | `musicFolderId?` | `[Artist]` |
| 7 | `artist(id:)` | `.getArtist` | `id` | `OpenSubsonicArtistDetail` |
| 8 | `album(id:)` | `.getAlbum` | `id` | `OpenSubsonicAlbumDetail` |
| 9 | `song(id:)` | `.getSong` | `id` | `Track` |
| 10 | `genres()` | `.getGenres` | 无 | `[Genre]` |
| 11 | `albums(type:size:offset:fromYear:toYear:genre:musicFolderID:)` | `.getAlbumList2` | `type,size,offset,fromYear?,toYear?,genre?,musicFolderId?` | `[Album]` |
| 12 | `randomSongs(size:genre:fromYear:toYear:musicFolderID:)` | `.getRandomSongs` | `size,genre?,fromYear?,toYear?,musicFolderId?` | `[Track]` |
| 13 | `starred(musicFolderID:)` | `.getStarred2` | `musicFolderId?` | `OpenSubsonicStarred` |
| 14 | `search(query:artistCount:artistOffset:albumCount:albumOffset:songCount:songOffset:musicFolderID:)` | `.search3` | `query,artistCount,artistOffset,albumCount,albumOffset,songCount,songOffset,musicFolderId?` | `OpenSubsonicSearchResult` |
| 15 | `playlists(username:)` | `.getPlaylists` | `username?` | `[Playlist]`（过滤 folderLike） |
| 16 | `playlist(id:)` | `.getPlaylist` | `id` | `OpenSubsonicPlaylistDetail` |
| 17 | `createPlaylist(name:trackIDs:)` | `.createPlaylist` | `name`，重复 `songId` | `OpenSubsonicPlaylistDetail` |
| 18 | `updatePlaylist(id:name:comment:isPublic:appendTrackIDs:removeIndexes:)` | `.updatePlaylist` | `playlistId,name?,comment?,public?,songIdToAdd*,songIndexToRemove*` | `Void` |
| 19 | `deletePlaylist(id:)` | `.deletePlaylist` | `id` | `Void` |
| 20 | `star(_:)` | `.star` | `id` / `albumId` / `artistId`（依 target） | `Void` |
| 21 | `unstar(_:)` | `.unstar` | `id` / `albumId` / `artistId` | `Void` |
| 22 | `setRating(_:trackID:)` | `.setRating` | `id, rating` | `Void` |
| 23 | `coverArt(id:size:)` | `.getCoverArt` | `id, size?` | `Data`（二进制） |
| 24 | `stream(trackID:maxBitRate:format:estimateContentLength:timeOffset:)` | `.stream` | `id,maxBitRate?,format?,estimateContentLength?,timeOffset?` | `Data`（二进制音频） |
| 25 | `download(trackID:)` | `.download` | `id` | `Data`（二进制音频） |
| 26 | `structuredLyrics(trackID:enhanced:)` | `.getLyricsBySongId` | `id, enhanced` | `[LyricsDocument]` |
| 27 | `traditionalLyrics(artist:title:trackID:)` | `.getLyrics` | `artist, title` | `LyricsDocument?` |
| 28 | `scrobble(trackIDs:times:submission:)` | `.scrobble` | `id*`（可重复）, `time*`, `submission` | `Void` |
| 29 | `playQueue()` | `.getPlayQueue` | 无 | `OpenSubsonicPlayQueue` |
| 30 | `savePlayQueue(trackIDs:currentTrackID:positionMilliseconds:)` | `.savePlayQueue` | `id*`, `current?`, `position?` | `Void` |
| 31 | `similarSongs(trackID:count:)` | `.getSimilarSongs2` | `id, count` | `[Track]` |

附带 URL 构造方法（非 API 调用，返回供播放器/下载器直接使用的完整 URL）：
- `makeStreamURL(trackID:maxBitRate:format:)` → stream URL（含 auth 查询参数，`OpenSubsonicClient.swift:45-58` + `streamURL` `:87-106`）。
- `makeStreamURLs(trackIDs:...)` → `[String: URL]`（批量）。
- `makeDownloadURL(trackID:)` → download URL（`:457-473`）。

### 3.1 关键参数约束（来自源码）
- `albums`：`size ∈ 1...500`，`offset ≥ 0`；`type == .byYear` 必须同时给 `fromYear`/`toYear`；`type == .byGenre` 必须给非空 `genre`（`:221-228`）。
- `randomSongs`：`size ∈ 1...500`（`:256`）。
- `search3`：`artistCount/albumCount/songCount ∈ 0...500`，各 offset ≥ 0（`:298-307`）。
- `coverArt`：`size ∈ 1...4096`（`:433`）。
- `updatePlaylist`：`removeIndexes` 每项 ≥ 0（`:388`）。
- `setRating`：`rating ∈ 0...5`（`:420`）。
- `similarSongs`：`count ∈ 1...500`（`:580`）。
- 所有带 `id` 的方法要求非空（`:156, :174, :192, :356` 等 `requireNonEmpty`）。

### 3.2 重复参数（必须用有序参数列表，不能折叠成 Map）
- `createPlaylist`：`songId` 可重复（`:368-369`）。
- `updatePlaylist`：`songIdToAdd`、`songIndexToRemove` 可重复（`:396-397`）。
- `scrobble`：`id`、`time` 可重复（`:540-543`）。
- `savePlayQueue`：`id` 可重复（`:568`）。
- `star`/`unstar`：根据 target 选用 `id` / `albumId` / `artistId`（`:136-142`）。

`OpenSubsonicRequestDescriptor.parameters` 的字典视图会丢弃重复（取最后一个），需要保留顺序/重复时必须用 `parameterItems`（`OpenSubsonic.swift:162-169` 注释明确说明）。

### 3.3 流式/二进制响应
`stream`/`download`/`coverArt` 调用 `execute`（返回原始 `Data`），**不经** JSON 信封解析。`execute` 对 200-299 直接返回 body（`OpenSubsonicClient.swift:661-678`）。`coverArt`/`download`/`stream` 返回的 `Data` 即为二进制文件内容。

---

## 4. DTO 结构（Models.swift 原始解码类型）

> 所有字段 `let`，可缺省（除特别标注）。ID 类用 `FlexibleString`（兼容 Int/String/Double 的 JSON，`Models.swift:6-21`），访问其 `.value: String`。

### 4.1 FlexibleString
```swift
struct FlexibleString: Decodable, Hashable, Sendable {
    let value: String   // 优先 String；否则 Int/Double 转 String；否则 ""
}
```

### 4.2 信封 / 响应 / 错误
见 1.3。补充字段（DTO 顶层额外）：`status, version, type, serverVersion, openSubsonic, error` + 各 endpoint 的容器字段（`musicFolders, artists, artist, album, song, genres, albumList2, randomSongs, starred2, searchResult3, playlists, playlist, lyricsList, lyrics, playQueue, similarSongs2`）。

### 4.3 MusicFolderDTO
```swift
struct MusicFolderDTO: Decodable {
    let id: FlexibleString
    let name: String
}
```

### 4.4 ArtistDTO
```swift
struct ArtistDTO: Decodable {
    let id: FlexibleString
    let name: String?
    let albumCount: Int?
    let coverArt: String?
    let album: [AlbumDTO]?
    let starred: String?
    let userRating: Int?
}
```
容器：`ArtistsDTO { ignoredArticles: String?; index: [ArtistIndexDTO]? }`，`ArtistIndexDTO { name: String?; artist: [ArtistDTO]? }`。

### 4.5 AlbumDTO
```swift
struct AlbumDTO: Decodable {
    let id: FlexibleString
    let name: String?
    let title: String?
    let album: String?
    let artist: String?
    let artistId: FlexibleString?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let songCount: Int?
    let song: [SongDTO]?
    let starred: String?
    let userRating: Int?
}
```
容器：`AlbumsDTO { album: [AlbumDTO]? }`。

### 4.6 SongDTO（核心曲目）
```swift
struct SongDTO: Decodable {
    let id: FlexibleString
    let title: String?
    let name: String?
    let artist: String?
    let artistId: FlexibleString?
    let album: String?
    let albumId: FlexibleString?
    let duration: Double?          // 注意：Double 秒
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let genres: [ItemGenreDTO]?    // OpenSubsonic 1.16 多重 genre
    let coverArt: String?
    let suffix: String?            // 如 "mp3"
    let contentType: String?       // 如 "audio/mpeg"
    let bitRate: Int?
    let bitDepth: Int?
    let samplingRate: Int?
    let channelCount: Int?
    let starred: String?
    let userRating: Int?
    let replayGain: ReplayGainDTO?
}
```
容器：`SongsDTO { song: [SongDTO]? }`。

### 4.7 ReplayGainDTO
```swift
struct ReplayGainDTO: Decodable {
    let trackGain: Double?
    let albumGain: Double?
    let trackPeak: Double?
    let albumPeak: Double?
    let baseGain: Double?
    let fallbackGain: Double?
}
```

### 4.8 ItemGenreDTO（OpenSubsonic 多重 genre，兼容字符串与对象）
```swift
struct ItemGenreDTO: Decodable {
    let name: String?
    let value: String?
    // 兼容：若 JSON 为纯字符串，则 name=value=该字符串
    var displayValue: String? { name ?? value }
}
```

### 4.9 GenreDTO
```swift
struct GenreDTO: Decodable {
    let songCount: Int?
    let albumCount: Int?
    let value: String          // 必填
}
```
容器：`GenresDTO { genre: [GenreDTO]? }`。
Domain 映射（`OpenSubsonicClient.swift:207-209`）：`Genre(name: value.value, songCount: value.songCount ?? 0)`。

### 4.10 PlaylistDTO
```swift
struct PlaylistDTO: Decodable {
    let id: FlexibleString
    let name: String?
    let comment: String?
    let songCount: Int?
    let created: String?        // ISO-8601
    let changed: String?        // ISO-8601，映射为 modifiedAt
    let entry: [SongDTO]?
    let readonly: Bool?         // R06 OpenSubsonic readonly=true
    let validUntil: String?     // IS 扩展只读歌单过期时间
}
```
容器：`PlaylistsDTO { playlist: [PlaylistDTO]? }`。

`PlaylistDTO.isFolderLike` 过滤规则（`Models.swift:368-374`）：**仅当** 整批响应中至少有一个条目携带 `songCount/created/changed` 之一（即服务器按规范给真实歌单带元数据）时，才把三者全缺的条目当伪歌单丢弃；若整批都没有这些字段则不过滤（避免误杀只返回 id/name/comment 的小众服务器）。**绝不**按名称猜测。

### 4.11 Lyrics
```swift
struct LyricsDTO: Decodable {       // 传统 getLyrics（artist + title）
    let artist: String?
    let title: String?
    let value: String?              // 纯文本歌词
}
struct LyricsListDTO: Decodable {   // 结构化 getLyricsBySongId
    let structuredLyrics: [StructuredLyricsDTO]?
}
struct StructuredLyricsDTO: Decodable {
    let displayArtist: String?
    let displayTitle: String?
    let lang: String?
    let synced: Bool?
    let line: [LyricLineDTO]?
}
struct LyricLineDTO: Decodable {
    let start: Int?     // 毫秒
    let value: String   // 必填
}
```

### 4.12 PlayQueueDTO
```swift
struct PlayQueueDTO: Decodable {
    let entry: [SongDTO]?
    let current: String?
    let position: Int?      // 毫秒
}
```

### 4.13 未在上述 DTO 中出现的 endpoint 字段
`OpenSubsonicResponseDTO` 中 `searchResult3`、`starred2`、`randomSongs`、`similarSongs2`、`albumList2` 均复用 `SearchCollectionDTO / SongsDTO / AlbumsDTO`：
```swift
struct SearchCollectionDTO: Decodable {
    let artist: [ArtistDTO]?
    let album: [AlbumDTO]?
    let song: [SongDTO]?
}
```

---

## 5. Mapper：DTO → Domain 映射规则

实现于 `OpenSubsonicDomainMapper`（`Models.swift:406-504`）。所有 Domain 实体都带 `serverID: ServerID`（来自 `configuration.serverID`）。

### 5.1 artist（ArtistDTO → Artist）
```swift
Artist(
    id: ArtistID(rawValue: value.id.value),
    serverID: serverID,
    name: value.name ?? value.id.value,
    albumCount: value.albumCount ?? value.album?.count ?? 0,
    artworkKey: value.coverArt          // 来自 coverArt 字段（字符串 ID）
)
```

### 5.2 album（AlbumDTO → Album）
```swift
let title = value.name ?? value.album ?? value.title ?? value.id.value
let artistName = value.artist ?? ""
Album(
    id: AlbumID(rawValue: value.id.value),
    serverID: serverID,
    artistID: ArtistID(rawValue: value.artistId?.value ?? legacyID(prefix: "artist", value: artistName)),
    title: title,
    artistName: artistName,
    year: value.year,
    genre: value.genre,
    artworkKey: value.coverArt,        // 来自 coverArt
    songCount: value.songCount
)
```

### 5.3 track（SongDTO → Track）—— 最关键
```swift
let artistName = value.artist ?? ""
let albumTitle = value.album ?? ""
let nestedGenres = value.genres?.compactMap(\.displayValue) ?? []
let genres = nestedGenres.isEmpty ? value.genre.map { [$0] } ?? [] : nestedGenres

Track(
    id: TrackID(rawValue: value.id.value),
    serverID: serverID,
    albumID: AlbumID(rawValue: value.albumId?.value ?? legacyID(prefix: "album", value: albumTitle)),
    artistID: ArtistID(rawValue: value.artistId?.value ?? legacyID(prefix: "artist", value: artistName)),
    title: value.title ?? value.name ?? value.id.value,
    artistName: artistName,
    albumTitle: albumTitle,
    duration: value.duration ?? 0,        // Double 秒 → 单位秒
    trackNumber: value.track,
    discNumber: value.discNumber,
    year: value.year,
    genres: genres,
    isFavorite: value.starred != nil,     // starred 字段存在即收藏
    rating: value.userRating,
    artworkKey: value.coverArt,           // 来自 coverArt
    sourceInfo: AudioSourceInfo(
        codec: value.suffix ?? value.contentType,
        bitDepth: value.bitDepth,
        sampleRate: value.samplingRate,
        bitRate: value.bitRate,
        channelCount: value.channelCount,
        replayGain: value.replayGain.map {
            ReplayGainMetadata(
                trackGainDB: $0.trackGain,
                albumGainDB: $0.albumGain,
                trackPeak: $0.trackPeak,
                albumPeak: $0.albumPeak,
                baseGainDB: $0.baseGain,
                fallbackGainDB: $0.fallbackGain
            )
        }
    )
)
```

映射要点（精确）：
- **artworkKey**：直接来自 DTO 的 `coverArt` 字符串（`song.coverArt` / `album.coverArt` / `artist.coverArt`）。注意它**不是完整 URL**，而是 coverArt id，需经 `getCoverArt?id=<artworkKey>` 解析为图片（见 endpoint 23）。
- **duration**：`value.duration ?? 0`，单位为**秒（Double）**。
- **genres**：优先用 `genres[]`（OpenSubsonic 多重 genre，`ItemGenreDTO.displayValue`）；若为空则回退到单值 `genre` 字符串构成的单元素数组；都缺失则为空数组。
- **replayGain**：嵌套映射到 `AudioSourceInfo.replayGain`（`ReplayGainMetadata`），各字段可为 nil。
- **sourceInfo.codec**：优先 `suffix`（如 `mp3`），回退 `contentType`（如 `audio/mpeg`）。
- **isFavorite**：`starred != nil`（starred 字段存在与否表示收藏状态）。
- **rating**：`userRating`（0–5，可为 nil）。
- **artistID / albumID 缺省兜底**：当 DTO 无 `artistId` / `albumId` 时，用 `legacyID(prefix:value:)` 生成确定性占位 ID（`Models.swift:501-503`）：
  ```swift
  private func legacyID(prefix: String, value: String) -> String {
      "legacy-\(prefix):\(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))"
  }
  ```

### 5.4 playlist（PlaylistDTO → Playlist）
```swift
Playlist(
    id: PlaylistID(rawValue: value.id.value),
    serverID: serverID,
    name: value.name ?? value.id.value,
    trackIDs: (value.entry ?? []).map { TrackID(rawValue: $0.id.value) },
    comment: value.comment,
    modifiedAt: playlistChangedDate(value.changed),
    isReadOnly: value.readonly ?? false,
    validUntil: playlistChangedDate(value.validUntil)
)
```
`playlistChangedDate`（`Models.swift:493-499`）：ISO-8601，先尝试标准格式再尝试带小数秒格式，失败返回 nil（**不猜测时间**）。

### 5.5 其它聚合 DTO → Domain
- `OpenSubsonicArtistDetail` = `artist` + `(value.album ?? []).map(mapper.album)`（`:163-166`）。
- `OpenSubsonicAlbumDetail` = `album` + `(value.song ?? []).map(mapper.track)`（`:181-184`）。
- `OpenSubsonicStarred` = artist/album/track 三部分分别 map（`:281-285`）。
- `OpenSubsonicSearchResult` = 同上三段（`:326-330`）。
- `OpenSubsonicPlaylistDetail` = `playlist` + `(value.entry ?? []).map(mapper.track)`（`:767-772`）。
- `OpenSubsonicPlayQueue`：`tracks = entry.map(track)`，`currentTrackID = queue.current.map(TrackID.init)`，`positionMilliseconds = queue.position`（`:553-557`）。

---

## 6. StreamQualityPolicy 规则

源码（`StreamQualityPolicy.swift`）。配置通过 `@Sendable` 闭包从 UserDefaults 读取（修改设置即时生效，无需重启）。

UserDefaults 键（`:65-66`）：
```swift
public static let highQualityWiFiKey = "auralis.audio.highQualityWiFi"
public static let cellularTranscodingKey = "auralis.audio.cellularTranscoding"
```
默认值：`highQualityOnWiFi` 默认 **true**，`cellularTranscodingAllowed` 默认 **true**（`:73-78`）。

### 6.1 maxBitRate（码率上限；nil = 服务器原始质量）
```swift
public var maxBitRate: Int? {
    if isCellular() {
        return cellularTranscodingAllowed() ? 320 : nil
    }
    return highQualityOnWiFi() ? nil : 320
}
```
逐条规则：
1. **蜂窝网络**（`isCellular()` 返回 true）：
   - `cellularTranscodingAllowed()` 为 true → `320`（即转码上限 320 kbps）。
   - 否则 → `nil`（原始质量）。
2. **非蜂窝（Wi-Fi/以太网/未知）**：
   - `highQualityOnWiFi()` 为 true → `nil`（原始质量）。
   - 否则 → `320`。

### 6.2 format（转码格式）
```swift
public var format: String? {
    maxBitRate == nil ? nil : "mp3"
}
```
- 仅当 `maxBitRate` 非 nil（即需要限制码率）时返回 `"mp3"`；否则 `nil`（不转码）。
- 注意：Android 端 `stream`/`makeStreamURL` 的 `format` 参数**仅在同时传入 `maxBitRate` 时才附加**（见 `OpenSubsonicClient.swift:98` `if let format, maxBitRate != nil`）。

### 6.3 网络类型判定
- `isCellular()` 默认取 `NetworkPath.shared.isCellular`（`StreamQualityPolicy.swift:79`），`NetworkPath` 用 `NWPathMonitor` 实时监测 `path.usesInterfaceType(.cellular)`（`StreamQualityPolicy.swift:42`）。
- 无法判断时 `isCellular` 返回 **false**（按 Wi-Fi/原始质量处理）（`:24-29`）。

### 6.4 应用位置
`makeStreamURL` / `makeStreamURLs` 在构造 `stream` URL 时把 `maxBitRate`/`format` 仅作为**查询参数**传入（`OpenSubsonicClient.swift:51-57, 96-98`），不会改 `v`/`c`。`stream()` 方法同理（`OpenSubsonicClient.swift:448-453`）。

---

## 7. 错误处理

### 7.1 错误类型
`OpenSubsonicClientError`（`OpenSubsonic.swift:206-218`）：
```swift
public enum OpenSubsonicClientError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidConfiguration(String)
    case invalidParameter(String)
    case unsupportedCapability(String)
    case server(code: Int, message: String)       // 兼容 Phase 0
    case serverFailure(OpenSubsonicServerError)
    case httpStatus(Int)
    case transport(code: Int, host: String?)
    case malformedResponse(String)
    case missingPayload(String)
}
```
`OpenSubsonicServerError`（`OpenSubsonic.swift:194-204`）：`code: Int, message: String, helpURL: URL?`。

### 7.2 错误映射流程（`execute`，`OpenSubsonicClient.swift:646-699`）
1. 非 HTTP 响应（非 `HTTPURLResponse`）→ `malformedResponse("非 HTTP 响应")`。
2. HTTP 状态码非 2xx：
   - 若 `canRetry && attempt < maxAttempts && isTransient(statusCode)` → 重试。
   - 否则优先用 `serverErrorMessage(from:)`（`:594-601`，解析 `{"subsonic-response":{"error":{"message":...}}}` 或 `{"error":{"message":...}}`）得到 message，抛 `serverFailure(.init(code: statusCode, message: message))`；无 message 则抛 `httpStatus(statusCode)`。
3. 响应体验证（`validateEnvelopeIfPresent`，`:741-756`）：仅当 `Content-Type` 含 `json` 或（Content-Type 为空/以 `text/` 且首字节为 `{`）时解析；非 JSON（二进制流）直接跳过。
4. JSON 信封解析后 `validate(_:)`（`:758-765`）：若 `error != nil` → `serverFailure(error.domainValue)`；若 `status?.lowercased() != "ok"` → `malformedResponse`。
5. `URLError`：
   - `cancelled` 且 `Task.isCancelled` → `CancellationError()`。
   - 可重试且 `isTransient(error.code)` → 重试。
   - 否则 → `transport(code: error.errorCode, host: error.failingURL?.host)`。
6. 其它 `NSError` → `transport(code: nsError.code, host: ...)`。

### 7.3 可重试 vs 不可重试
**按 endpoint 划分是否启用重试**（`isRetryable`，`:774-783`）：
```swift
private func isRetryable(_ endpoint: OpenSubsonicEndpoint) -> Bool {
    switch endpoint {
    case .createPlaylist, .updatePlaylist, .deletePlaylist,
         .star, .unstar, .setRating, .scrobble,
         .savePlayQueue, .savePlayQueueByIndex, .reportPlayback:
        false
    default:
        true
    }
}
```
- **不可重试（写/副作用操作）**：`createPlaylist, updatePlaylist, deletePlaylist, star, unstar, setRating, scrobble, savePlayQueue, savePlayQueueByIndex, reportPlayback`。
- **可重试（读操作 + stream/download/coverArt）**：其余所有 endpoint。

**重试触发条件（需同时满足：可重试 + 未达 maxAttempts + 瞬态）**：
- HTTP 瞬态（`isTransient(statusCode:)`，`:785-787`）：`408`、`429`、`500...599`。
- 传输层瞬态（`isTransient(_:)`，`:789-798`）：`timedOut, cannotFindHost, cannotConnectToHost, networkConnectionLost, dnsLookupFailed, notConnectedToInternet, internationalRoamingOff, callIsActive, dataNotAllowed, resourceUnavailable`。

**退避策略**（`waitBeforeRetry`，`:800-806`）：
```swift
let multiplier = pow(retryPolicy.multiplier, Double(max(0, attempt - 1)))
let calculated = Double(retryPolicy.initialDelayNanoseconds) * multiplier
let capped = min(calculated, 30_000_000_000)   // 上限 30s
```
`OpenSubsonicRetryPolicy` 默认（`:290-307`）：`maximumAttempts = 3`, `initialDelayNanoseconds = 250_000_000`（250ms）, `multiplier = 2`；`disabled` 为 `maximumAttempts: 1`。

### 7.4 特殊响应处理
- `getLyricsBySongId` 无歌词时返回 `{status:ok}` 无 `lyricsList`，客户端视为**空数组**而非错误（`OpenSubsonicClient.swift:488-493`）。
- `getLyrics`（传统）value 为空返回 `nil`（`:522-524`）。
- 各种 `missingPayload(name)`：对应容器字段为 nil 时抛出（如 `musicFolders`,`artists`,`artist`,`album`,`song`,`genres`,`albumList2`,`randomSongs`,`starred2`,`searchResult3`,`playlists`,`playlist`,`playQueue`,`similarSongs2`）。

---

## 8. Capabilities（ServerCapabilities 解析）

`extensions()` 调用 `.getOpenSubsonicExtensions`，返回 `[OpenSubsonicExtension]`（`OpenSubsonic.swift:47-55`）：
```swift
public struct OpenSubsonicExtension: Codable, Hashable, Sendable {
    public let name: String
    public let versions: [Int]
}
```

`capabilities()` 经 `CapabilityRegistry.capabilities(from:)`（`OpenSubsonic.swift:57-78`）映射为 `ServerCapabilities`：

```swift
public static func capabilities(from extensions: [OpenSubsonicExtension]) -> ServerCapabilities {
    let names = Set(extensions.map { normalized($0.name) })
    return ServerCapabilities(
        supportsStructuredLyrics: containsAny(names, ["songLyrics", "structuredLyrics"]),
        supportsSonicSimilarity: containsAny(names, ["sonicSimilarity", "similarSongs", "similarTracks"]),
        supportsIndexedQueue: containsAny(names, ["indexBasedQueue", "indexedQueue"]),
        supportsPlaybackReport: containsAny(names, ["playbackReport"]),
        supportsTranscoding: containsAny(names, ["transcoding"]),
        supportsTranscodeOffset: containsAny(names, ["transcodeOffset"]),
        supportsAPIKeyAuthentication: containsAny(names, ["apiKeyAuthentication"])
    )
}

private static func normalized(_ name: String) -> String {
    name.lowercased().filter(\.isLetter)     // 仅保留字母并小写
}
private static func containsAny(_ values: Set<String>, _ candidates: [String]) -> Bool {
    !values.isDisjoint(with: candidates.map(normalized))
}
```

`ServerCapabilities` 字段（Domain/Models.swift）：`supportsStructuredLyrics, supportsSonicSimilarity, supportsIndexedQueue, supportsPlaybackReport, supportsTranscoding, supportsTranscodeOffset, supportsAPIKeyAuthentication`（均为 Bool，默认 false）。

匹配规则要点：
- **名称归一化**：先 `lowercased()` 再 `filter(\.isLetter)`（去掉所有非字母字符，包括数字、连字符、下划线）。
- 因此候选匹配是任意“归一化后名称集合”交集非空即 true（不区分大小写、忽略非字母）。
- 例如 `supportsStructuredLyrics` = 扩展名归一化后含 `songlyrics` 或 `structuredlyrics`；`supportsAPIKeyAuthentication` = 含 `apikeyauthentication`。
- `versions` 数组在 capability 判定中**未使用**（仅保留，用于未来精细判断）。

---

## 9. 依赖装配（ApplicationComposition）

- 生产装配根在 `ApplicationComposition`（`ApplicationComposition.swift`）。
- `OpenSubsonicLibrarySyncSource(client:)` 作为 `sourceFactory` 注入 `ProductionServerConnector`（`:67-75`）。
- `credentialVault` = `KeychainCredentialVault()`（`:53`），凭据不落明文。
- 服务器 `URLSession` 开启 `waitsForConnectivity = true` 且 `timeoutIntervalForResource = 60`（`:92-97`），用于应对 macOS/iOS 本地网络授权弹窗期间的网络 unsatisfied 状态（避免 -1009 立即失败）。
- 重试策略默认 `.standard`（3 次，250ms 起，×2）。

---

## 10. LibrarySync 分页与 pageSize（OpenSubsonicLibrarySyncSource）

- 全部走 offset 分页，封装成不透明、可取消的 `LibraryPage<...>`。
- `albumsPage`：每次向 `client.albums(type: .alphabeticalByName, size: min(500, pageSize), offset:, musicFolderID:)` 请求（`:129-134`）。**单页请求 size 上限 500**（与 `albums` 约束 `1...500` 一致）。
- `tracksPage`：每次 `client.albums(type: .alphabeticalByName, size: min(50, pageSize), offset:, ...)` 取专辑，再并发拉专辑详情（`maximumConcurrentAlbumRequests` 默认 6，`:94, :257`），展开其 `tracks`（`:162-169`）。
- 多 music folder：先 `musicFolders()`；若为空则用 `[nil]`（即不带 `musicFolderId` 请求全部）（`:206-212`）。
- 去重：专辑用 `seenAlbumIDs`，曲目用 `seenTrackIDs`（`:89-90, :135, :173`）。
- 续传游标 `Cursor` 编码为 `"v1|\(section)|\(folderIndex)|\(offset)"`（`:61`），非法续传抛 `invalidContinuation`。
- `validate`：`serverID` 必须匹配；`pageSize > 0`（否则 `invalidPageSize`）（`:191-199`）。

**注意（可疑点 B）**：tracks 同步实际上是通过“拉取字母序专辑列表 + 逐个专辑详情”间接获得曲目，而非 `getSongsByGenre`/分段 `getAlbumList2` 直取曲目。Android 端若想高效拉全库曲目需复刻此策略（500 专辑批量、6 并发详情）。

---

## 11. 关键事实与可疑点汇总（供 Kotlin 实现核对）

1. **所有请求都是 POST 表单**（`x-www-form-urlencoded`），含只读操作；URL 路径 `<base>/rest/<endpoint>.view`。
2. **认证只有 token（md5(password+salt)，小写十六进制）+ salt，u/t/s）与 apiKey 两种，无明文密码**（可疑点：设计上永不发送 `p=`）。
3. **表单转义非标准**：空格→`+`，其它字节→`%XX`（大写）。需逐字复刻，否则与服务器编码不一致。
4. **可疑点 A**：`getPlayQueueByIndex/savePlayQueueByIndex/reportPlayback/getSonicSimilarTracks/findSonicPath/getTranscodeDecision/getTranscodeStream` 在枚举与“不可重试”列表中声明，但 **Client 无任何方法**，疑似预留未接线能力——Android 端应先确认是否需要实现。
5. **可疑点 B**：全库曲目同步靠“专辑列表 + 并发专辑详情”间接获取，非直取曲目端点。
6. **缺失 duration 单位陷阱**：`SongDTO.duration` 是 **Double 秒**，映射为 Domain `duration`（单位需与 Android 端约定一致，建议秒或毫秒统一）。
7. **artworkKey = coverArt 字符串**（非 URL），需经 `getCoverArt?id=` 取得图片。
8. **ID 多类型兼容**：`FlexibleString` 兼容 Int/String/Double，必须统一为 String。
9. **严格去重/非猜测**：`isFolderLike` 仅凭结构（缺 `songCount/created/changed`）过滤伪歌单，绝不按名称；`playlistChangedDate` 解析失败返回 nil 而非猜测时间。
10. **API 版本默认 `1.16.1`**，client 名 `Auralis`。
11. **重试规则**：写操作（playlist/star/rating/scrobble/savePlayQueue 等）不可重试；读操作 + 流可重试；仅 408/429/5xx 与若干网络错误可瞬态重试，退避 250ms×2，上限 30s。
12. **二进制响应**（stream/download/coverArt）不经 JSON 信封解析，直接返回 Data。
