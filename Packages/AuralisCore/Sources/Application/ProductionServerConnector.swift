import CryptoKit
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import Observability
import OpenSubsonicKit
import Persistence
import SecurityKit

public actor ProductionServerConnector: ServerConnecting {
    public typealias SourceFactory = @Sendable (OpenSubsonicClient) -> any LibrarySyncSource

    /// 端点探测只把“不可达”与“地址虽然可达但认证/协议不正确”分开；后者绝不能误切到外网。
    private enum EndpointProbe: Sendable {
        case reachable(OpenSubsonicServerInfo)
        case unavailable
        case failed(ServerConnectionError)
    }

    private let credentialVault: any CredentialVault
    /// Canonical music catalog. `persistence` below retains accounts/configuration only.
    private let catalogStore: LocalCatalogStore
    private let persistence: any AuralisPersisting
    private let session: URLSession
    private let sourceFactory: SourceFactory
    /// 歌单 / 流派的本地缓存，让冷启动无需等待网络。
    private let auxiliaryCache: LibraryAuxiliaryCache
    /// 按 ServerID 管理的已认证客户端：任何涉及远程实体的请求都从这里按
    /// 显式 serverID 取客户端，绝不依赖“当前活跃服务器”（R01）。
    /// `activeServerID` 只表示 UI 当前浏览的服务器，不能决定一首已存在 Track
    /// 应该访问哪台服务器。
    private var clients: [ServerID: OpenSubsonicClient] = [:]
    /// UI 当前浏览 / 操作的服务器（不影响既有 Track 的请求路由）。
    public private(set) var activeServerID: ServerID?
    /// 端点探测代际计数：restoreConnection 启动的双地址探测完成后必须校验
    /// generation 仍匹配，否则丢弃结果，避免旧探测把 activeServerID 改回去。
    private var endpointResolutionGeneration: UInt64 = 0
    /// 流质量策略（Wi-Fi 原始 / 蜂窝转码、码率限制），构造流地址时生效。
    private let streamQuality: StreamQualityPolicy

    public init(
        credentialVault: any CredentialVault,
        persistence: any AuralisPersisting,
        catalogStore: LocalCatalogStore,
        session: URLSession = .shared,
        auxiliaryCache: LibraryAuxiliaryCache = LibraryAuxiliaryCache(),
        sourceFactory: @escaping SourceFactory,
        streamQuality: StreamQualityPolicy = .init()
    ) {
        self.credentialVault = credentialVault
        self.persistence = persistence
        self.catalogStore = catalogStore
        self.session = session
        self.auxiliaryCache = auxiliaryCache
        self.sourceFactory = sourceFactory
        self.streamQuality = streamQuality
    }

    /// 仅供 composition identity 回归测试；不暴露数据库路径或内容。
    nonisolated var catalogStoreIdentity: ObjectIdentifier {
        ObjectIdentifier(catalogStore)
    }

    public func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        try await connect(input) { _ in }
    }

    public func connect(
        _ input: ServerConnectionInput,
        progress: @escaping @Sendable (ServerConnectionStage) async -> Void
    ) async throws -> ServerConnectionResult {
        do {
            try Task.checkCancellation()
            await progress(.validating)
            try validate(input)

            let normalizedURL = Self.normalizedBaseURL(input.baseURL)
            let normalizedExternalURL = input.externalBaseURL.map(Self.normalizedBaseURL)
            let username = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let serverID = Self.stableServerID(baseURL: normalizedURL, username: username)
            let credentialID = CredentialID(rawValue: "opensubsonic.\(serverID.rawValue)")
            let previousCredential = try await existingCredential(id: credentialID)
            // R12：记录本次连接前该服务器是否已有持久化账户，用于失败补偿决策——
            // 覆盖已有账户时失败，需要把 Persistence/SQLite 里的旧账户也恢复回去，
            // 不能只回滚 Keychain 密码（否则出现「新 username/URL + 旧密码」）。
            let previousAccount = try? await persistence.account(id: serverID)

            await progress(.storingCredential)
            try await credentialVault.store(input.password, for: credentialID)

            do {
                await progress(.authenticating)
                let (client, serverInfo) = try await selectAuthenticatedClient(
                    internalURL: normalizedURL,
                    externalURL: normalizedExternalURL,
                    serverID: serverID,
                    username: username,
                    credentialID: credentialID
                )

                await progress(.detectingCapabilities)
                let capabilities = (try? await client.capabilities()) ?? ServerCapabilities()

                async let genresRequest = Self.optional { try await client.genres() }
                async let playlistsRequest = Self.optional { try await client.playlists() }
                async let starredRequest = Self.optional { try await client.starred() }

                await progress(.loadingLibrary)
                let synchronizer = LibrarySynchronizer(
                    source: sourceFactory(client),
                    store: catalogStore,
                    pageSize: 50,
                    isRetryable: Self.isRetryableSyncError
                )
                _ = try await synchronizer.sync(serverID: serverID, mode: .full) { update in
                    switch update.stage {
                    case .beginning, .fetching:
                        await progress(.loadingLibrary)
                    case .persisting, .completedSection, .completed:
                        await progress(.savingLibrary)
                    }
                }

                try Task.checkCancellation()
                let account = ServerAccount(
                    id: serverID,
                    displayName: input.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    baseURL: normalizedURL,
                    externalBaseURL: normalizedExternalURL,
                    username: username,
                    credentialReference: credentialID.rawValue
                )
                try await persistence.saveAccount(account)
                try await catalogStore.upsertServer(account)
                let snapshot = try await canonicalSnapshot(serverID: serverID, account: account)
                try await compactLegacySnapshot(serverID: serverID, account: account)

                let genres = await genresRequest ?? []
                let playlists = await playlistsRequest ?? []
                // 服务器收藏回流：以 getStarred2 的完整集合为准，把已收藏的曲目标记为 isFavorite，
                // 保证首次连接时 app 的收藏状态与服务器一致（此前完全丢失服务器收藏）。
                let starred = await starredRequest
                var favoriteTrackIDs: [String] = []
                var tracks = snapshot.tracks
                if let starred {
                    favoriteTrackIDs = starred.tracks.map(\.id.rawValue)
                    let favoriteSet = Set(favoriteTrackIDs)
                    for index in tracks.indices {
                        tracks[index].isFavorite = favoriteSet.contains(tracks[index].id.rawValue)
                    }
                }
                // 首次连接就把歌单 / 流派 / 收藏落盘，下次冷启动直接读本地。
                await auxiliaryCache.save(
                    playlists: playlists,
                    genres: genres,
                    favoriteTrackIDs: favoriteTrackIDs,
                    serverID: serverID
                )

                // Catalog 保持纯元数据；真正播放/预载/重试时由 AppModel 按需解析单曲 URL。
                clients[serverID] = client
                activeServerID = serverID

                return ServerConnectionResult(
                    account: account,
                    capabilities: capabilities,
                    artists: snapshot.artists,
                    albums: snapshot.albums,
                    tracks: tracks,
                    genres: genres,
                    playlists: playlists,
                    serverType: serverInfo.serverType,
                    serverVersion: serverInfo.serverVersion
                )
            } catch {
                await restoreCredential(previousCredential, id: credentialID)
                if let previousAccount {
                    // R12 补偿：本次连接覆盖了已有账户；失败后恢复 Persistence 与
                    // SQLite 中的旧账户记录，避免「凭据已回滚、账户却已是新配置」。
                    try? await catalogStore.upsertServer(previousAccount)
                    try? await persistence.saveAccount(previousAccount)
                } else {
                    // R12 补偿：若此前没有持久化账户，本次连接又未成功保存账号，
                    // 已同步进 SQLite 的目录可能成为无 account 的 orphan 数据——
                    // 清理该服务器本地数据，避免「凭据已回滚但目录残留」。
                    try? await catalogStore.purgeServer(serverID)
                }
                // 保留原始错误描述，让用户看到具体原因而非笼统的"无法识别"
                throw Self.preservedError(error)
            }
        } catch {
            throw Self.preservedError(error)
        }
    }

    public func restoreLastConnection() async throws -> ServerConnectionResult? {
        // 兼容入口：恢复「首个已保存账户」（未记录上次活跃服务器的旧行为）。
        guard let account = try await persistence.accounts().first else { return nil }
        return try await restoreConnection(serverID: account.id)
    }

    /// 恢复指定服务器的本地资料库：零网络请求出界面（快照 + 本地辅助缓存），
    /// 联网后由 AppModel 触发后台增量同步。按 serverID 恢复让「切换服务器」真正可用，
    /// 不再总是回到第一台服务器。
    public func restoreConnection(serverID: ServerID) async throws -> ServerConnectionResult? {
        do {
            try Task.checkCancellation()
            let serverHash = StartupPerformanceTrace.redactedServerID(serverID.rawValue)
            // 只要求账号存在：备份恢复的服务器可能还没有本地快照（未同步过），
            // 此时返回空库结果让 UI 显示「已配置但未同步」，而不是让用户重新添加服务器。
            let restoreAccountStartedAt = ContinuousClock.now
            let account = try await persistence.account(id: serverID)
            StartupPerformanceTrace.record(
                .restoreAccount,
                since: restoreAccountStartedAt,
                metadata: .init(serverIDHash: serverHash)
            )
            guard let account else {
                return nil
            }
            let legacyMigrationStartedAt = ContinuousClock.now
            try await migrateLegacySnapshotIfNeeded(serverID: serverID, account: account)
            StartupPerformanceTrace.record(
                .legacySnapshotMigration,
                since: legacyMigrationStartedAt,
                metadata: .init(serverIDHash: serverHash)
            )
            try await catalogStore.upsertServer(account)
            // 冷启动必须先展示本地快照，不能被内外网探测（内网最长 30 秒）阻塞。
            // 先用内网客户端拼出本地目录；端点选择转到后台，完成后按 serverID 更新
            // clients 字典。代际校验保证：探测期间用户切到其他服务器/重新恢复时，
            // 迟到的旧探测结果不会覆盖新状态。
            if let client = restoreClient(for: account) {
                clients[account.id] = client
                activeServerID = account.id
            }
            if account.externalBaseURL != nil {
                let generation = endpointResolutionGeneration &+ 1
                endpointResolutionGeneration = generation
                Task {
                    guard let client = await self.resolvedClient(for: account) else { return }
                    guard self.endpointResolutionGeneration == generation else { return }
                    self.clients[account.id] = client
                }
            }
            let snapshot = try await canonicalSnapshot(serverID: account.id, account: account)
            var tracks = snapshot.tracks
            let artists = snapshot.artists
            let albums = snapshot.albums
            // 冷恢复不再给全曲库生成 stream URL。这里记录真实的零工作量，方便启动
            // timeline 明确证明 URL decoration 已离开 critical path。
            let streamURLStartedAt = ContinuousClock.now
            StartupPerformanceTrace.record(
                .restoreStreamURLs,
                since: streamURLStartedAt,
                metadata: .init(entityCount: 0, serverIDHash: serverHash)
            )
            // 除双地址的端点选择外，仍只读本地辅助缓存；歌单/流派随后后台增量刷新。
            let cached = await auxiliaryCache.snapshot(serverID: account.id)
            // 服务器收藏回流：冷启动时用本地缓存的收藏 ID 集合校正曲目收藏状态，
            // 否则重启后所有收藏都会回到未收藏，与服务器不一致。
            if let favoriteIDs = cached?.favoriteTrackIDs {
                let favoriteSet = Set(favoriteIDs)
                for index in tracks.indices {
                    tracks[index].isFavorite = favoriteSet.contains(tracks[index].id.rawValue)
                }
            }
            return ServerConnectionResult(
                account: account,
                capabilities: ServerCapabilities(),
                artists: artists,
                albums: albums,
                tracks: tracks,
                genres: cached?.genres ?? [],
                playlists: cached?.playlists ?? []
            )
        } catch {
            throw Self.safeError(error)
        }
    }

    /// 用当前服务器凭据重新做一次全量同步并返回最新资料库（自愈：旧快照为空/损坏时恢复界面）。
    /// 与 restoreConnection 不同：restoreConnection 只读本地快照（零网络），
    /// 本方法真正走 getArtists/getAlbumList2/getAlbum 全量拉取并重写快照。
    public func resync(serverID: ServerID) async throws -> ServerConnectionResult? {
        guard let account = try await persistence.account(id: serverID) else { return nil }
        guard let client = await resolvedClient(for: account) else { return nil }
        clients[serverID] = client
        activeServerID = serverID
        do {
            try Task.checkCancellation()
            let serverInfo = try await client.serverInfo()
            let capabilities = (try? await client.capabilities()) ?? ServerCapabilities()

            async let genresRequest = Self.optional { try await client.genres() }
            async let playlistsRequest = Self.optional { try await client.playlists() }
            async let starredRequest = Self.optional { try await client.starred() }

            let synchronizer = LibrarySynchronizer(
                source: sourceFactory(client),
                store: catalogStore,
                pageSize: 50,
                isRetryable: Self.isRetryableSyncError
            )
            _ = try await synchronizer.sync(serverID: serverID, mode: .full) { _ in }

            try await catalogStore.upsertServer(account)
            let snapshot = try await canonicalSnapshot(serverID: serverID, account: account)
            try await compactLegacySnapshot(serverID: serverID, account: account)

            let genres = await genresRequest ?? []
            let playlists = await playlistsRequest ?? []
            let starred = await starredRequest
            var favoriteTrackIDs: [String] = []
            var tracks = snapshot.tracks
            if let starred {
                favoriteTrackIDs = starred.tracks.map(\.id.rawValue)
                let favoriteSet = Set(favoriteTrackIDs)
                for index in tracks.indices {
                    tracks[index].isFavorite = favoriteSet.contains(tracks[index].id.rawValue)
                }
            }
            await auxiliaryCache.save(
                playlists: playlists,
                genres: genres,
                favoriteTrackIDs: favoriteTrackIDs,
                serverID: serverID
            )
            // 完整同步结果同样保持纯目录元数据；播放入口统一按需解析 URL。

            return ServerConnectionResult(
                account: account,
                capabilities: capabilities,
                artists: snapshot.artists,
                albums: snapshot.albums,
                tracks: tracks,
                genres: genres,
                playlists: playlists,
                serverType: serverInfo.serverType,
                serverVersion: serverInfo.serverVersion
            )
        } catch {
            throw Self.safeError(error)
        }
    }

    /// 后台增量刷新歌单与流派，并写入本地辅助缓存。
    /// 由 App 在冷启动「先显示本地缓存」之后调用；失败时返回 nil，界面保持缓存内容不变。
    /// 只刷新 `serverID` 对应服务器的辅助数据，绝不写进其他服务器的缓存命名空间。
    public func refreshAuxiliaryData(serverID: ServerID) async -> AuxiliaryLibraryData? {
        guard let client = clients[serverID] else { return nil }
        async let playlistsRequest = Self.optional { try await client.playlists() }
        async let genresRequest = Self.optional { try await client.genres() }
        async let starredRequest = Self.optional { try await client.starred() }
        let playlists = await playlistsRequest
        let genres = await genresRequest
        let starred = await starredRequest
        // 所有请求都失败（离线）时不要用空数组覆盖已有缓存。
        guard playlists != nil || genres != nil || starred != nil else { return nil }
        // 单侧失败时保留该侧的本地缓存，避免把已有数据抹成空。
        let cached = await auxiliaryCache.snapshot(serverID: serverID)
        let mergedPlaylists = playlists ?? cached?.playlists ?? []
        let mergedGenres = genres ?? cached?.genres ?? []
        let mergedFavorites = starred.map { $0.tracks.map(\.id.rawValue) } ?? cached?.favoriteTrackIDs ?? []
        await auxiliaryCache.save(
            playlists: mergedPlaylists,
            genres: mergedGenres,
            favoriteTrackIDs: mergedFavorites,
            serverID: serverID
        )
        return AuxiliaryLibraryData(
            playlists: mergedPlaylists,
            playlistsAreAuthoritative: playlists != nil,
            genres: mergedGenres,
            favoriteTrackIDs: mergedFavorites,
            favoriteTrackIDsAreAuthoritative: starred != nil
        )
    }

    /// 按需拉取单曲歌词。服务器不支持结构化歌词或单曲无歌词时返回 nil。
    /// 网络/认证等失败也折叠为 nil（便捷入口；需要区分失败与无歌词时用 fetchLyrics）。
    public func lyrics(for track: Track) async -> LyricsDocument? {
        try? await fetchLyrics(for: track)
    }

    /// 渐进缓存用：区分「失败」与「服务器无歌词」。
    /// - 网络/认证/解析错误：抛出错误（失败，可重试，不标记无歌词）。
    /// - 服务器明确没有歌词：返回 nil（调用方标记无歌词状态）。
    /// - 结构化歌词（getLyricsBySongId）为空时，回退到传统 getLyrics(artist+title)，
    ///   兼容 Navidrome 等服务器只暴露纯文本歌词、不返回 structuredLyrics 的场景。
    /// 请求始终路由到 `track.serverID` 对应的客户端（R01），与当前浏览服务器无关。
    public func fetchLyrics(for track: Track) async throws -> LyricsDocument? {
        guard let client = clients[track.serverID] else {
            throw ServerConnectionError.serverUnavailable
        }
        let documents = try await client.structuredLyrics(trackID: track.id)
        // 优先返回带时间轴且非空的歌词，其次任何非空歌词
        if let best = documents.first(where: { $0.isSynced && !$0.lines.isEmpty })
            ?? documents.first(where: { !$0.lines.isEmpty }) {
            return best
        }
        // 回退：主端点已确认无结构化歌词。传统接口的网络/认证/解析失败必须上抛（R04），
        // 让调用方区分「服务器明确无歌词」与「请求失败」，避免断网时误写负缓存。
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return try await client.traditionalLyrics(artist: artist, title: title, trackID: track.id)
    }

    /// 上报单曲已完成播放（scrobble submission=true），让服务器更新播放次数。
    /// Navidrome 只在 scrobble(submission=true) 时标记已播放，stream 不会计数。
    /// 未连接或上报失败时静默忽略（本地播放记录不受影响）。
    public func scrobble(serverID: ServerID, trackID: TrackID, submission: Bool) async {
        guard let client = clients[serverID] else { return }
        _ = try? await client.scrobble(trackIDs: [trackID], submission: submission)
    }

    /// 按需拉取封面图片数据（getCoverArt）。按 serverID 路由，封面 key 跨服务器互不串扰。
    public func artworkData(serverID: ServerID, key: String, targetPixelSize: Int) async -> Data? {
        guard let client = clients[serverID] else { return nil }
        let size = min(max(targetPixelSize, 1), 4096)
        return try? await client.coverArt(id: key, size: size)
    }

    /// 从服务器拉取流派列表（getGenres）。失败时抛出，调用方决定是否降级为空。
    public func genres(serverID: ServerID) async throws -> [Genre] {
        guard let client = clients[serverID] else { throw ServerConnectionError.serverUnavailable }
        return try await client.genres()
    }

    /// 按流派从服务器拉取歌曲：先按流派列专辑，再展开各专辑曲目并补全 stream URL。
    public func tracks(byGenre name: String, serverID: ServerID) async throws -> [Track] {
        guard let client = clients[serverID], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerConnectionError.serverUnavailable
        }
        let albums = try await client.albums(
            type: .byGenre,
            size: 40,
            offset: 0,
            fromYear: nil,
            toYear: nil,
            genre: name,
            musicFolderID: nil
        )
        var collected: [Track] = []
        var seen = Set<TrackID>()
        for album in albums {
            let detail = try? await client.album(id: album.id)
            for var track in detail?.tracks ?? [] {
                track.streamURL = await Self.makeStreamURL(client: client, trackID: track.id.rawValue, quality: streamQuality)
                if seen.insert(track.id).inserted {
                    collected.append(track)
                }
                if collected.count >= 200 { break }
            }
            if collected.count >= 200 { break }
        }
        return collected
    }

    /// 重新获取单曲的带认证播放地址：调用 OpenSubsonic makeStreamURL 刷新（本地拼串，无网络往返）。
    /// 流地址过期（服务器重启 / token 失效）后，播放器用新地址重试。
    public func refreshStreamURL(serverID: ServerID, trackID: TrackID) async -> URL? {
        guard let client = clients[serverID] else { return nil }
        return await Self.makeStreamURL(client: client, trackID: trackID.rawValue, quality: streamQuality)
    }

    /// 探针分页上限（500/页 → 最多 20,000 张专辑）。达到上限仍未翻完时视为
    /// 「无法可靠判定」，返回 nil 走保守全量，而不是无限翻页。
    private static let maximumProbePages = 40

    /// 轻量获取服务器音乐库曲目总数：分页 getAlbumList2（500/页）求和 songCount。
    /// 只拉专辑列表元数据，不逐张专辑拉取曲目，因此比全量同步快得多。
    /// 服务器不返回 songCount（老版本 Subsonic）或总数异常时返回 nil，表示「无法判断，不跳过同步」。
    public func librarySongCount(serverID: ServerID) async -> Int? {
        await libraryRevisionProbe(serverID: serverID)?.songCount
    }

    public func libraryRevisionProbe(serverID: ServerID) async -> LibraryRevisionProbe? {
        guard let client = clients[serverID] else { return nil }
        var total = 0
        var offset = 0
        let pageSize = 500
        var anySongCount = false
        var fingerprintParts: [String] = []
        // 探针有界：超大型曲库（超过上限页仍未翻完）无法可靠判定是否变化，
        // 保守返回 nil（= 不跳过同步，走全量校验），避免「轻量检查」退化成整库扫描。
        let maxPages = Self.maximumProbePages
        var reachedEnd = false
        for _ in 0..<maxPages {
            do {
                let page = try await client.albums(type: .alphabeticalByName, size: pageSize, offset: offset)
                if page.isEmpty {
                    reachedEnd = true
                    break
                }
                for album in page {
                    if let count = album.songCount {
                        anySongCount = true
                        total += count
                    }
                    fingerprintParts.append([
                        album.id.rawValue,
                        album.title,
                        album.artistName,
                        album.year.map(String.init) ?? "",
                        album.genre ?? "",
                        album.artworkKey ?? "",
                        album.songCount.map(String.init) ?? "",
                    ].joined(separator: "\u{1f}"))
                }
                if page.count < pageSize {
                    reachedEnd = true
                    break
                }
                offset += pageSize
            } catch {
                return nil
            }
        }
        // 没翻完（超大库）或服务器未提供任何 songCount 时无法可靠比对，返回 nil 走原有同步逻辑。
        guard reachedEnd, anySongCount, total > 0 else { return nil }
        fingerprintParts.sort()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in fingerprintParts.joined(separator: "\u{1e}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return LibraryRevisionProbe(
            kind: .albumFingerprint,
            fingerprint: String(hash, radix: 16),
            songCount: total
        )
    }

    /// 带认证的下载地址（后台下载任务用），本地拼串无网络往返。
    public func downloadURL(serverID: ServerID, trackID: TrackID) async -> URL? {
        guard let client = clients[serverID] else { return nil }
        return try? await client.makeDownloadURL(trackID: trackID.rawValue)
    }

    /// 按 ID 从服务器拉取单曲（getSong）并补流地址。
    /// 供 Agent「服务器曲目直播回退」使用：本地目录尚未同步到这首歌时，也能直接在线流播。
    /// 失败时抛出（与「服务器确实没有该曲目」区分，R15）。
    public func serverTrack(serverID: ServerID, trackID: TrackID) async throws -> Track? {
        guard let client = clients[serverID] else { throw ServerConnectionError.serverUnavailable }
        var track = try await client.song(id: trackID)
        if track.streamURL == nil {
            track.streamURL = await Self.makeStreamURL(client: client, trackID: track.id.rawValue, quality: streamQuality)
        }
        return track
    }

    /// 服务器在线搜索歌曲（search3），返回带流地址的曲目。
    /// 失败时抛出（与「无匹配结果」区分，R15）。
    public func serverSearch(query: String, limit: Int, serverID: ServerID) async throws -> [Track] {
        guard let client = clients[serverID],
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ServerConnectionError.serverUnavailable }
        let result = try await client.search(query: query, songCount: min(max(limit, 1), 100))
        var tracks = result.tracks
        for index in tracks.indices {
            tracks[index].streamURL = await Self.makeStreamURL(
                client: client, trackID: tracks[index].id.rawValue, quality: streamQuality
            )
        }
        return tracks
    }

    /// 下载单曲完整音频数据（download 端点），用于本地缓存播放。
    public func downloadData(serverID: ServerID, trackID: TrackID) async -> Data? {
        guard let client = clients[serverID] else { return nil }
        return try? await client.download(trackID: trackID)
    }

    /// 把单曲追加到服务器歌单（updatePlaylist 的 songIdToAdd）。
    public func addToPlaylist(serverID: ServerID, playlistID: PlaylistID, trackID: TrackID) async -> Bool {
        guard let client = clients[serverID] else { return false }
        do {
            try await client.updatePlaylist(id: playlistID, appendTrackIDs: [trackID])
            // 写操作成功后把服务器最新歌单列表落盘，冷启动即与服务器一致。
            await refreshCachedPlaylists(serverID: serverID, client: client)
            return true
        } catch {
            return false
        }
    }

    /// 同步收藏状态到服务器；失败静默（本地状态已生效，下次同步会对齐）。
    public func setFavorite(serverID: ServerID, trackID: TrackID, isFavorite: Bool) async {
        guard let client = clients[serverID] else { return }
        do {
            if isFavorite {
                try await client.star(.track(trackID))
            } else {
                try await client.unstar(.track(trackID))
            }
        } catch {
            // 收藏是本地立即可见的操作，服务器同步失败不阻塞 UI；
            // 失败时不更新本地缓存，后续后台刷新会以服务器真实状态校正。
            return
        }
        // 同步成功后即时更新本地缓存的收藏集合，冷启动即与服务器一致。
        let cached = await auxiliaryCache.snapshot(serverID: serverID)
        var ids = Set(cached?.favoriteTrackIDs ?? [])
        if isFavorite {
            ids.insert(trackID.rawValue)
        } else {
            ids.remove(trackID.rawValue)
        }
        await auxiliaryCache.updateFavorites(Array(ids).sorted(), serverID: serverID)
    }

    /// 用指定服务器构建资料库同步器（本地目录写入）。
    /// 与 connect()/resync() 使用同一个 bounded-concurrency source（sourceFactory 注入），
    /// 避免后台/增量同步退回旧版「逐专辑串行拉取」——几千张专辑会变成几千次串行 HTTP。
    public func makeSynchronizer(serverID: ServerID, store: LocalCatalogStore) -> LibrarySynchronizer? {
        guard let client = clients[serverID] else { return nil }
        let source = sourceFactory(client)
        return LibrarySynchronizer(source: source, store: store)
    }

    /// 修改服务器显示名称：更新持久化账户，不影响服务器 ID / 凭据 / 资料库。
    public func updateServerDisplayName(serverID: ServerID, displayName: String) async -> Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard var account = try? await persistence.account(id: serverID) else { return false }
        account.displayName = trimmed
        let credentialID = CredentialID(rawValue: account.credentialReference ?? "opensubsonic.\(serverID.rawValue)")
        do {
            // R12：persistence 与 catalog 任一步失败都逆序恢复，不留下半写状态。
            try await withAccountMutationRollback(serverID: serverID, credentialID: credentialID) {
                try await persistence.saveAccount(account)
                try await catalogStore.upsertServer(account)
            }
            return true
        } catch {
            return false
        }
    }

    public func updateServerExternalBaseURL(serverID: ServerID, externalBaseURL: URL?) async -> Bool {
        guard var account = try? await persistence.account(id: serverID) else { return false }
        account.externalBaseURL = externalBaseURL.map(Self.normalizedBaseURL)
        let credentialID = CredentialID(rawValue: account.credentialReference ?? "opensubsonic.\(serverID.rawValue)")
        do {
            // R12：persistence 与 catalog 任一步失败都逆序恢复，不留下半写状态。
            try await withAccountMutationRollback(serverID: serverID, credentialID: credentialID) {
                try await persistence.saveAccount(account)
                try await catalogStore.upsertServer(account)
            }
            return true
        } catch {
            return false
        }
    }

    public func updateServerConfiguration(
        serverID: ServerID,
        update: ServerConfigurationUpdate
    ) async -> ServerAccount? {
        guard var account = try? await persistence.account(id: serverID) else { return nil }
        do {
            try ServerURLPolicy.validate(update.baseURL)
            if let externalBaseURL = update.externalBaseURL {
                try ServerURLPolicy.validate(externalBaseURL)
            }
        } catch {
            return nil
        }
        let displayName = update.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = update.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, !username.isEmpty else { return nil }

        let credentialID = CredentialID(rawValue: account.credentialReference ?? "opensubsonic.\(serverID.rawValue)")
        let newPassword = update.password?.trimmingCharacters(in: .whitespacesAndNewlines)
        account.displayName = displayName
        account.baseURL = Self.normalizedBaseURL(update.baseURL)
        account.externalBaseURL = update.externalBaseURL.map(Self.normalizedBaseURL)
        account.username = username
        account.credentialReference = credentialID.rawValue

        do {
            // R12：整个变更（密码 → persistence → catalog）包进补偿辅助——
            // saveAccount 成功、upsertServer 失败时，按逆序恢复 Persistence 旧账户
            // 与 Keychain 旧密码，杜绝「新 username/URL + 旧密码」跨存储不一致。
            return try await withAccountMutationRollback(serverID: serverID, credentialID: credentialID) {
                if let newPassword, !newPassword.isEmpty {
                    guard (try await credentialVault.store(newPassword, for: credentialID)) != nil else {
                        throw AccountMutationError.credentialStoreFailed
                    }
                }
                try await persistence.saveAccount(account)
                try await catalogStore.upsertServer(account)
                // 更新该服务器的内存客户端（若已建立），并保持 activeServerID 不变。
                if clients[serverID] != nil {
                    clients[serverID] = makeClient(
                        baseURL: account.baseURL!,
                        serverID: serverID,
                        username: username,
                        credentialID: credentialID,
                        vault: credentialVault
                    )
                }
                return account
            }
        } catch {
            return nil
        }
    }

    /// 用「用户当前输入」执行一次真实连接测试：临时把密码存入 Keychain（测试专用 ID），
    /// 构造客户端调用 serverInfo，测试结束后删除临时凭据；不保存账号、不同步、不影响当前连接。
    public func testConnection(_ input: ServerConnectionInput) async throws -> ServerConnectionTestResult {
        try validate(input)
        let normalizedURL = Self.normalizedBaseURL(input.baseURL)
        let normalizedExternalURL = input.externalBaseURL.map(Self.normalizedBaseURL)
        let username = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        // 用内存凭据测试：不写 Keychain（测试连接本就不需要持久化凭据，
        // 也避免 macOS 上 Keychain 交互不允许（-128）导致测试失败）。
        let memoryVault = InMemoryCredentialVault()
        let tempCredentialID = CredentialID(rawValue: "connection-test")
        try await memoryVault.store(input.password, for: tempCredentialID)
        let (_, info) = try await selectAuthenticatedClient(
            internalURL: normalizedURL,
            externalURL: normalizedExternalURL,
            serverID: ServerID(rawValue: "connection-test"),
            username: username,
            credentialID: tempCredentialID,
            vault: memoryVault
        )
        return ServerConnectionTestResult(
            serverType: info.serverType,
            serverVersion: info.serverVersion,
            apiVersion: info.protocolVersion,
            username: username
        )
    }

    /// 备份恢复：把服务器账号与登录凭据写回本地（不联网、不触发资料同步）。
    /// 凭据写入 Keychain，账号写入持久化快照；SQLite 目录由 AppModel 另行登记。
    public func restoreAccountFromBackup(_ account: ServerAccount, secret: String?) async throws {
        // R12：credential → persistence → catalog 三存储写入包进补偿辅助——
        // 任一步失败都按逆序恢复，备份恢复不留下半写状态（例如凭据已写、
        // 账户未写导致登录信息与目录登记不一致）。
        let credentialID = CredentialID(
            rawValue: account.credentialReference ?? "opensubsonic.\(account.id.rawValue)"
        )
        try await withAccountMutationRollback(serverID: account.id, credentialID: credentialID) {
            if let secret, !secret.isEmpty, let reference = account.credentialReference {
                try await credentialVault.store(secret, for: CredentialID(rawValue: reference))
            }
            try await persistence.saveAccount(account)
            try await catalogStore.upsertServer(account)
        }
    }

    // MARK: - 歌单编辑

    public func createPlaylist(serverID: ServerID, name: String, trackIDs: [TrackID]) async -> Playlist? {
        guard let client = clients[serverID] else { return nil }
        guard let detail = try? await client.createPlaylist(name: name, trackIDs: trackIDs) else { return nil }
        await refreshCachedPlaylists(serverID: serverID, client: client)
        return detail.playlist
    }

    public func renamePlaylist(serverID: ServerID, playlistID: PlaylistID, name: String) async -> Bool {
        guard let client = clients[serverID] else { return false }
        do {
            try await client.updatePlaylist(id: playlistID, name: name)
            await refreshCachedPlaylists(serverID: serverID, client: client)
            return true
        } catch {
            return false
        }
    }

    public func removeFromPlaylist(serverID: ServerID, playlistID: PlaylistID, indices: [Int]) async -> Bool {
        guard let client = clients[serverID], !indices.isEmpty else { return false }
        do {
            // 服务器按下标删除，必须降序执行，否则先删的会让后面的下标错位
            try await client.updatePlaylist(id: playlistID, removeIndexes: indices.sorted(by: >))
            await refreshCachedPlaylists(serverID: serverID, client: client)
            return true
        } catch {
            return false
        }
    }

    /// 重排歌单：用**单次** updatePlaylist 请求完成「清空旧下标 + 追加新顺序」（R02）。
    /// 不允许「先清空、再追加」的两步实现——第一步成功、第二步失败会把用户歌单
    /// 变成空歌单。OpenSubsonic updatePlaylist 同请求同时支持 songIndexToRemove 与
    /// songIdToAdd；Navidrome 等兼容实现均接受。
    public func replacePlaylistTracks(serverID: ServerID, playlistID: PlaylistID, trackIDs: [TrackID]) async -> Bool {
        guard let client = clients[serverID] else { return false }
        do {
            let detail = try await client.playlist(id: playlistID)
            let existingCount = detail.tracks.count
            try await client.updatePlaylist(
                id: playlistID,
                appendTrackIDs: trackIDs,
                removeIndexes: existingCount > 0 ? Array((0..<existingCount).reversed()) : []
            )
            await refreshCachedPlaylists(serverID: serverID, client: client)
            return true
        } catch {
            return false
        }
    }

    public func deletePlaylist(serverID: ServerID, playlistID: PlaylistID) async -> Bool {
        guard let client = clients[serverID] else { return false }
        do {
            try await client.deletePlaylist(id: playlistID)
            await cacheDeletedPlaylist(playlistID, client: client)
            return true
        } catch {
            // 删除属于幂等操作：请求超时不代表服务器没有执行。用 getPlaylists 验证一次，
            // 只有服务器仍明确返回该 ID 时才报失败，避免“已删但 App 显示删不掉”。
            guard let playlists = try? await client.playlists(),
                  !playlists.contains(where: { $0.id == playlistID })
            else { return false }
            await cacheDeletedPlaylist(playlistID, client: client, verifiedPlaylists: playlists)
            return true
        }
    }

    /// 删除确认后立即更新缓存。若验证请求已拿到完整列表，直接采用它；否则仅移除
    /// 目标项，避免等待下一轮刷新期间把已删歌单显示回来。
    private func cacheDeletedPlaylist(
        _ playlistID: PlaylistID,
        client: OpenSubsonicClient,
        verifiedPlaylists: [Playlist]? = nil
    ) async {
        let serverID = client.configuration.serverID
        if let verifiedPlaylists {
            await auxiliaryCache.updatePlaylists(verifiedPlaylists, serverID: serverID)
        } else if let cached = await auxiliaryCache.snapshot(serverID: serverID) {
            await auxiliaryCache.updatePlaylists(
                cached.playlists.filter { $0.id != playlistID },
                serverID: serverID
            )
        }
    }

    /// 拉取歌单内的完整曲目列表（getPlaylist 单数端点）。失败时抛出（R15）。
    public func fetchPlaylistTracks(serverID: ServerID, playlistID: PlaylistID) async throws -> [Track] {
        guard let client = clients[serverID] else { throw ServerConnectionError.serverUnavailable }
        let detail = try await client.playlist(id: playlistID)
        var tracks = detail.tracks
        // 为歌单内的曲目也构造 stream URL
        for index in tracks.indices {
            tracks[index].streamURL = await Self.makeStreamURL(client: client, trackID: tracks[index].id.rawValue, quality: streamQuality)
        }
        // 把歌单最新曲目列表写回本地缓存，冷启动后详情可直接展示，与服务器一致。
        if let cached = await auxiliaryCache.snapshot(serverID: serverID) {
            var playlists = cached.playlists
            if let index = playlists.firstIndex(where: { $0.id == playlistID }) {
                playlists[index].trackIDs = tracks.map(\.id)
                await auxiliaryCache.updatePlaylists(playlists, serverID: serverID)
            }
        }
        return tracks
    }

    /// 从服务器拉取最新歌单列表并写入本地辅助缓存（歌单写操作成功后调用）。
    /// 失败时静默保留旧缓存，界面继续用现有数据。
    /// 使用调用时捕获的 client（R01）：await 间隙切服不会把 B 的歌单写进 A 的缓存。
    private func refreshCachedPlaylists(serverID: ServerID, client: OpenSubsonicClient) async {
        if let fresh = try? await client.playlists() {
            await auxiliaryCache.updatePlaylists(fresh, serverID: serverID)
        }
    }

    // MARK: - 标注

    public func setAlbumFavorite(serverID: ServerID, albumID: AlbumID, isFavorite: Bool) async {
        guard let client = clients[serverID] else { return }
        if isFavorite {
            try? await client.star(.album(albumID))
        } else {
            try? await client.unstar(.album(albumID))
        }
    }

    public func setArtistFavorite(serverID: ServerID, artistID: ArtistID, isFavorite: Bool) async {
        guard let client = clients[serverID] else { return }
        if isFavorite {
            try? await client.star(.artist(artistID))
        } else {
            try? await client.unstar(.artist(artistID))
        }
    }

    public func setRating(serverID: ServerID, trackID: TrackID, rating: Int) async {
        guard let client = clients[serverID] else { return }
        try? await client.setRating(min(max(rating, 0), 5), trackID: trackID)
    }

    // MARK: - 服务器

    public func ping(serverID: ServerID) async -> Bool {
        guard let client = clients[serverID] else { return false }
        do {
            try await client.ping()
            return true
        } catch {
            return false
        }
    }

    public func disconnect() async {
        clients.removeAll()
        activeServerID = nil
    }

    /// Reads the complete visible music library from SQLite. This is the only catalog snapshot
    /// used to hydrate SwiftUI; the JSON persistence no longer participates in music queries.
    private func canonicalSnapshot(
        serverID: ServerID,
        account: ServerAccount
    ) async throws -> ServerLibrarySnapshot {
        let catalog = try await catalogStore.catalogSnapshot(serverID: serverID)
        let snapshot = ServerLibrarySnapshot(
            serverID: serverID,
            account: account,
            artists: catalog.artists,
            albums: catalog.albums,
            tracks: catalog.tracks
        )
        return Self.repaired(snapshot: snapshot, account: account)
    }

    /// One-time compatibility bridge for users upgrading from the former JSON music snapshot.
    /// Accounts/config remain in FileBackedPersistence. Music is copied into SQLite first, then
    /// removed from the JSON archive only after SQLite has committed successfully.
    private func migrateLegacySnapshotIfNeeded(
        serverID: ServerID,
        account: ServerAccount
    ) async throws {
        guard let legacy = try await persistence.snapshot(serverID: serverID),
              !legacy.artists.isEmpty || !legacy.albums.isEmpty || !legacy.tracks.isEmpty
        else { return }

        let localTracks = try await catalogStore.trackCount(serverID: serverID)
        let localArtists = try await catalogStore.allArtists(serverID: serverID).count
        let localAlbums = try await catalogStore.allAlbums(serverID: serverID).count
        if localTracks < legacy.tracks.count
            || localArtists < legacy.artists.count
            || localAlbums < legacy.albums.count {
            let repaired = Self.repaired(snapshot: legacy, account: account)
            let session = try await catalogStore.beginSync(serverID: serverID, mode: .full)
            try await catalogStore.stageArtists(repaired.artists, session: session)
            try await catalogStore.stageAlbums(repaired.albums, session: session)
            try await catalogStore.stageTracks(repaired.tracks, session: session)
            try await catalogStore.completeSync(session, completedAt: .now)
        }
        try await catalogStore.upsertServer(account)
        try await compactLegacySnapshot(serverID: serverID, account: account)
    }

    private func compactLegacySnapshot(serverID: ServerID, account: ServerAccount) async throws {
        guard let legacy = try await persistence.snapshot(serverID: serverID),
              !legacy.artists.isEmpty || !legacy.albums.isEmpty || !legacy.tracks.isEmpty
        else { return }
        try await persistence.saveSnapshot(ServerLibrarySnapshot(serverID: serverID, account: account))
    }

    /// 仅本地清理：删除持久化资料库与 Keychain 凭据。远端 NAS 数据不受任何影响。
    /// 移除服务器：仅清理本地凭据与本地数据，绝不向远端发送任何删除请求。
    public func forgetServer(serverID: ServerID) async {
        if let account = try? await persistence.account(id: serverID),
           let reference = account.credentialReference {
            try? await credentialVault.delete(id: CredentialID(rawValue: reference))
        } else {
            // 兜底：按约定的稳定命名删除。
            try? await credentialVault.delete(id: CredentialID(rawValue: "opensubsonic.\(serverID.rawValue)"))
        }
        try? await persistence.removeServer(serverID)
        try? await catalogStore.purgeServer(serverID)
        await auxiliaryCache.purge(serverID: serverID)
        clients[serverID] = nil
        if activeServerID == serverID {
            activeServerID = nil
        }
    }

    /// 用持久化的账户信息重建 API 客户端（凭据仍在系统 Keychain 中）。
    private func restoreClient(for account: ServerAccount) -> OpenSubsonicClient? {
        guard let baseURL = account.baseURL,
              let username = account.username,
              let credentialReference = account.credentialReference
        else { return nil }
        return OpenSubsonicClient(
            configuration: OpenSubsonicConfiguration(
                serverID: account.id,
                baseURL: baseURL,
                authentication: .token(
                    username: username,
                    credentialID: CredentialID(rawValue: credentialReference)
                )
            ),
            credentialVault: credentialVault,
            session: session
        )
    }

    /// 已保存账户的实际端点选择。单地址沿用零网络恢复；双地址在这里并行探测，
    /// 让随后生成的播放/下载 URL 与当前网络一致。
    private func resolvedClient(for account: ServerAccount) async -> OpenSubsonicClient? {
        guard let internalURL = account.baseURL,
              let username = account.username,
              let reference = account.credentialReference
        else { return nil }
        guard account.externalBaseURL != nil else {
            return restoreClient(for: account)
        }
        let selection = try? await selectAuthenticatedClient(
            internalURL: internalURL,
            externalURL: account.externalBaseURL,
            serverID: account.id,
            username: username,
            credentialID: CredentialID(rawValue: reference)
        )
        return selection?.0
    }

    /// 内外网端点同时探测。内网在 30 秒窗口内可用就取消外网探测并固定内网；
    /// 只有内网确认不可达，才采纳外网结果。认证、协议和地址校验失败不会触发降级。
    private func selectAuthenticatedClient(
        internalURL: URL,
        externalURL: URL?,
        serverID: ServerID,
        username: String,
        credentialID: CredentialID,
        vault: (any CredentialVault)? = nil
    ) async throws -> (OpenSubsonicClient, OpenSubsonicServerInfo) {
        let vault = vault ?? credentialVault
        let internalClient = makeClient(
            baseURL: internalURL,
            serverID: serverID,
            username: username,
            credentialID: credentialID,
            vault: vault
        )
        guard let externalURL, externalURL != internalURL else {
            return (internalClient, try await internalClient.serverInfo())
        }

        let externalClient = makeClient(
            baseURL: externalURL,
            serverID: serverID,
            username: username,
            credentialID: credentialID,
            vault: vault
        )
        let externalTask = Task { await Self.probe(externalClient) }
        let internalResult = await Self.probe(internalClient)
        switch internalResult {
        case let .reachable(info):
            externalTask.cancel()
            return (internalClient, info)
        case let .failed(error):
            externalTask.cancel()
            throw error
        case .unavailable:
            switch await externalTask.value {
            case let .reachable(info):
                return (externalClient, info)
            case let .failed(error):
                throw error
            case .unavailable:
                throw ServerConnectionError.serverUnavailable
            }
        }
    }

    private func makeClient(
        baseURL: URL,
        serverID: ServerID,
        username: String,
        credentialID: CredentialID,
        vault: any CredentialVault
    ) -> OpenSubsonicClient {
        OpenSubsonicClient(
            configuration: OpenSubsonicConfiguration(
                serverID: serverID,
                baseURL: baseURL,
                authentication: .token(username: username, credentialID: credentialID),
                requestTimeout: 30
            ),
            credentialVault: vault,
            session: session
        )
    }

    private nonisolated static func probe(_ client: OpenSubsonicClient) async -> EndpointProbe {
        do {
            return .reachable(try await client.serverInfo())
        } catch let error as OpenSubsonicClientError {
            switch error {
            case .transport:
                return .unavailable
            case let .httpStatus(status) where status == 408 || (500...599).contains(status):
                return .unavailable
            default:
                return .failed(safeError(error))
            }
        } catch {
            return .failed(safeError(error))
        }
    }

    /// 按流质量策略构造带认证的流地址（本地拼串，无网络往返）。
    nonisolated private static func makeStreamURL(
        client: OpenSubsonicClient,
        trackID: String,
        quality: StreamQualityPolicy
    ) async -> URL? {
        try? await client.makeStreamURL(
            trackID: trackID,
            maxBitRate: quality.maxBitRate,
            format: quality.format
        )
    }

    public nonisolated static func stableServerID(baseURL: URL, username: String) -> ServerID {
        let canonicalURL = normalizedBaseURL(baseURL).absoluteString
        let digest = SHA256.hash(data: Data("\(canonicalURL)\n\(username)".utf8))
        let value = digest.map { String(format: "%02x", $0) }.joined()
        return ServerID(rawValue: "server-\(value)")
    }

    public nonisolated static func normalizedBaseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        // 剥离内嵌凭据：user:pass@host 中的密码不得随地址落库/进日志（凭据只进 Keychain）。
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    private func existingCredential(id: CredentialID) async throws -> String? {
        do {
            return try await credentialVault.retrieve(id: id)
        } catch CredentialVaultError.missing {
            return nil
        } catch {
            throw ServerConnectionError.secureStorageUnavailable
        }
    }

    private func restoreCredential(_ value: String?, id: CredentialID) async {
        if let value {
            try? await credentialVault.store(value, for: id)
        } else {
            try? await credentialVault.delete(id: id)
        }
    }

    /// 账户变更补偿辅助（R12）。
    ///
    /// 调用前记录 previous account（Persistence）与 previous credential（Keychain）；
    /// mutate 闭包内按「credential → persistence → catalog」顺序写入。任一步抛错时
    /// 按逆序恢复（catalog → persistence → credential），保证失败后不会留下
    /// 「Persistence 已是新 username/URL、Keychain 却恢复旧密码」的跨存储不一致。
    ///
    /// 不实现真正数据库两阶段提交，但补偿路径完整：恢复动作本身失败时只记录日志，
    /// 不再向上抛（尽力恢复，避免掩盖原始错误）。
    private func withAccountMutationRollback<T>(
        serverID: ServerID,
        credentialID: CredentialID,
        _ mutate: () async throws -> T
    ) async throws -> T {
        let previousAccount = try? await persistence.account(id: serverID)
        let previousPassword = try? await credentialVault.retrieve(id: credentialID)
        do {
            return try await mutate()
        } catch {
            // 逆序恢复：catalog → persistence → Keychain。
            if let previousAccount {
                try? await catalogStore.upsertServer(previousAccount)
                try? await persistence.saveAccount(previousAccount)
            } else {
                // 此前无账户记录：本次是新增服务器，清除可能残留的 catalog server 行，
                // 避免「凭据已回滚、SQLite 却登记了无 account 的 orphan server」。
                try? await catalogStore.purgeServer(serverID)
            }
            if let previousPassword {
                try? await credentialVault.store(previousPassword, for: credentialID)
            } else {
                try? await credentialVault.delete(id: credentialID)
            }
            throw error
        }
    }

    /// 账户变更辅助内部错误（R12）。
    private enum AccountMutationError: Error {
        case credentialStoreFailed
    }

    private func validate(_ input: ServerConnectionInput) throws {
        try ServerURLPolicy.validate(input.baseURL)
        if let externalBaseURL = input.externalBaseURL {
            try ServerURLPolicy.validate(externalBaseURL)
        }
        guard !input.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerConnectionError.missingDisplayName
        }
        guard !input.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerConnectionError.missingUsername
        }
        guard !input.password.isEmpty else { throw ServerConnectionError.missingCredential }
    }

    private nonisolated static func repaired(
        snapshot: ServerLibrarySnapshot,
        account: ServerAccount
    ) -> ServerLibrarySnapshot {
        var artists = Dictionary(snapshot.artists.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var albums = Dictionary(snapshot.albums.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        for album in snapshot.albums where artists[album.artistID] == nil {
            artists[album.artistID] = Artist(
                id: album.artistID,
                serverID: snapshot.serverID,
                name: album.artistName.isEmpty ? "未知艺术家" : album.artistName,
                albumCount: 1
            )
        }
        for track in snapshot.tracks {
            if artists[track.artistID] == nil {
                artists[track.artistID] = Artist(
                    id: track.artistID,
                    serverID: snapshot.serverID,
                    name: track.artistName.isEmpty ? "未知艺术家" : track.artistName,
                    albumCount: 1
                )
            }
            if albums[track.albumID] == nil {
                albums[track.albumID] = Album(
                    id: track.albumID,
                    serverID: snapshot.serverID,
                    artistID: track.artistID,
                    title: track.albumTitle.isEmpty ? "未知专辑" : track.albumTitle,
                    artistName: track.artistName,
                    year: track.year,
                    genre: track.genres.first,
                    artworkKey: track.artworkKey
                )
            }
        }

        return ServerLibrarySnapshot(
            serverID: snapshot.serverID,
            account: account,
            artists: artists.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            albums: albums.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            tracks: snapshot.tracks,
            checkpoints: []
        )
    }

    private nonisolated static func optional<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async -> Value? {
        try? await operation()
    }

    private nonisolated static func isRetryableSyncError(_ error: any Error) -> Bool {
        guard let error = error as? OpenSubsonicClientError else {
            return !(error is CancellationError) && !(error is LibrarySyncError)
        }
        switch error {
        case let .httpStatus(status):
            return status == 408 || status == 429 || (500...599).contains(status)
        case let .transport(code, _):
            return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet]
                .contains(code)
        default:
            return false
        }
    }

    private nonisolated static func preservedError(_ error: any Error) -> any Error {
        // 验证错误已经是 ServerConnectionError，直接返回
        if let error = error as? ServerConnectionError { return error }
        // 取消错误映射
        if error is CancellationError { return ServerConnectionError.cancelled }
        // 其他错误（OpenSubsonicClientError 等）直接返回，
        // 让 UI 显示原始 errorDescription 而非笼统的"无法识别"
        return error
    }

    private nonisolated static func safeError(_ error: any Error) -> ServerConnectionError {
        if let error = error as? ServerConnectionError { return error }
        if error is CancellationError { return .cancelled }
        if error is CredentialVaultError { return .secureStorageUnavailable }
        if error is PersistenceError { return .libraryStorageUnavailable }
        if let error = error as? OpenSubsonicClientError {
            switch error {
            case let .server(code, _):
                return [40, 41, 50].contains(code) ? .authenticationFailed : .unsupportedResponse
            case let .serverFailure(serverError):
                return [40, 41, 50].contains(serverError.code) ? .authenticationFailed : .unsupportedResponse
            case .transport, .httpStatus:
                return .serverUnavailable
            case .malformedResponse, .missingPayload:
                return .unsupportedResponse
            case .invalidBaseURL, .invalidConfiguration, .invalidParameter, .unsupportedCapability:
                return .unexpected
            }
        }
        return .unexpected
    }
}
