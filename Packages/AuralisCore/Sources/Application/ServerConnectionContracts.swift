import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import OpenSubsonicKit
import SecurityKit

public struct ServerConnectionInput: Sendable {
    public var displayName: String
    /// 内网入口，连接时优先选用。
    public var baseURL: URL
    /// 可选的外网入口；仅在内网端点确认不可达时降级使用。
    public var externalBaseURL: URL?
    public var username: String
    public var password: String

    public init(
        displayName: String,
        baseURL: URL,
        externalBaseURL: URL? = nil,
        username: String,
        password: String
    ) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.externalBaseURL = externalBaseURL
        self.username = username
        self.password = password
    }
}

/// 已保存服务器的本机连接配置编辑值；密码留空时继续使用 Keychain 中现有凭据。
public struct ServerConfigurationUpdate: Sendable {
    public var displayName: String
    public var baseURL: URL
    public var externalBaseURL: URL?
    public var username: String
    public var password: String?

    public init(displayName: String, baseURL: URL, externalBaseURL: URL?, username: String, password: String?) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.externalBaseURL = externalBaseURL
        self.username = username
        self.password = password
    }
}

/// 连接测试结果：只包含可安全展示的服务器信息，不含凭据。
public struct ServerConnectionTestResult: Sendable {
    public let serverType: String?
    public let serverVersion: String?
    public let apiVersion: String?
    public let username: String?

    public init(serverType: String?, serverVersion: String?, apiVersion: String? = nil, username: String? = nil) {
        self.serverType = serverType
        self.serverVersion = serverVersion
        self.apiVersion = apiVersion
        self.username = username
    }
}

public struct ServerConnectionResult: Sendable {
    public let account: ServerAccount
    public let capabilities: ServerCapabilities
    public let artists: [Artist]
    public let albums: [Album]
    public let tracks: [Track]
    public let genres: [Genre]
    public let playlists: [Playlist]
    public let serverType: String?
    public let serverVersion: String?

    public init(
        account: ServerAccount,
        capabilities: ServerCapabilities,
        artists: [Artist],
        albums: [Album],
        tracks: [Track],
        genres: [Genre] = [],
        playlists: [Playlist] = [],
        serverType: String? = nil,
        serverVersion: String? = nil
    ) {
        self.account = account
        self.capabilities = capabilities
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.genres = genres
        self.playlists = playlists
        self.serverType = serverType
        self.serverVersion = serverVersion
    }
}

/// 后台增量刷新的辅助数据结果：歌单、流派与服务器收藏（getStarred2）。
/// 收藏是「服务器权威」回流：以 getStarred2 的完整集合为准，覆盖本地展示。
public struct AuxiliaryLibraryData: Sendable {
    public let playlists: [Playlist]
    /// `true` 仅表示本轮 getPlaylists 成功返回完整集合；失败回退缓存时不能把
    /// 本地尚未确认的删除当作“服务器重新创建”。
    public let playlistsAreAuthoritative: Bool
    public let genres: [Genre]
    public let favoriteTrackIDs: [String]
    /// `true` 仅表示本轮 getStarred2 成功返回完整集合；失败回退缓存时绝不能清空本地收藏。
    public let favoriteTrackIDsAreAuthoritative: Bool

    public init(
        playlists: [Playlist],
        playlistsAreAuthoritative: Bool = false,
        genres: [Genre],
        favoriteTrackIDs: [String] = [],
        favoriteTrackIDsAreAuthoritative: Bool = false
    ) {
        self.playlists = playlists
        self.playlistsAreAuthoritative = playlistsAreAuthoritative
        self.genres = genres
        self.favoriteTrackIDs = favoriteTrackIDs
        self.favoriteTrackIDsAreAuthoritative = favoriteTrackIDsAreAuthoritative
    }
}

public struct LibraryRevisionProbe: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// 服务器提供的真实单调 revision / scan id。
        case authoritativeRevision
        /// 专辑 ID、名称、曲目数等轻量元数据的稳定指纹；不能覆盖单曲级元数据变化。
        case albumFingerprint
        /// 仅有总数，只能发现数量变化，绝不能单独证明资料库未变化。
        case countOnly
    }

    public let kind: Kind
    public let fingerprint: String?
    public let songCount: Int?
    public let fetchedAt: Date

    public init(kind: Kind, fingerprint: String?, songCount: Int?, fetchedAt: Date = .now) {
        self.kind = kind
        self.fingerprint = fingerprint
        self.songCount = songCount
        self.fetchedAt = fetchedAt
    }
}

public protocol ServerConnecting: Sendable {
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult
    func connect(
        _ input: ServerConnectionInput,
        progress: @escaping @Sendable (ServerConnectionStage) async -> Void
    ) async throws -> ServerConnectionResult
    func restoreLastConnection() async throws -> ServerConnectionResult?
    /// 恢复指定服务器的本地资料库（不联网出界面）。默认退化为 restoreLastConnection()。
    func restoreConnection(serverID: ServerID) async throws -> ServerConnectionResult?
    /// 用当前服务器凭据重新做一次全量同步并返回最新资料库（旧快照为空时自愈界面）。
    /// 默认退化为 restoreConnection（不联网）。
    func resync(serverID: ServerID) async throws -> ServerConnectionResult?

    // MARK: 远程实体请求（所有方法显式携带 serverID / Track，禁止依赖“当前活跃服务器”）

    /// 按需从服务器拉取单曲歌词（结构化歌词优先，空时回退传统 getLyrics 纯文本）；
    /// 未连接或服务器不支持时返回 nil。`track` 自带 serverID。
    func lyrics(for track: Track) async -> LyricsDocument?
    /// 渐进缓存用：拉取歌词并区分「失败」与「服务器无歌词」。
    /// 返回 nil = 服务器确认没有歌词；抛出错误 = 网络/认证等失败（不是无歌词）。
    func fetchLyrics(for track: Track) async throws -> LyricsDocument?
    /// 上报单曲已完成播放（scrobble submission=true），让服务器更新播放次数。
    /// Navidrome 只在 scrobble(submission=true) 时标记已播放；未连接时静默忽略。
    func scrobble(serverID: ServerID, trackID: TrackID, submission: Bool) async
    /// 按需从服务器拉取封面图片数据；未连接或失败时返回 nil。
    func artworkData(serverID: ServerID, key: String, targetPixelSize: Int) async -> Data?
    /// 从服务器拉取流派列表（getGenres）；失败时抛出，由调用方决定是否降级为空。
    func genres(serverID: ServerID) async throws -> [Genre]
    /// 后台增量刷新歌单与流派并写入本地辅助缓存。
    /// 冷启动先用本地缓存出界面，随后调用这里对照服务器更新；离线时返回 nil、保留缓存。
    func refreshAuxiliaryData(serverID: ServerID) async -> AuxiliaryLibraryData?
    /// 按流派从服务器拉取歌曲（getAlbumList2 type=byGenre 展开各专辑曲目）；
    /// Navidrome 等服务器 getGenres 常为空，但按流派列专辑可用，
    /// 因此即便本地没有流派标签，进入某个流派也能拉到真实歌曲。失败时抛出。
    func tracks(byGenre name: String, serverID: ServerID) async throws -> [Track]
    /// 重新获取单曲的带认证播放地址（流地址过期 / 播放失败后刷新）。
    /// 返回的 URL 只用于 AVPlayer 内部播放，不得发送给大模型。
    func refreshStreamURL(serverID: ServerID, trackID: TrackID) async -> URL?
    /// 在服务器上在线搜索歌曲（本地无结果时使用）；失败时抛出（与“无结果”区分）。
    func serverSearch(query: String, limit: Int, serverID: ServerID) async throws -> [Track]
    /// 按 ID 从服务器拉取单曲（getSong）并补流地址；本地目录未同步时用于在线流播。
    /// 失败时抛出（与“确实不存在”区分）。
    func serverTrack(serverID: ServerID, trackID: TrackID) async throws -> Track?
    /// 轻量获取服务器音乐库的曲目总数（getAlbumList2 各专辑 songCount 求和）。
    /// 用于启动/回前台时与本地目录曲目数比对：一致则跳过整库拉取。未连接/不支持/失败返回 nil（= 不跳过）。
    func librarySongCount(serverID: ServerID) async -> Int?
    /// 轻量远端修订探针。countOnly 不能作为“无需同步”的充分条件。
    func libraryRevisionProbe(serverID: ServerID) async -> LibraryRevisionProbe?
    /// 生成带认证的下载地址（供后台下载任务使用）；未连接或失败返回 nil。
    func downloadURL(serverID: ServerID, trackID: TrackID) async -> URL?
    /// 下载单曲完整音频数据（用于本地缓存）；未连接或失败时返回 nil。
    func downloadData(serverID: ServerID, trackID: TrackID) async -> Data?
    /// 把单曲追加到服务器歌单；成功返回 true。
    func addToPlaylist(serverID: ServerID, playlistID: PlaylistID, trackID: TrackID) async -> Bool
    /// 同步单曲收藏状态到服务器（star/unstar）。
    func setFavorite(serverID: ServerID, trackID: TrackID, isFavorite: Bool) async -> Bool
    /// 用指定服务器构建一个资料库同步器；未连接时返回 nil。
    func makeSynchronizer(serverID: ServerID, store: LocalCatalogStore) async -> LibrarySynchronizer?

    // MARK: 歌单编辑（Agent 与 UI 共用）

    /// 新建歌单，成功返回服务器分配的歌单。
    func createPlaylist(serverID: ServerID, name: String, trackIDs: [TrackID]) async -> Playlist?
    /// 重命名歌单。
    func renamePlaylist(serverID: ServerID, playlistID: PlaylistID, name: String) async -> Bool
    /// 按下标移除歌单中的曲目。
    func removeFromPlaylist(serverID: ServerID, playlistID: PlaylistID, indices: [Int]) async -> Bool
    /// 用给定顺序整体覆盖歌单曲目（用于重排）。实现必须为单次服务器请求，
    /// 禁止「先清空再追加」的两步窗口（R02）。
    func replacePlaylistTracks(serverID: ServerID, playlistID: PlaylistID, trackIDs: [TrackID]) async -> Bool
    /// 删除歌单。
    func deletePlaylist(serverID: ServerID, playlistID: PlaylistID) async -> Bool
    /// 拉取歌单内的曲目（getPlaylist 单数端点，含完整 entry）；失败时抛出。
    func fetchPlaylistTracks(serverID: ServerID, playlistID: PlaylistID) async throws -> [Track]

    // MARK: 标注

    /// 收藏 / 取消收藏专辑。
    func setAlbumFavorite(serverID: ServerID, albumID: AlbumID, isFavorite: Bool) async -> Bool
    /// 收藏 / 取消收藏艺术家。
    func setArtistFavorite(serverID: ServerID, artistID: ArtistID, isFavorite: Bool) async -> Bool
    /// 设置单曲评分（0 表示清除）。
    func setRating(serverID: ServerID, trackID: TrackID, rating: Int) async -> Bool

    // MARK: 服务器

    /// 对指定服务器发一次心跳，验证连通性。
    func ping(serverID: ServerID) async -> Bool
    /// 断开所有连接并清理内存中的客户端（不删除任何远端数据）。
    func disconnect() async
    /// 删除本地保存的服务器凭据与持久化资料库（仅本地，远端不受影响）。
    func forgetServer(serverID: ServerID) async
    /// 修改服务器显示名称（持久化，不影响凭据与连接）。
    func updateServerDisplayName(serverID: ServerID, displayName: String) async -> Bool
    /// 更新已保存服务器的外网降级地址；不改变内网地址、账号 ID 或凭据。
    func updateServerExternalBaseURL(serverID: ServerID, externalBaseURL: URL?) async -> Bool
    /// 编辑已保存连接而不新建服务器；成功返回更新后的本地账户。
    func updateServerConfiguration(serverID: ServerID, update: ServerConfigurationUpdate) async -> ServerAccount?
    /// 备份恢复：把服务器账号与登录凭据写回本地持久化（不联网、不触发资料同步）。
    /// `secret` 为解密后的登录密码 / Token，仅在备份恢复流程中传入。
    func restoreAccountFromBackup(_ account: ServerAccount, secret: String?) async throws
    /// 用「用户当前输入」执行一次真实连接测试：不保存凭据、不同步、不改变当前连接。
    /// 失败时抛出分类错误（地址/认证/网络/超时/非 OpenSubsonic 等）。
    func testConnection(_ input: ServerConnectionInput) async throws -> ServerConnectionTestResult
}

public extension ServerConnecting {
    func connect(
        _ input: ServerConnectionInput,
        progress: @escaping @Sendable (ServerConnectionStage) async -> Void
    ) async throws -> ServerConnectionResult {
        await progress(.authenticating)
        return try await connect(input)
    }

    func restoreLastConnection() async throws -> ServerConnectionResult? { nil }
    func restoreConnection(serverID: ServerID) async throws -> ServerConnectionResult? {
        try await restoreLastConnection()
    }
    func resync(serverID: ServerID) async throws -> ServerConnectionResult? {
        try await restoreConnection(serverID: serverID)
    }
    func lyrics(for track: Track) async -> LyricsDocument? { nil }
    func fetchLyrics(for track: Track) async throws -> LyricsDocument? { nil }
    func scrobble(serverID: ServerID, trackID: TrackID, submission: Bool) async {}
    func artworkData(serverID: ServerID, key: String, targetPixelSize: Int) async -> Data? { nil }
    func genres(serverID: ServerID) async throws -> [Genre] { [] }
    func refreshAuxiliaryData(serverID: ServerID) async -> AuxiliaryLibraryData? { nil }
    func tracks(byGenre name: String, serverID: ServerID) async throws -> [Track] { [] }
    func refreshStreamURL(serverID: ServerID, trackID: TrackID) async -> URL? { nil }
    func serverSearch(query: String, limit: Int, serverID: ServerID) async throws -> [Track] { [] }
    func serverTrack(serverID: ServerID, trackID: TrackID) async throws -> Track? { nil }
    func librarySongCount(serverID: ServerID) async -> Int? { nil }
    func libraryRevisionProbe(serverID: ServerID) async -> LibraryRevisionProbe? {
        guard let count = await librarySongCount(serverID: serverID) else { return nil }
        return LibraryRevisionProbe(kind: .countOnly, fingerprint: nil, songCount: count)
    }
    func downloadURL(serverID: ServerID, trackID: TrackID) async -> URL? { nil }
    func downloadData(serverID: ServerID, trackID: TrackID) async -> Data? { nil }
    func addToPlaylist(serverID: ServerID, playlistID: PlaylistID, trackID: TrackID) async -> Bool { false }
    func setFavorite(serverID: ServerID, trackID: TrackID, isFavorite: Bool) async -> Bool { false }
    func makeSynchronizer(serverID: ServerID, store: LocalCatalogStore) async -> LibrarySynchronizer? { nil }
    func restoreAccountFromBackup(_ account: ServerAccount, secret: String?) async throws {
        throw ServerConnectionError.unsupportedResponse
    }
    func testConnection(_ input: ServerConnectionInput) async throws -> ServerConnectionTestResult {
        throw ServerConnectionError.unsupportedResponse
    }

    func createPlaylist(serverID: ServerID, name: String, trackIDs: [TrackID]) async -> Playlist? { nil }
    func renamePlaylist(serverID: ServerID, playlistID: PlaylistID, name: String) async -> Bool { false }
    func removeFromPlaylist(serverID: ServerID, playlistID: PlaylistID, indices: [Int]) async -> Bool { false }
    func replacePlaylistTracks(serverID: ServerID, playlistID: PlaylistID, trackIDs: [TrackID]) async -> Bool { false }
    func deletePlaylist(serverID: ServerID, playlistID: PlaylistID) async -> Bool { false }
    func fetchPlaylistTracks(serverID: ServerID, playlistID: PlaylistID) async throws -> [Track] { [] }

    func setAlbumFavorite(serverID: ServerID, albumID: AlbumID, isFavorite: Bool) async -> Bool { false }
    func setArtistFavorite(serverID: ServerID, artistID: ArtistID, isFavorite: Bool) async -> Bool { false }
    func setRating(serverID: ServerID, trackID: TrackID, rating: Int) async -> Bool { false }

    func ping(serverID: ServerID) async -> Bool { false }
    func disconnect() async {}
    func forgetServer(serverID: ServerID) async {}
    func updateServerDisplayName(serverID: ServerID, displayName: String) async -> Bool { false }
    func updateServerExternalBaseURL(serverID: ServerID, externalBaseURL: URL?) async -> Bool { false }
    func updateServerConfiguration(serverID: ServerID, update: ServerConfigurationUpdate) async -> ServerAccount? { nil }
}

public enum ServerConnectionStage: String, CaseIterable, Equatable, Sendable {
    case validating
    case storingCredential
    case authenticating
    case detectingCapabilities
    case loadingLibrary
    case savingLibrary

    public var title: String {
        switch self {
        case .validating: String(localized: "检查地址", bundle: .module)
        case .storingCredential: String(localized: "保护凭据", bundle: .module)
        case .authenticating: String(localized: "验证服务器", bundle: .module)
        case .detectingCapabilities: String(localized: "检测能力", bundle: .module)
        case .loadingLibrary: String(localized: "读取音乐库", bundle: .module)
        case .savingLibrary: String(localized: "保存资料库", bundle: .module)
        }
    }
}

public enum ServerConnectionError: Error, Equatable, LocalizedError, Sendable {
    case missingDisplayName
    case invalidURL
    case embeddedCredentials
    case insecurePublicServer
    case missingUsername
    case missingCredential
    case authenticationFailed
    case serverUnavailable
    case emptyLibrary
    case secureStorageUnavailable
    case libraryStorageUnavailable
    case unsupportedResponse
    case cancelled
    case unexpected

    public var errorDescription: String? {
        switch self {
        case .missingDisplayName: String(localized: "请输入服务器名称。", bundle: .module)
        case .invalidURL: String(localized: "服务器地址无效，请包含 http:// 或 https://。", bundle: .module)
        case .embeddedCredentials: String(localized: "服务器地址不能内嵌用户名或密码（如 user:pass@host）。请把用户名与密码填写在对应输入框。", bundle: .module)
        case .insecurePublicServer: String(localized: "公共网络服务器必须使用 HTTPS；HTTP 仅允许本机或私有局域网地址。", bundle: .module)
        case .missingUsername: String(localized: "请输入用户名。", bundle: .module)
        case .missingCredential: String(localized: "请输入密码或 API Key。", bundle: .module)
        case .authenticationFailed: String(localized: "认证失败，请检查用户名和凭据。", bundle: .module)
        case .serverUnavailable: String(localized: "无法访问服务器，请检查地址、网络和服务状态。", bundle: .module)
        case .emptyLibrary: String(localized: "服务器连接成功，但当前账户没有可见歌曲。", bundle: .module)
        case .secureStorageUnavailable: String(localized: "无法访问系统 Keychain，请解锁设备后重试。", bundle: .module)
        case .libraryStorageUnavailable: String(localized: "无法安全保存音乐库，请检查可用空间后重试。", bundle: .module)
        case .unsupportedResponse: String(localized: "服务器返回了无法识别的 OpenSubsonic 响应。", bundle: .module)
        case .cancelled: String(localized: "连接已取消，未完成的资料不会覆盖本地音乐库。", bundle: .module)
        case .unexpected: String(localized: "连接未完成。请重试；如问题持续，请检查服务器兼容性。", bundle: .module)
        }
    }
}

public enum ServerURLPolicy {
    public static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              scheme == "http" || scheme == "https"
        else {
            throw ServerConnectionError.invalidURL
        }
        // 拒绝内嵌凭据（user:pass@host）：URL 中的密码会随地址明文落库、进日志与备份，
        // 违背「生产凭据只进 Keychain」的隐私模型。
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.user != nil || components.password != nil {
            throw ServerConnectionError.embeddedCredentials
        }
        if scheme == "http", !NetworkHostClassifier.isPrivateOrLocal(host: host) {
            throw ServerConnectionError.insecurePublicServer
        }
    }

    public static func isPrivateOrLocal(host: String) -> Bool {
        NetworkHostClassifier.isPrivateOrLocal(host: host)
    }
}


/// 统一把连接错误翻译成可读中文分类，供 iOS / macOS 设置页共用。
/// 区分：地址格式 / 认证 / 超时 / 找不到主机 / 无法连接 / 网络不可用 /
/// 本地网络权限 / ATS 拦截 / 非 OpenSubsonic 响应 / API 不兼容 / HTTP 错误。
public enum ConnectionErrorDescription {
    public static func describe(_ error: Error) -> String {
        if let error = error as? ServerConnectionError {
            return error.localizedDescription
        }
        if let error = error as? CredentialVaultError {
            switch error {
            case .unavailable:
                return String(localized: "无法访问系统 Keychain（可能被锁定或签名受限）。请解锁 Mac 后重试；测试连接使用内存凭据，不受影响。", bundle: .module)
            case let .operationFailed(status):
                return String(localized: "系统 Keychain 写入失败（状态 \(status)）。请解锁 Mac 后重试；凭据不会被保存到不安全位置。", bundle: .module)
            default:
                return error.localizedDescription
            }
        }
        if let error = error as? OpenSubsonicClientError {
            switch error {
            case let .server(code, message):
                return String(localized: "服务器返回错误（代码 \(code)）：\(message)", bundle: .module)
            case let .serverFailure(serverError):
                return String(localized: "服务器返回错误（代码 \(serverError.code)）：\(serverError.message)", bundle: .module)
            case let .httpStatus(status):
                return String(localized: "服务器返回 HTTP \(status)", bundle: .module)
            case let .transport(code, host):
                return Self.transport(code, host: host)
            case .malformedResponse, .missingPayload:
                return String(localized: "服务器返回的不是有效的 OpenSubsonic 响应", bundle: .module)
            case .invalidBaseURL:
                return String(localized: "服务器地址格式错误", bundle: .module)
            case let .invalidConfiguration(reason):
                return String(localized: "连接配置无效：\(reason)", bundle: .module)
            case let .invalidParameter(name):
                return String(localized: "请求参数无效：\(name)", bundle: .module)
            case let .unsupportedCapability(name):
                return String(localized: "服务器不支持该功能：\(name)（API 版本可能不兼容）", bundle: .module)
            }
        }
        if let error = error as? URLError {
            return Self.transport(error.code.rawValue, host: error.failingURL?.host)
        }
        return error.localizedDescription
    }

    private static func transport(_ code: Int, host: String? = nil) -> String {
        switch code {
        case NSURLErrorTimedOut:
            return String(localized: "连接超时，请检查服务器地址与网络", bundle: .module) + localNetworkHint(host: host)
        case NSURLErrorCannotFindHost:
            return String(localized: "找不到主机，请检查服务器地址（IP / 主机名 / .local）", bundle: .module) + localNetworkHint(host: host)
        case NSURLErrorCannotConnectToHost:
            return String(localized: "无法连接到服务器（服务器可能未启动或拒绝连接）", bundle: .module) + localNetworkHint(host: host)
        case NSURLErrorNotConnectedToInternet:
            return String(localized: "网络不可用", bundle: .module) + localNetworkHint(host: host)
        case NSURLErrorNetworkConnectionLost:
            return String(localized: "网络连接中断", bundle: .module) + localNetworkHint(host: host)
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return String(localized: "HTTPS 连接失败（证书不受信任或被安全策略拦截）", bundle: .module)
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return String(localized: "该地址被 App Transport Security 拦截（局域网 HTTP 请确认已允许本地网络）", bundle: .module)
        default:
            return String(localized: "网络错误（\(code)）", bundle: .module)
        }
    }

    /// 当失败目标是局域网/本机地址时，网络层 -1009 / -1004 / -1005 通常代表
    /// 「本地网络」权限未授予或 Mac 与服务器不在同一网络，给出可操作的排查指引。
    /// 公共地址保持通用提示，避免把普通断网误判为权限问题。
    private static func localNetworkHint(host: String?) -> String {
        guard let host, ServerURLPolicy.isPrivateOrLocal(host: host) else {
            return String(localized: "，请检查网络连接", bundle: .module)
        }
        #if os(macOS)
        return String(localized: "。若是局域网地址（\(host)），请检查 系统设置 → 隐私与安全性 → 本地网络 是否允许「Auralis」访问本地网络，并确认 Mac 与服务器在同一网络。", bundle: .module)
        #else
        return String(localized: "。若是局域网地址（\(host)），请检查 设置 → 隐私与安全性 → 本地网络 是否允许「Auralis」访问本地网络，并确认设备与服务器在同一网络。", bundle: .module)
        #endif
    }
}
