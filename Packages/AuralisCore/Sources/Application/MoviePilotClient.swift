import Foundation
import SecurityKit

// MARK: - 配置

/// MoviePilot（MoviePilot 音乐下载插件）配置：普通字段存 UserDefaults，Token 存 Keychain。
public struct MoviePilotSettings: Sendable {
    public static let baseURLKey = "auralis.movipnote.baseURL"
    public static let tokenCredentialID = CredentialID(rawValue: "movipnote.music-token")
    public static let defaultHint = "http://<MoviePilot-Host>:3000"

    public var baseURL: String

    public init(defaults: UserDefaults = .standard) {
        baseURL = (defaults.string(forKey: Self.baseURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool { !baseURL.isEmpty }

    /// 把用户可能漏写协议的地址补全为合法 URL（IP/localhost 推断 http，其余 https）。
    public var normalizedURL: URL? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host != nil {
            return url
        }
        let hostPart = raw.replacingOccurrences(
            of: #"^[a-zA-Z][a-zA-Z0-9+.\-]*://"#,
            with: "",
            options: .regularExpression
        )
        let isLocal = hostPart.lowercased().hasPrefix("localhost")
            || hostPart.hasPrefix("127.0.0.1")
            || hostPart.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?"#, options: .regularExpression) != nil
        let scheme = isLocal ? "http" : "https"
        return URL(string: "\(scheme)://\(hostPart)")
    }
}

/// 一次调用所需的连接信息（地址 + 可选 Token），Token 只从 Keychain 读取。
public struct MoviePilotConnection: Sendable {
    public let baseURL: URL
    public let token: String?

    public init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }
}

// MARK: - 错误

public enum MoviePilotError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case pluginFailed(String)
    case transport(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            return message
        case let .pluginFailed(message):
            // 插件常见鉴权错误直接给出可操作提示（用户能看到真实原因而不是笼统的 HTTP 401）。
            if message.contains("apikey") || message.contains("校验不通过") {
                return "\(message)（请核对「音乐下载」设置里的 Token）"
            }
            return message
        case let .transport(message):
            return "网络请求失败：\(message)"
        case let .malformedResponse(message):
            return "响应解析失败：\(message)"
        }
    }
}

// MARK: - 宽松解码
//
// MoviePilot 站点搜索结果里的数值/布尔字段（seeders/grabs/size/quality/music 等）来自
// 各站点索引器，经不同 MoviePilot 版本透传后可能是 Int/Bool，也可能是 "34"/"true" 这类字符串。
// 用严格 Int?/Bool? 解码会整体抛「响应解析失败」，因此对插件字段做「字符串数字/字符串布尔」兼容。

private extension KeyedDecodingContainer {
    /// 数字字段兼容：Int / String("34") / Double / 缺失 / null → Int?
    func decodeLooseIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        if let raw = try? decode(String.self, forKey: key) {
            return Int(raw.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// 布尔字段兼容：Bool / String("true","1","yes","false","0","no") / 缺失 / null → Bool?
    func decodeLooseBoolIfPresent(forKey key: Key) throws -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let raw = try? decode(String.self, forKey: key) {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    /// 浮点字段兼容：Double / Int / String("5.0") / 缺失 / null → Double?
    func decodeLooseDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return Double(value) }
        if let raw = try? decode(String.self, forKey: key) {
            return Double(raw.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// 字符串字段兼容：String / Int / Double / 缺失 / null → String?
    func decodeLooseStringIfPresent(forKey key: Key) throws -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }
}

// MARK: - 响应 DTO（与插件 /api/v1/plugin/MusicDownloader 契约一致）

public struct MoviePilotEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    public let success: Bool
    public let message: String?
    public let data: T?
}

public struct MoviePilotSearchData: Decodable, Sendable {
    public let keyword: String?
    public let searchedSites: [String]?
    public let total: Int?
    public let albumMatchedAny: Bool?
    public let droppedVideo: Int?
    public let droppedUncertain: Int?
    public let fallbackTried: Bool?
    public let fallbackResolved: String?
    public let fallbackAlbum: String?
    public let kind: String?
    /// 本次生效的大小上限（GB）：单曲→max_size_gb，合集/降级→album_max_size_gb（v0.5.x）。
    public let sizeLimitGB: Double?
    public let sizeLimitApplied: Bool?
    public let results: [MoviePilotCandidate]?

    enum CodingKeys: String, CodingKey {
        case keyword, total, results, kind
        case searchedSites = "searched_sites"
        case albumMatchedAny = "album_matched_any"
        case droppedVideo = "dropped_video"
        case droppedUncertain = "dropped_uncertain"
        case fallbackTried = "fallback_tried"
        case fallbackResolved = "fallback_resolved"
        case fallbackAlbum = "fallback_album"
        case sizeLimitGB = "size_limit_gb"
        case sizeLimitApplied = "size_limit_applied"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword)
        searchedSites = try c.decodeIfPresent([String].self, forKey: .searchedSites)
        total = try c.decodeLooseIntIfPresent(forKey: .total)
        albumMatchedAny = try c.decodeLooseBoolIfPresent(forKey: .albumMatchedAny)
        droppedVideo = try c.decodeLooseIntIfPresent(forKey: .droppedVideo)
        droppedUncertain = try c.decodeLooseIntIfPresent(forKey: .droppedUncertain)
        fallbackTried = try c.decodeLooseBoolIfPresent(forKey: .fallbackTried)
        fallbackResolved = try c.decodeIfPresent(String.self, forKey: .fallbackResolved)
        fallbackAlbum = try c.decodeIfPresent(String.self, forKey: .fallbackAlbum)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        sizeLimitGB = try c.decodeLooseDoubleIfPresent(forKey: .sizeLimitGB)
        sizeLimitApplied = try c.decodeLooseBoolIfPresent(forKey: .sizeLimitApplied)
        results = try c.decodeIfPresent([MoviePilotCandidate].self, forKey: .results)
    }
}

public struct MoviePilotCandidate: Decodable, Sendable {
    public let index: Int?
    public let ref: String?
    public let siteId: Int?
    public let siteName: String?
    public let title: String?
    public let category: String?
    public let music: Bool?
    public let confidence: String?
    public let audioFormat: String?
    public let quality: Int?
    public let qualityLabel: String?
    public let relevance: Int?
    public let albumMatched: Bool?
    /// 体积（字节），插件可能返回数字或字符串，统一透传为字符串供展示/传回。
    public let size: String?
    public let sizeText: String?
    /// 个别版本在候选上带出大小上限（GB）；通常该值在 search 顶层 size_limit_gb。
    public let sizeLimitGB: Double?
    public let seeders: Int?
    public let grabs: Int?
    public let pubdate: String?
    public let enclosure: String?

    enum CodingKeys: String, CodingKey {
        case index, ref, title, category, music, confidence, quality, relevance, size, seeders, grabs, pubdate, enclosure
        case siteId = "site_id"
        case siteName = "site_name"
        case audioFormat = "audio_format"
        case qualityLabel = "quality_label"
        case albumMatched = "album_matched"
        case sizeText = "size_text"
        case sizeLimitGB = "size_limit_gb"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeLooseIntIfPresent(forKey: .index)
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        siteId = try c.decodeLooseIntIfPresent(forKey: .siteId)
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        music = try c.decodeLooseBoolIfPresent(forKey: .music)
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence)
        audioFormat = try c.decodeIfPresent(String.self, forKey: .audioFormat)
        quality = try c.decodeLooseIntIfPresent(forKey: .quality)
        qualityLabel = try c.decodeIfPresent(String.self, forKey: .qualityLabel)
        relevance = try c.decodeLooseIntIfPresent(forKey: .relevance)
        albumMatched = try c.decodeLooseBoolIfPresent(forKey: .albumMatched)
        size = try c.decodeLooseStringIfPresent(forKey: .size)
        sizeText = try c.decodeIfPresent(String.self, forKey: .sizeText)
        sizeLimitGB = try c.decodeLooseDoubleIfPresent(forKey: .sizeLimitGB)
        seeders = try c.decodeLooseIntIfPresent(forKey: .seeders)
        grabs = try c.decodeLooseIntIfPresent(forKey: .grabs)
        pubdate = try c.decodeIfPresent(String.self, forKey: .pubdate)
        enclosure = try c.decodeIfPresent(String.self, forKey: .enclosure)
    }
}

public struct MoviePilotDownloadData: Decodable, Sendable {
    public let hash: String?
    public let downloader: String?
    public let savePath: String?
    public let label: String?
    public let status: String?
    /// 曲目级内容校验结果（v0.5.2+）：true=包含目标歌曲 / false=拒绝 / nil=整轨无法逐曲校验。
    public let contentVerified: Bool?
    public let matchedFiles: [String]?
    public let sizeText: String?

    enum CodingKeys: String, CodingKey {
        case hash, downloader, label, status
        case savePath = "save_path"
        case contentVerified = "content_verified"
        case matchedFiles = "matched_files"
        case sizeText = "size_text"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        downloader = try c.decodeIfPresent(String.self, forKey: .downloader)
        savePath = try c.decodeIfPresent(String.self, forKey: .savePath)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        contentVerified = try c.decodeLooseBoolIfPresent(forKey: .contentVerified)
        matchedFiles = try c.decodeIfPresent([String].self, forKey: .matchedFiles)
        sizeText = try c.decodeIfPresent(String.self, forKey: .sizeText)
    }
}

public struct MoviePilotTaskData: Decodable, Sendable {
    public let hash: String
    public let title: String
    public let site: String?
    public let quality: Int?
    public let state: String
    public let progress: Double?
    public let savePath: String?

    enum CodingKeys: String, CodingKey {
        case hash, title, site, quality, state, progress
        case savePath = "save_path"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.decode(String.self, forKey: .hash)
        title = try c.decode(String.self, forKey: .title)
        site = try c.decodeIfPresent(String.self, forKey: .site)
        quality = try c.decodeLooseIntIfPresent(forKey: .quality)
        state = try c.decode(String.self, forKey: .state)
        progress = try c.decodeLooseDoubleIfPresent(forKey: .progress)
        savePath = try c.decodeIfPresent(String.self, forKey: .savePath)
    }
}

public struct MoviePilotSitesData: Decodable, Sendable {
    public let mode: String?
    public let sites: [MoviePilotSite]?
}

public struct MoviePilotSite: Decodable, Sendable {
    public let id: Int?
    public let name: String?
}

/// /test 接口：连通性与配置逐项检查。
public struct MoviePilotTestData: Decodable, Sendable {
    public let summary: String?
    public let checks: [MoviePilotTestCheck]?
}

public struct MoviePilotTestCheck: Decodable, Sendable {
    public let name: String?
    public let ok: Bool?
    public let detail: String?

    enum CodingKeys: String, CodingKey { case name, ok, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        ok = try c.decodeLooseBoolIfPresent(forKey: .ok)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// /history 接口：下载历史（含下载器实时状态）。
public struct MoviePilotHistoryData: Decodable, Sendable {
    public let liveAvailable: Bool?
    public let tasks: [MoviePilotTaskData]?

    enum CodingKeys: String, CodingKey {
        case tasks
        case liveAvailable = "live_available"
    }
}

// MARK: - 客户端

/// MoviePilot 音乐下载插件 REST 客户端。
/// 只使用「站点搜索 + 下载器下载」，不触发刮削/整理/订阅。
/// 鉴权优先使用插件级 `X-Music-Token`（移动端推荐），未配置时回退 `X-API-KEY`。
public struct MoviePilotClient: Sendable {
    private static let apiPath = "/api/v1/plugin/MusicDownloader"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 搜索音乐资源（含音乐/影视判别 + 无损优先排序）。
    /// - Parameter kind: "single"（单曲，大小上限生效）/ "album"（专辑合集）/ "auto"（自动，默认）。
    public func search(
        _ connection: MoviePilotConnection,
        artist: String?,
        album: String?,
        albumAliases: [String],
        keyword: String?,
        year: Int?,
        limit: Int,
        preferLossless: Bool,
        minSeeders: Int,
        kind: String? = nil
    ) async throws -> MoviePilotSearchData {
        var body: [String: Any] = [:]
        if let artist, !artist.isEmpty { body["artist"] = artist }
        if let album, !album.isEmpty { body["album"] = album }
        if !albumAliases.isEmpty { body["album_aliases"] = albumAliases }
        if let keyword, !keyword.isEmpty { body["keyword"] = keyword }
        if let year { body["year"] = year }
        if let kind, !kind.isEmpty { body["kind"] = kind }
        body["limit"] = limit
        body["prefer_lossless"] = preferLossless
        body["min_seeders"] = minSeeders
        return try await send(connection, endpoint: "search", body: body)
    }

    /// 加入下载：优先 ref（hash:id），否则 site_id+index，否则 magnet。
    /// - Parameters:
    ///   - maxSizeGB: 把 search 返回的 size_limit_gb 原样传回（单曲/合集的体积上限，v0.5.x）。
    ///   - verifySong / verifyArtist: 单曲自动下载必传，下载前校验种子确实包含目标歌曲。
    public func download(
        _ connection: MoviePilotConnection,
        ref: String?,
        siteID: Int?,
        index: Int?,
        magnet: String?,
        title: String?,
        maxSizeGB: Double? = nil,
        verifySong: String? = nil,
        verifyArtist: String? = nil
    ) async throws -> MoviePilotDownloadData {
        var body: [String: Any] = [:]
        if let ref, !ref.isEmpty {
            body["ref"] = ref
        } else if let siteID, let index {
            body["site_id"] = siteID
            body["index"] = index
        } else if let magnet, !magnet.isEmpty {
            body["magnet"] = magnet
            if let title, !title.isEmpty { body["title"] = title }
        } else {
            throw MoviePilotError.invalidConfiguration("下载参数缺失：请提供 ref（或 site_id+index，或 magnet）")
        }
        if let maxSizeGB, maxSizeGB > 0 { body["max_size_gb"] = maxSizeGB }
        if let verifySong, !verifySong.isEmpty { body["verify_song"] = verifySong }
        if let verifyArtist, !verifyArtist.isEmpty { body["verify_artist"] = verifyArtist }
        return try await send(connection, endpoint: "download", body: body)
    }

    /// 查询下载任务。
    public func tasks(_ connection: MoviePilotConnection, status: String?) async throws -> [MoviePilotTaskData] {
        let payload: MoviePilotTasksPayload = try await send(connection, endpoint: "tasks", query: status.map { [URLQueryItem(name: "status", value: $0)] })
        return payload.tasks ?? []
    }

    /// 查询站点范围。
    /// 注意：send() 已解包并校验统一 envelope，这里直接用 Data 类型，不能再套一层 envelope。
    public func sites(_ connection: MoviePilotConnection) async throws -> MoviePilotSitesData {
        try await send(connection, endpoint: "sites")
    }

    /// 插件连通性与配置检查（供设置页「测试连接」逐项展示）。
    /// 注意：send() 已解包并校验统一 envelope（success=false 时抛 pluginFailed(message)），
    /// 这里直接用 Data 类型，不能再套一层 envelope（旧写法导致「测试无法解析」）。
    public func test(_ connection: MoviePilotConnection) async throws -> MoviePilotTestData {
        try await send(connection, endpoint: "test", body: [:])
    }

    /// 下载历史（含实时状态）。
    /// 注意：send() 已解包并校验统一 envelope，这里直接用 Data 类型。
    public func history(_ connection: MoviePilotConnection) async throws -> MoviePilotHistoryData {
        try await send(connection, endpoint: "history")
    }

    // MARK: - 内部

    private struct MoviePilotTasksPayload: Decodable, Sendable {
        let tasks: [MoviePilotTaskData]?
    }

    /// 非 2xx 响应里插件仍返回统一 envelope（success/message），只读 message 用于诊断。
    private struct MoviePilotErrorEnvelope: Decodable, Sendable {
        let success: Bool?
        let message: String?
    }

    private func send<Response: Decodable & Sendable>(
        _ connection: MoviePilotConnection,
        endpoint: String,
        body: [String: Any]? = nil,
        query: [URLQueryItem]? = nil
    ) async throws -> Response {
        let base = connection.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var path = Self.apiPath
        if base.hasSuffix(Self.apiPath) {
            path = ""
        }
        var components = URLComponents(string: base + path + "/" + endpoint)
        if let query {
            components?.queryItems = query
        }
        guard let url = components?.url else {
            throw MoviePilotError.invalidConfiguration("MoviePilot 地址无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            request.httpMethod = "GET"
        }
        if let token = connection.token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Music-Token")
        }
        // 未配置 Token 时不发送空鉴权头，让插件返回明确的鉴权错误。

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MoviePilotError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // 插件错误也走统一 envelope（如 401 带 {"success":false,"message":"apikey 校验不通过"}）。
            // 优先透出真实业务错误让用户可诊断；解析不了再回退到笼统的 HTTP 状态码。
            if let envelope = try? JSONDecoder().decode(MoviePilotErrorEnvelope.self, from: data),
               let message = envelope.message, !message.isEmpty {
                throw MoviePilotError.pluginFailed(message)
            }
            throw MoviePilotError.transport("HTTP \(status)")
        }
        do {
            let envelope = try JSONDecoder().decode(MoviePilotEnvelope<Response>.self, from: data)
            guard envelope.success, let payload = envelope.data else {
                throw MoviePilotError.pluginFailed(envelope.message ?? "插件返回失败")
            }
            return payload
        } catch let error as MoviePilotError {
            throw error
        } catch {
            throw MoviePilotError.malformedResponse(error.localizedDescription)
        }
    }
}
