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
    /// 按需从服务器拉取单曲歌词（结构化歌词优先，空时回退传统 getLyrics 纯文本）；
    /// 未连接或服务器不支持时返回 nil。
    func lyrics(for track: Track) async -> LyricsDocument?
    /// 渐进缓存用：拉取歌词并区分「失败」与「服务器无歌词」。
    /// 返回 nil = 服务器确认没有歌词；抛出错误 = 网络/认证等失败（不是无歌词）。
    func fetchLyrics(for track: Track) async throws -> LyricsDocument?
    /// 上报单曲已完成播放（scrobble submission=true），让服务器更新播放次数。
    /// Navidrome 只在 scrobble(submission=true) 时标记已播放；未连接时静默忽略。
    func scrobble(trackID: TrackID, submission: Bool) async
    /// 按需从服务器拉取封面图片数据；未连接或失败时返回 nil。
    func artworkData(key: String, targetPixelSize: Int) async -> Data?
    /// 从服务器拉取流派列表（getGenres）；未连接或失败时返回空数组。
    func genres() async -> [Genre]
    /// 后台增量刷新歌单与流派并写入本地辅助缓存。
    /// 冷启动先用本地缓存出界面，随后调用这里对照服务器更新；离线时返回 nil、保留缓存。
    func refreshAuxiliaryData() async -> AuxiliaryLibraryData?
    /// 按流派从服务器拉取歌曲（getAlbumList2 type=byGenre 展开各专辑曲目）；
    /// Navidrome 等服务器 getGenres 常为空，但按流派列专辑可用，
    /// 因此即便本地没有流派标签，进入某个流派也能拉到真实歌曲。未连接或失败时返回空。
    func tracks(byGenre name: String) async -> [Track]
    /// 重新获取单曲的带认证播放地址（流地址过期 / 播放失败后刷新）。
    /// 返回的 URL 只用于 AVPlayer 内部播放，不得发送给大模型。
    func refreshStreamURL(trackID: TrackID) async -> URL?
    /// 在服务器上在线搜索歌曲（本地无结果时使用）；未连接或失败返回空数组。
    func serverSearch(query: String, limit: Int) async -> [Track]
    /// 按 ID 从服务器拉取单曲（getSong）并补流地址；本地目录未同步时用于在线流播。未连接或失败返回 nil。
    func serverTrack(trackID: TrackID) async -> Track?
    /// 轻量获取服务器音乐库的曲目总数（getAlbumList2 各专辑 songCount 求和）。
    /// 用于启动/回前台时与本地目录曲目数比对：一致则跳过整库拉取。未连接/不支持/失败返回 nil（= 不跳过）。
    func librarySongCount() async -> Int?
    /// 生成带认证的下载地址（供后台下载任务使用）；未连接或失败返回 nil。
    func downloadURL(trackID: TrackID) async -> URL?
    /// 下载单曲完整音频数据（用于本地缓存）；未连接或失败时返回 nil。
    func downloadData(trackID: TrackID) async -> Data?
    /// 把单曲追加到服务器歌单；成功返回 true。
    func addToPlaylist(playlistID: PlaylistID, trackID: TrackID) async -> Bool
    /// 同步单曲收藏状态到服务器（star/unstar）。
    func setFavorite(trackID: TrackID, isFavorite: Bool) async
    /// 用当前已认证服务器构建一个资料库同步器；未连接时返回 nil。
    func makeSynchronizer(store: LocalCatalogStore) async -> LibrarySynchronizer?

    // MARK: 歌单编辑（Agent 与 UI 共用）

    /// 新建歌单，成功返回服务器分配的歌单。
    func createPlaylist(name: String, trackIDs: [TrackID]) async -> Playlist?
    /// 重命名歌单。
    func renamePlaylist(playlistID: PlaylistID, name: String) async -> Bool
    /// 按下标移除歌单中的曲目。
    func removeFromPlaylist(playlistID: PlaylistID, indices: [Int]) async -> Bool
    /// 用给定顺序整体覆盖歌单曲目（用于重排）。
    func replacePlaylistTracks(playlistID: PlaylistID, trackIDs: [TrackID]) async -> Bool
    /// 删除歌单。
    func deletePlaylist(playlistID: PlaylistID) async -> Bool
    /// 拉取歌单内的曲目（getPlaylist 单数端点，含完整 entry）。
    func fetchPlaylistTracks(playlistID: PlaylistID) async -> [Track]

    // MARK: 标注

    /// 收藏 / 取消收藏专辑。
    func setAlbumFavorite(albumID: AlbumID, isFavorite: Bool) async
    /// 收藏 / 取消收藏艺术家。
    func setArtistFavorite(artistID: ArtistID, isFavorite: Bool) async
    /// 设置单曲评分（0 表示清除）。
    func setRating(trackID: TrackID, rating: Int) async

    // MARK: 服务器

    /// 对当前已连接服务器发一次心跳，验证连通性。
    func ping() async -> Bool
    /// 断开当前连接并清理内存中的客户端（不删除任何远端数据）。
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
    func restoreAccountFromBackup(_ account: ServerAccount, secret: String?) async
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
    func scrobble(trackID: TrackID, submission: Bool) async {}
    func artworkData(key: String, targetPixelSize: Int) async -> Data? { nil }
    func genres() async -> [Genre] { [] }
    func refreshAuxiliaryData() async -> AuxiliaryLibraryData? { nil }
    func tracks(byGenre name: String) async -> [Track] { [] }
    func refreshStreamURL(trackID: TrackID) async -> URL? { nil }
    func serverSearch(query: String, limit: Int) async -> [Track] { [] }
    func serverTrack(trackID: TrackID) async -> Track? { nil }
    func librarySongCount() async -> Int? { nil }
    func downloadURL(trackID: TrackID) async -> URL? { nil }
    func downloadData(trackID: TrackID) async -> Data? { nil }
    func addToPlaylist(playlistID: PlaylistID, trackID: TrackID) async -> Bool { false }
    func setFavorite(trackID: TrackID, isFavorite: Bool) async {}
    func makeSynchronizer(store: LocalCatalogStore) async -> LibrarySynchronizer? { nil }
    func restoreAccountFromBackup(_ account: ServerAccount, secret: String?) async {}
    func testConnection(_ input: ServerConnectionInput) async throws -> ServerConnectionTestResult {
        throw ServerConnectionError.unsupportedResponse
    }

    func createPlaylist(name: String, trackIDs: [TrackID]) async -> Playlist? { nil }
    func renamePlaylist(playlistID: PlaylistID, name: String) async -> Bool { false }
    func removeFromPlaylist(playlistID: PlaylistID, indices: [Int]) async -> Bool { false }
    func replacePlaylistTracks(playlistID: PlaylistID, trackIDs: [TrackID]) async -> Bool { false }
    func deletePlaylist(playlistID: PlaylistID) async -> Bool { false }
    func fetchPlaylistTracks(playlistID: PlaylistID) async -> [Track] { [] }

    func setAlbumFavorite(albumID: AlbumID, isFavorite: Bool) async {}
    func setArtistFavorite(artistID: ArtistID, isFavorite: Bool) async {}
    func setRating(trackID: TrackID, rating: Int) async {}

    func ping() async -> Bool { false }
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
        case .validating: String(localized: "检查地址")
        case .storingCredential: String(localized: "保护凭据")
        case .authenticating: String(localized: "验证服务器")
        case .detectingCapabilities: String(localized: "检测能力")
        case .loadingLibrary: String(localized: "读取音乐库")
        case .savingLibrary: String(localized: "保存资料库")
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
        case .missingDisplayName: "请输入服务器名称。"
        case .invalidURL: "服务器地址无效，请包含 http:// 或 https://。"
        case .embeddedCredentials: "服务器地址不能内嵌用户名或密码（如 user:pass@host）。请把用户名与密码填写在对应输入框。"
        case .insecurePublicServer: "公共网络服务器必须使用 HTTPS；HTTP 仅允许本机或私有局域网地址。"
        case .missingUsername: "请输入用户名。"
        case .missingCredential: "请输入密码或 API Key。"
        case .authenticationFailed: "认证失败，请检查用户名和凭据。"
        case .serverUnavailable: "无法访问服务器，请检查地址、网络和服务状态。"
        case .emptyLibrary: "服务器连接成功，但当前账户没有可见歌曲。"
        case .secureStorageUnavailable: "无法访问系统 Keychain，请解锁设备后重试。"
        case .libraryStorageUnavailable: "无法安全保存音乐库，请检查可用空间后重试。"
        case .unsupportedResponse: "服务器返回了无法识别的 OpenSubsonic 响应。"
        case .cancelled: "连接已取消，未完成的资料不会覆盖本地音乐库。"
        case .unexpected: "连接未完成。请重试；如问题持续，请检查服务器兼容性。"
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
        if scheme == "http", !isPrivateOrLocal(host: host) {
            throw ServerConnectionError.insecurePublicServer
        }
    }

    public static func isPrivateOrLocal(host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized.hasSuffix(".local") { return true }
        if normalized == "::1" { return true }
        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ 0...255 ~= $0 }) else { return false }
        if octets[0] == 10 || octets[0] == 127 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 169 && octets[1] == 254 { return true }
        return false
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
                return "无法访问系统 Keychain（可能被锁定或签名受限）。请解锁 Mac 后重试；测试连接使用内存凭据，不受影响。"
            case let .operationFailed(status):
                return "系统 Keychain 写入失败（状态 \(status)）。请解锁 Mac 后重试；凭据不会被保存到不安全位置。"
            default:
                return error.localizedDescription
            }
        }
        if let error = error as? OpenSubsonicClientError {
            switch error {
            case let .server(code, message):
                return "服务器返回错误（代码 \(code)）：\(message)"
            case let .serverFailure(serverError):
                return "服务器返回错误（代码 \(serverError.code)）：\(serverError.message)"
            case let .httpStatus(status):
                return "服务器返回 HTTP \(status)"
            case let .transport(code, host):
                return Self.transport(code, host: host)
            case .malformedResponse, .missingPayload:
                return "服务器返回的不是有效的 OpenSubsonic 响应"
            case .invalidBaseURL:
                return "服务器地址格式错误"
            case let .invalidConfiguration(reason):
                return "连接配置无效：\(reason)"
            case let .invalidParameter(name):
                return "请求参数无效：\(name)"
            case let .unsupportedCapability(name):
                return "服务器不支持该功能：\(name)（API 版本可能不兼容）"
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
            return "连接超时，请检查服务器地址与网络" + localNetworkHint(host: host)
        case NSURLErrorCannotFindHost:
            return "找不到主机，请检查服务器地址（IP / 主机名 / .local）" + localNetworkHint(host: host)
        case NSURLErrorCannotConnectToHost:
            return "无法连接到服务器（服务器可能未启动或拒绝连接）" + localNetworkHint(host: host)
        case NSURLErrorNotConnectedToInternet:
            return "网络不可用" + localNetworkHint(host: host)
        case NSURLErrorNetworkConnectionLost:
            return "网络连接中断" + localNetworkHint(host: host)
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "HTTPS 连接失败（证书不受信任或被安全策略拦截）"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "该地址被 App Transport Security 拦截（局域网 HTTP 请确认已允许本地网络）"
        default:
            return "网络错误（\(code)）"
        }
    }

    /// 当失败目标是局域网/本机地址时，网络层 -1009 / -1004 / -1005 通常代表
    /// 「本地网络」权限未授予或 Mac 与服务器不在同一网络，给出可操作的排查指引。
    /// 公共地址保持通用提示，避免把普通断网误判为权限问题。
    private static func localNetworkHint(host: String?) -> String {
        guard let host, ServerURLPolicy.isPrivateOrLocal(host: host) else {
            return "，请检查网络连接"
        }
        #if os(macOS)
        return "。若是局域网地址（\(host)），请检查 系统设置 → 隐私与安全性 → 本地网络 是否允许「澜音」访问本地网络，并确认 Mac 与服务器在同一网络。"
        #else
        return "。若是局域网地址（\(host)），请检查 设置 → 隐私与安全性 → 本地网络 是否允许「澜音」访问本地网络，并确认设备与服务器在同一网络。"
        #endif
    }
}
