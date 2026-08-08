import CryptoKit
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import OpenSubsonicKit
import Persistence
import SecurityKit

public actor ProductionServerConnector: ServerConnecting {
    public typealias SourceFactory = @Sendable (OpenSubsonicClient) -> any LibrarySyncSource

    private let credentialVault: any CredentialVault
    private let persistence: any AuralisPersisting
    private let session: URLSession
    private let sourceFactory: SourceFactory
    /// 歌单 / 流派的本地缓存，让冷启动无需等待网络。
    private let auxiliaryCache: LibraryAuxiliaryCache
    /// 当前已认证的服务器客户端，供歌词、封面等按需请求复用。
    private var activeClient: OpenSubsonicClient?
    /// 流质量策略（Wi-Fi 原始 / 蜂窝转码、码率限制），构造流地址时生效。
    private let streamQuality: StreamQualityPolicy

    public init(
        credentialVault: any CredentialVault,
        persistence: any AuralisPersisting,
        session: URLSession = .shared,
        auxiliaryCache: LibraryAuxiliaryCache = LibraryAuxiliaryCache(),
        sourceFactory: @escaping SourceFactory,
        streamQuality: StreamQualityPolicy = .init()
    ) {
        self.credentialVault = credentialVault
        self.persistence = persistence
        self.session = session
        self.auxiliaryCache = auxiliaryCache
        self.sourceFactory = sourceFactory
        self.streamQuality = streamQuality
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
            let username = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let serverID = Self.stableServerID(baseURL: normalizedURL, username: username)
            let credentialID = CredentialID(rawValue: "opensubsonic.\(serverID.rawValue)")
            let previousCredential = try await existingCredential(id: credentialID)

            await progress(.storingCredential)
            try await credentialVault.store(input.password, for: credentialID)

            do {
                let client = OpenSubsonicClient(
                    configuration: OpenSubsonicConfiguration(
                        serverID: serverID,
                        baseURL: normalizedURL,
                        authentication: .token(username: username, credentialID: credentialID)
                    ),
                    credentialVault: credentialVault,
                    session: session
                )

                await progress(.authenticating)
                let serverInfo = try await client.serverInfo()

                await progress(.detectingCapabilities)
                let capabilities = (try? await client.capabilities()) ?? ServerCapabilities()

                async let genresRequest = Self.optional { try await client.genres() }
                async let playlistsRequest = Self.optional { try await client.playlists() }
                async let starredRequest = Self.optional { try await client.starred() }

                await progress(.loadingLibrary)
                let syncStore = PersistenceLibrarySyncStore(persistence: persistence)
                let synchronizer = LibrarySynchronizer(
                    source: sourceFactory(client),
                    store: syncStore,
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
                guard var snapshot = try await persistence.snapshot(serverID: serverID) else {
                    throw ServerConnectionError.libraryStorageUnavailable
                }
                let account = ServerAccount(
                    id: serverID,
                    displayName: input.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    baseURL: normalizedURL,
                    username: username,
                    credentialReference: credentialID.rawValue
                )
                snapshot = Self.repaired(snapshot: snapshot, account: account)
                try await persistence.saveSnapshot(snapshot)

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
                    for index in tracks.indices where favoriteSet.contains(tracks[index].id.rawValue) {
                        tracks[index].isFavorite = true
                    }
                }
                // 首次连接就把歌单 / 流派 / 收藏落盘，下次冷启动直接读本地。
                await auxiliaryCache.save(
                    playlists: playlists,
                    genres: genres,
                    favoriteTrackIDs: favoriteTrackIDs,
                    serverID: serverID
                )

                // 为每首 track 构造带认证的 stream URL，供 AVPlayer 直接播放
                for index in tracks.indices {
                    tracks[index].streamURL = await Self.makeStreamURL(client: client, trackID: tracks[index].id.rawValue, quality: streamQuality)
                }
                activeClient = client

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
            // 只要求账号存在：备份恢复的服务器可能还没有本地快照（未同步过），
            // 此时返回空库结果让 UI 显示「已配置但未同步」，而不是让用户重新添加服务器。
            guard let account = try await persistence.account(id: serverID) else {
                return nil
            }
            // 重建已认证的客户端：恢复播放地址，并支撑歌词/封面/后台同步的按需请求。
            // makeStreamURL 只是本地拼串（无网络往返），不影响冷启动速度。
            if let client = restoreClient(for: account) {
                activeClient = client
            }
            var tracks: [Track] = []
            var artists: [Artist] = []
            var albums: [Album] = []
            if let snapshot = try await persistence.snapshot(serverID: account.id) {
                tracks = snapshot.tracks
                artists = snapshot.artists
                albums = snapshot.albums
                if let client = activeClient {
                    for index in tracks.indices {
                        tracks[index].streamURL = await Self.makeStreamURL(client: client, trackID: tracks[index].id.rawValue, quality: streamQuality)
                    }
                }
            }
            // 关键：冷启动这条路径「零网络请求」。
            // 以前这里同步 await getPlaylists + getGenres，服务器慢或不可达时
            // 整个启动被拖住，看上去就像「每次打开都要重新下载一遍资料」。
            // 现在改为读本地辅助缓存立即返回，联网后由 refreshAuxiliaryData() 在后台增量刷新。
            let cached = await auxiliaryCache.snapshot(serverID: account.id)
            // 服务器收藏回流：冷启动时用本地缓存的收藏 ID 集合校正曲目收藏状态，
            // 否则重启后所有收藏都会回到未收藏，与服务器不一致。
            if let favoriteIDs = cached?.favoriteTrackIDs, !favoriteIDs.isEmpty {
                let favoriteSet = Set(favoriteIDs)
                for index in tracks.indices where favoriteSet.contains(tracks[index].id.rawValue) {
                    tracks[index].isFavorite = true
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
        guard let client = restoreClient(for: account) else { return nil }
        activeClient = client
        do {
            try Task.checkCancellation()
            let serverInfo = try await client.serverInfo()
            let capabilities = (try? await client.capabilities()) ?? ServerCapabilities()

            async let genresRequest = Self.optional { try await client.genres() }
            async let playlistsRequest = Self.optional { try await client.playlists() }
            async let starredRequest = Self.optional { try await client.starred() }

            let syncStore = PersistenceLibrarySyncStore(persistence: persistence)
            let synchronizer = LibrarySynchronizer(
                source: sourceFactory(client),
                store: syncStore,
                pageSize: 50,
                isRetryable: Self.isRetryableSyncError
            )
            _ = try await synchronizer.sync(serverID: serverID, mode: .full) { _ in }

            guard var snapshot = try await persistence.snapshot(serverID: serverID) else { return nil }
            snapshot = Self.repaired(snapshot: snapshot, account: account)
            try await persistence.saveSnapshot(snapshot)

            let genres = await genresRequest ?? []
            let playlists = await playlistsRequest ?? []
            let starred = await starredRequest
            var favoriteTrackIDs: [String] = []
            var tracks = snapshot.tracks
            if let starred {
                favoriteTrackIDs = starred.tracks.map(\.id.rawValue)
                let favoriteSet = Set(favoriteTrackIDs)
                for index in tracks.indices where favoriteSet.contains(tracks[index].id.rawValue) {
                    tracks[index].isFavorite = true
                }
            }
            await auxiliaryCache.save(
                playlists: playlists,
                genres: genres,
                favoriteTrackIDs: favoriteTrackIDs,
                serverID: serverID
            )
            for index in tracks.indices {
                tracks[index].streamURL = await Self.makeStreamURL(client: client, trackID: tracks[index].id.rawValue, quality: streamQuality)
            }

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
    public func refreshAuxiliaryData() async -> AuxiliaryLibraryData? {
        guard let client = activeClient else { return nil }
        let serverID = client.configuration.serverID
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
            genres: mergedGenres,
            favoriteTrackIDs: mergedFavorites
        )
    }

    /// 按需拉取单曲歌词。服务器不支持结构化歌词或单曲无歌词时返回 nil。
    public func lyrics(for track: Track) async -> LyricsDocument? {
        try? await fetchLyrics(for: track)
    }

    /// 渐进缓存用：区分「失败」与「服务器无歌词」。
    /// - 网络/认证/解析错误：抛出错误（失败，可重试，不标记无歌词）。
    /// - 服务器明确没有歌词：返回 nil（调用方标记无歌词状态）。
    /// - 结构化歌词（getLyricsBySongId）为空时，回退到传统 getLyrics(artist+title)，
    ///   兼容 Navidrome 等服务器只暴露纯文本歌词、不返回 structuredLyrics 的场景。
    public func fetchLyrics(for track: Track) async throws -> LyricsDocument? {
        guard let client = activeClient else {
            throw ServerConnectionError.serverUnavailable
        }
        let documents = try await client.structuredLyrics(trackID: track.id)
        // 优先返回带时间轴且非空的歌词，其次任何非空歌词
        if let best = documents.first(where: { $0.isSynced && !$0.lines.isEmpty })
            ?? documents.first(where: { !$0.lines.isEmpty }) {
            return best
        }
        // 回退：主端点已确认无结构化歌词；传统接口失败按「无歌词」处理（不抛错、不标记失败）。
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return try? await client.traditionalLyrics(artist: artist, title: title, trackID: track.id)
    }

    /// 上报单曲已完成播放（scrobble submission=true），让服务器更新播放次数。
    /// Navidrome 只在 scrobble(submission=true) 时标记已播放，stream 不会计数。
    /// 未连接或上报失败时静默忽略（本地播放记录不受影响）。
    public func scrobble(trackID: TrackID, submission: Bool) async {
        guard let client = activeClient else { return }
        _ = try? await client.scrobble(trackIDs: [trackID], submission: submission)
    }

    /// 按需拉取封面图片数据（getCoverArt）。
    public func artworkData(key: String, targetPixelSize: Int) async -> Data? {
        guard let client = activeClient else { return nil }
        let size = min(max(targetPixelSize, 1), 4096)
        return try? await client.coverArt(id: key, size: size)
    }

    /// 从服务器拉取流派列表（getGenres）。
    public func genres() async -> [Genre] {
        guard let client = activeClient else { return [] }
        return (try? await client.genres()) ?? []
    }

    /// 按流派从服务器拉取歌曲：先按流派列专辑，再展开各专辑曲目并补全 stream URL。
    public func tracks(byGenre name: String) async -> [Track] {
        guard let client = activeClient, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do {
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
        } catch {
            return []
        }
    }

    /// 重新获取单曲的带认证播放地址：调用 OpenSubsonic makeStreamURL 刷新（本地拼串，无网络往返）。
    /// 流地址过期（服务器重启 / token 失效）后，播放器用新地址重试。
    public func refreshStreamURL(trackID: TrackID) async -> URL? {
        guard let client = activeClient else { return nil }
        return await Self.makeStreamURL(client: client, trackID: trackID.rawValue, quality: streamQuality)
    }

    /// 带认证的下载地址（后台下载任务用），本地拼串无网络往返。
    public func downloadURL(trackID: TrackID) async -> URL? {
        guard let client = activeClient else { return nil }
        return try? await client.makeDownloadURL(trackID: trackID.rawValue)
    }

    /// 按 ID 从服务器拉取单曲（getSong）并补流地址。
    /// 供 Agent「服务器曲目直播回退」使用：本地目录尚未同步到这首歌时，也能直接在线流播。
    public func serverTrack(trackID: TrackID) async -> Track? {
        guard let client = activeClient else { return nil }
        do {
            var track = try await client.song(id: trackID)
            if track.streamURL == nil {
                track.streamURL = await Self.makeStreamURL(client: client, trackID: track.id.rawValue, quality: streamQuality)
            }
            return track
        } catch {
            return nil
        }
    }

    /// 服务器在线搜索歌曲（search3），返回带流地址的曲目。
    public func serverSearch(query: String, limit: Int) async -> [Track] {
        guard let client = activeClient,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        do {
            let result = try await client.search(query: query, songCount: min(max(limit, 1), 100))
            var tracks = result.tracks
            for index in tracks.indices {
                tracks[index].streamURL = await Self.makeStreamURL(
                    client: client, trackID: tracks[index].id.rawValue, quality: streamQuality
                )
            }
            return tracks
        } catch {
            return []
        }
    }

    /// 下载单曲完整音频数据（download 端点），用于本地缓存播放。
    public func downloadData(trackID: TrackID) async -> Data? {
        guard let client = activeClient else { return nil }
        return try? await client.download(trackID: trackID)
    }

    /// 把单曲追加到服务器歌单（updatePlaylist 的 songIdToAdd）。
    public func addToPlaylist(playlistID: PlaylistID, trackID: TrackID) async -> Bool {
        guard let client = activeClient else { return false }
        do {
            try await client.updatePlaylist(id: playlistID, appendTrackIDs: [trackID])
            // 写操作成功后把服务器最新歌单列表落盘，冷启动即与服务器一致。
            await refreshCachedPlaylists(serverID: client.configuration.serverID)
            return true
        } catch {
            return false
        }
    }

    /// 同步收藏状态到服务器；失败静默（本地状态已生效，下次同步会对齐）。
    public func setFavorite(trackID: TrackID, isFavorite: Bool) async {
        guard let client = activeClient else { return }
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
        let serverID = client.configuration.serverID
        let cached = await auxiliaryCache.snapshot(serverID: serverID)
        var ids = Set(cached?.favoriteTrackIDs ?? [])
        if isFavorite {
            ids.insert(trackID.rawValue)
        } else {
            ids.remove(trackID.rawValue)
        }
        await auxiliaryCache.updateFavorites(Array(ids).sorted(), serverID: serverID)
    }

    /// 用当前已认证服务器构建资料库同步器（本地目录写入）。
    public func makeSynchronizer(store: LocalCatalogStore) -> LibrarySynchronizer? {
        guard let client = activeClient else { return nil }
        let source = OpenSubsonicSyncSource(client: client)
        return LibrarySynchronizer(source: source, store: store)
    }

    /// 修改服务器显示名称：更新持久化账户，不影响服务器 ID / 凭据 / 资料库。
    public func updateServerDisplayName(serverID: ServerID, displayName: String) async -> Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard var account = try? await persistence.account(id: serverID) else { return false }
        account.displayName = trimmed
        do {
            try await persistence.saveAccount(account)
            return true
        } catch {
            return false
        }
    }

    /// 用「用户当前输入」执行一次真实连接测试：临时把密码存入 Keychain（测试专用 ID），
    /// 构造客户端调用 serverInfo，测试结束后删除临时凭据；不保存账号、不同步、不影响当前连接。
    public func testConnection(_ input: ServerConnectionInput) async throws -> ServerConnectionTestResult {
        let normalizedURL = Self.normalizedBaseURL(input.baseURL)
        let username = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        // 用内存凭据测试：不写 Keychain（测试连接本就不需要持久化凭据，
        // 也避免 macOS 上 Keychain 交互不允许（-128）导致测试失败）。
        let memoryVault = InMemoryCredentialVault()
        let tempCredentialID = CredentialID(rawValue: "connection-test")
        try await memoryVault.store(input.password, for: tempCredentialID)
        let client = OpenSubsonicClient(
            configuration: OpenSubsonicConfiguration(
                serverID: ServerID(rawValue: "connection-test"),
                baseURL: normalizedURL,
                authentication: .token(username: username, credentialID: tempCredentialID)
            ),
            credentialVault: memoryVault,
            session: session
        )
        let info = try await client.serverInfo()
        return ServerConnectionTestResult(
            serverType: info.serverType,
            serverVersion: info.serverVersion,
            apiVersion: info.protocolVersion,
            username: username
        )
    }

    /// 备份恢复：把服务器账号与登录凭据写回本地（不联网、不触发资料同步）。
    /// 凭据写入 Keychain，账号写入持久化快照；SQLite 目录由 AppModel 另行登记。
    public func restoreAccountFromBackup(_ account: ServerAccount, secret: String?) async {
        if let secret, let reference = account.credentialReference {
            try? await credentialVault.store(secret, for: CredentialID(rawValue: reference))
        }
        try? await persistence.saveAccount(account)
    }

    // MARK: - 歌单编辑

    public func createPlaylist(name: String, trackIDs: [TrackID]) async -> Playlist? {
        guard let client = activeClient else { return nil }
        guard let detail = try? await client.createPlaylist(name: name, trackIDs: trackIDs) else { return nil }
        await refreshCachedPlaylists(serverID: client.configuration.serverID)
        return detail.playlist
    }

    public func renamePlaylist(playlistID: PlaylistID, name: String) async -> Bool {
        guard let client = activeClient else { return false }
        do {
            try await client.updatePlaylist(id: playlistID, name: name)
            await refreshCachedPlaylists(serverID: client.configuration.serverID)
            return true
        } catch {
            return false
        }
    }

    public func removeFromPlaylist(playlistID: PlaylistID, indices: [Int]) async -> Bool {
        guard let client = activeClient, !indices.isEmpty else { return false }
        do {
            // 服务器按下标删除，必须降序执行，否则先删的会让后面的下标错位
            try await client.updatePlaylist(id: playlistID, removeIndexes: indices.sorted(by: >))
            await refreshCachedPlaylists(serverID: client.configuration.serverID)
            return true
        } catch {
            return false
        }
    }

    /// 重排歌单：OpenSubsonic 无原生重排端点，用「清空后按新顺序追加」等价实现。
    public func replacePlaylistTracks(playlistID: PlaylistID, trackIDs: [TrackID]) async -> Bool {
        guard let client = activeClient else { return false }
        do {
            let detail = try await client.playlist(id: playlistID)
            let existingCount = detail.tracks.count
            if existingCount > 0 {
                try await client.updatePlaylist(id: playlistID, removeIndexes: Array((0..<existingCount).reversed()))
            }
            if !trackIDs.isEmpty {
                try await client.updatePlaylist(id: playlistID, appendTrackIDs: trackIDs)
            }
            await refreshCachedPlaylists(serverID: client.configuration.serverID)
            return true
        } catch {
            return false
        }
    }

    public func deletePlaylist(playlistID: PlaylistID) async -> Bool {
        guard let client = activeClient else { return false }
        do {
            try await client.deletePlaylist(id: playlistID)
            await refreshCachedPlaylists(serverID: client.configuration.serverID)
            return true
        } catch {
            return false
        }
    }

    /// 拉取歌单内的完整曲目列表（getPlaylist 单数端点）。
    public func fetchPlaylistTracks(playlistID: PlaylistID) async -> [Track] {
        guard let client = activeClient else { return [] }
        do {
            let detail = try await client.playlist(id: playlistID)
            var tracks = detail.tracks
            // 为歌单内的曲目也构造 stream URL
            for index in tracks.indices {
                tracks[index].streamURL = await Self.makeStreamURL(client: client, trackID: tracks[index].id.rawValue, quality: streamQuality)
            }
            // 把歌单最新曲目列表写回本地缓存，冷启动后详情可直接展示，与服务器一致。
            let serverID = client.configuration.serverID
            if let cached = await auxiliaryCache.snapshot(serverID: serverID) {
                var playlists = cached.playlists
                if let index = playlists.firstIndex(where: { $0.id == playlistID }) {
                    playlists[index].trackIDs = tracks.map(\.id)
                    await auxiliaryCache.updatePlaylists(playlists, serverID: serverID)
                }
            }
            return tracks
        } catch {
            return []
        }
    }

    /// 从服务器拉取最新歌单列表并写入本地辅助缓存（歌单写操作成功后调用）。
    /// 失败时静默保留旧缓存，界面继续用现有数据。
    private func refreshCachedPlaylists(serverID: ServerID) async {
        guard let client = activeClient else { return }
        if let fresh = try? await client.playlists() {
            await auxiliaryCache.updatePlaylists(fresh, serverID: serverID)
        }
    }

    // MARK: - 标注

    public func setAlbumFavorite(albumID: AlbumID, isFavorite: Bool) async {
        guard let client = activeClient else { return }
        if isFavorite {
            try? await client.star(.album(albumID))
        } else {
            try? await client.unstar(.album(albumID))
        }
    }

    public func setArtistFavorite(artistID: ArtistID, isFavorite: Bool) async {
        guard let client = activeClient else { return }
        if isFavorite {
            try? await client.star(.artist(artistID))
        } else {
            try? await client.unstar(.artist(artistID))
        }
    }

    public func setRating(trackID: TrackID, rating: Int) async {
        guard let client = activeClient else { return }
        try? await client.setRating(min(max(rating, 0), 5), trackID: trackID)
    }

    // MARK: - 服务器

    public func ping() async -> Bool {
        guard let client = activeClient else { return false }
        do {
            try await client.ping()
            return true
        } catch {
            return false
        }
    }

    public func disconnect() async {
        activeClient = nil
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
        await auxiliaryCache.purge(serverID: serverID)
        activeClient = nil
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

    private func validate(_ input: ServerConnectionInput) throws {
        try ServerURLPolicy.validate(input.baseURL)
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

