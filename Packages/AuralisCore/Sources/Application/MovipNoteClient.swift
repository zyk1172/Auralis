import Foundation
import SecurityKit

// MARK: - 配置

/// MovipNote（MoviePilot 音乐下载插件）配置：普通字段存 UserDefaults，Token 存 Keychain。
public struct MovipNoteSettings: Sendable {
    public static let baseURLKey = "auralis.movipnote.baseURL"
    public static let tokenCredentialID = CredentialID(rawValue: "movipnote.music-token")
    public static let defaultHint = "http://<MovipNote-Host>:3000"

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
public struct MovipNoteConnection: Sendable {
    public let baseURL: URL
    public let token: String?

    public init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }
}

// MARK: - 错误

public enum MovipNoteError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case pluginFailed(String)
    case transport(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): message
        case let .pluginFailed(message): message
        case let .transport(message): "网络请求失败：\(message)"
        case let .malformedResponse(message): "响应解析失败：\(message)"
        }
    }
}

// MARK: - 响应 DTO（与插件 /api/v1/plugin/MusicDownloader 契约一致）

public struct MovipNoteEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    public let success: Bool
    public let message: String?
    public let data: T?
}

public struct MovipNoteSearchData: Decodable, Sendable {
    public let keyword: String?
    public let total: Int?
    public let albumMatchedAny: Bool?
    public let droppedVideo: Int?
    public let results: [MovipNoteCandidate]?

    enum CodingKeys: String, CodingKey {
        case keyword, total, results
        case albumMatchedAny = "album_matched_any"
        case droppedVideo = "dropped_video"
    }
}

public struct MovipNoteCandidate: Decodable, Sendable {
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
    public let size: String?
    public let seeders: Int?
    public let grabs: Int?

    enum CodingKeys: String, CodingKey {
        case index, ref, title, category, music, confidence, quality, relevance, size, seeders, grabs
        case siteId = "site_id"
        case siteName = "site_name"
        case audioFormat = "audio_format"
        case qualityLabel = "quality_label"
        case albumMatched = "album_matched"
    }
}

public struct MovipNoteDownloadData: Decodable, Sendable {
    public let hash: String?
    public let downloader: String?
    public let savePath: String?
    public let label: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case hash, downloader, label, status
        case savePath = "save_path"
    }
}

public struct MovipNoteTaskData: Decodable, Sendable {
    public let hash: String
    public let title: String
    public let site: String?
    public let quality: Int?
    public let state: String
    public let progress: Double?
    public let savePath: String?

    enum CodingKeys: String, CodingKey {
        case hash, title, site, quality, state
        case progress
        case savePath = "save_path"
    }
}

public struct MovipNoteSitesData: Decodable, Sendable {
    public let mode: String?
    public let sites: [MovipNoteSite]?
}

public struct MovipNoteSite: Decodable, Sendable {
    public let id: Int?
    public let name: String?
}

// MARK: - 客户端

/// MovipNote 音乐下载插件 REST 客户端。
/// 只使用「站点搜索 + 下载器下载」，不触发刮削/整理/订阅。
/// 鉴权优先使用插件级 `X-Music-Token`（移动端推荐），未配置时回退 `X-API-KEY`。
public struct MovipNoteClient: Sendable {
    private static let apiPath = "/api/v1/plugin/MusicDownloader"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 搜索音乐资源（含音乐/影视判别 + 无损优先排序）。
    public func search(
        _ connection: MovipNoteConnection,
        artist: String?,
        album: String?,
        albumAliases: [String],
        keyword: String?,
        year: Int?,
        limit: Int,
        preferLossless: Bool,
        minSeeders: Int
    ) async throws -> MovipNoteSearchData {
        var body: [String: Any] = [:]
        if let artist, !artist.isEmpty { body["artist"] = artist }
        if let album, !album.isEmpty { body["album"] = album }
        if !albumAliases.isEmpty { body["album_aliases"] = albumAliases }
        if let keyword, !keyword.isEmpty { body["keyword"] = keyword }
        if let year { body["year"] = year }
        body["limit"] = limit
        body["prefer_lossless"] = preferLossless
        body["min_seeders"] = minSeeders
        return try await send(connection, endpoint: "search", body: body)
    }

    /// 加入下载：优先 ref（hash:id），否则 site_id+index，否则 magnet。
    public func download(
        _ connection: MovipNoteConnection,
        ref: String?,
        siteID: Int?,
        index: Int?,
        magnet: String?,
        title: String?
    ) async throws -> MovipNoteDownloadData {
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
            throw MovipNoteError.invalidConfiguration("下载参数缺失：请提供 ref（或 site_id+index，或 magnet）")
        }
        return try await send(connection, endpoint: "download", body: body)
    }

    /// 查询下载任务。
    public func tasks(_ connection: MovipNoteConnection, status: String?) async throws -> [MovipNoteTaskData] {
        let payload: MovipNoteTasksPayload = try await send(connection, endpoint: "tasks", query: status.map { [URLQueryItem(name: "status", value: $0)] })
        return payload.tasks ?? []
    }

    /// 查询站点范围（用于连通性测试）。
    public func sites(_ connection: MovipNoteConnection) async throws -> MovipNoteSitesData {
        let envelope: MovipNoteEnvelope<MovipNoteSitesData> = try await send(connection, endpoint: "sites")
        guard envelope.success, let data = envelope.data else {
            throw MovipNoteError.pluginFailed(envelope.message ?? "获取站点失败")
        }
        return data
    }

    // MARK: - 内部

    private struct MovipNoteTasksPayload: Decodable, Sendable {
        let tasks: [MovipNoteTaskData]?
    }

    private func send<Response: Decodable & Sendable>(
        _ connection: MovipNoteConnection,
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
            throw MovipNoteError.invalidConfiguration("MovipNote 地址无效")
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
            throw MovipNoteError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MovipNoteError.transport("HTTP \(status)")
        }
        do {
            let envelope = try JSONDecoder().decode(MovipNoteEnvelope<Response>.self, from: data)
            guard envelope.success, let payload = envelope.data else {
                throw MovipNoteError.pluginFailed(envelope.message ?? "插件返回失败")
            }
            return payload
        } catch let error as MovipNoteError {
            throw error
        } catch {
            throw MovipNoteError.malformedResponse(error.localizedDescription)
        }
    }
}
