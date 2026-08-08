import CryptoKit
import Domain
import Foundation
import SecurityKit

/// Endpoints used by Auralis. Every request is sent as an
/// `application/x-www-form-urlencoded` POST, including read-only operations.
public enum OpenSubsonicEndpoint: String, CaseIterable, Sendable {
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
}

public struct OpenSubsonicExtension: Codable, Hashable, Sendable {
    public let name: String
    public let versions: [Int]

    public init(name: String, versions: [Int] = []) {
        self.name = name
        self.versions = versions
    }
}

public enum CapabilityRegistry {
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
        name.lowercased().filter(\.isLetter)
    }

    private static func containsAny(_ values: Set<String>, _ candidates: [String]) -> Bool {
        !values.isDisjoint(with: candidates.map(normalized))
    }
}

/// References credentials held by a `CredentialVault`; no secret is retained in
/// the configuration value itself.
public enum OpenSubsonicAuthentication: Hashable, Sendable {
    case token(username: String, credentialID: CredentialID)
    case apiKey(credentialID: CredentialID)
}

public struct OpenSubsonicConfiguration: Hashable, Sendable {
    public let serverID: ServerID
    public let baseURL: URL
    public let clientName: String
    public let protocolVersion: String
    public let authentication: OpenSubsonicAuthentication
    public let requestTimeout: TimeInterval

    public init(
        serverID: ServerID? = nil,
        baseURL: URL,
        clientName: String = "Auralis",
        protocolVersion: String = "1.16.1",
        authentication: OpenSubsonicAuthentication,
        requestTimeout: TimeInterval = 30
    ) {
        self.serverID = serverID ?? Self.stableServerID(for: baseURL)
        self.baseURL = baseURL
        self.clientName = clientName
        self.protocolVersion = protocolVersion
        self.authentication = authentication
        self.requestTimeout = requestTimeout
    }

    private static func stableServerID(for baseURL: URL) -> ServerID {
        let canonicalURL = canonicalIdentityURL(baseURL)
        let digest = SHA256.hash(data: Data(canonicalURL.utf8))
        let hexadecimal = digest.map { String(format: "%02x", $0) }.joined()
        return ServerID(rawValue: "opensubsonic-\(hexadecimal)")
    }

    /// Produces a stable identity while excluding user-info, query values, and
    /// fragments. Equivalent trailing slashes and default ports map to the same
    /// server without exposing its private address in the resulting identifier.
    private static func canonicalIdentityURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        if (components.scheme == "http" && components.port == 80)
            || (components.scheme == "https" && components.port == 443) {
            components.port = nil
        }

        while components.percentEncodedPath.count > 1,
              components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }

        return components.string ?? url.absoluteString
    }
}

public struct OpenSubsonicParameter: Hashable, Sendable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct OpenSubsonicRequestDescriptor: Equatable, Sendable {
    public let endpoint: OpenSubsonicEndpoint
    public let method: String
    public let parameterItems: [OpenSubsonicParameter]

    /// A compatibility view for call sites that only use unique parameter names.
    /// Repeated values such as playlist `songId` entries are represented by the
    /// final value; use `parameterItems` when order or repetition matters.
    public var parameters: [String: String] {
        parameterItems.reduce(into: [:]) { result, item in
            result[item.name] = item.value
        }
    }

    public init(
        endpoint: OpenSubsonicEndpoint,
        method: String = "POST",
        parameters: [String: String] = [:]
    ) {
        self.endpoint = endpoint
        self.method = method
        self.parameterItems = parameters
            .map(OpenSubsonicParameter.init)
            .sorted { $0.name < $1.name }
    }

    public init(
        endpoint: OpenSubsonicEndpoint,
        method: String = "POST",
        parameterItems: [OpenSubsonicParameter]
    ) {
        self.endpoint = endpoint
        self.method = method
        self.parameterItems = parameterItems
    }
}

public struct OpenSubsonicServerError: Error, Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let helpURL: URL?

    public init(code: Int, message: String, helpURL: URL? = nil) {
        self.code = code
        self.message = message
        self.helpURL = helpURL
    }
}

public enum OpenSubsonicClientError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidConfiguration(String)
    case invalidParameter(String)
    case unsupportedCapability(String)
    /// Kept for source compatibility with the Phase 0 API.
    case server(code: Int, message: String)
    case serverFailure(OpenSubsonicServerError)
    case httpStatus(Int)
    case transport(code: Int, host: String?)
    case malformedResponse(String)
    case missingPayload(String)
}

extension OpenSubsonicClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The OpenSubsonic server URL is invalid."
        case let .invalidConfiguration(reason):
            return "The OpenSubsonic configuration is invalid: \(reason)"
        case let .invalidParameter(name):
            return "The OpenSubsonic parameter is invalid: \(name)"
        case let .unsupportedCapability(name):
            return "The server does not advertise the required capability: \(name)"
        case let .server(code, message):
            return "OpenSubsonic server error \(code): \(message)"
        case let .serverFailure(error):
            return "OpenSubsonic server error \(error.code): \(error.message)"
        case let .httpStatus(status):
            return "The OpenSubsonic server returned HTTP \(status)."
        case let .transport(code, host):
            if code == -1009 {
                let hostText = host.map { "（\($0)）" } ?? ""
                return "网络无法连接（错误 -1009）\(hostText)。如果是局域网地址，请到「设置 → 隐私与安全 → 本地网络」允许澜音访问本地网络。"
            }
            return "网络请求失败（错误 \(code)）。请检查地址和网络。"
        case let .malformedResponse(detail):
            return "服务器返回的内容无法解析：\(detail)"
        case let .missingPayload(name):
            return "The OpenSubsonic response did not contain \(name)."
        }
    }
}

public protocol OpenSubsonicServing: Sendable {
    func ping() async throws
    func extensions() async throws -> [OpenSubsonicExtension]
    func execute(_ request: OpenSubsonicRequestDescriptor) async throws -> Data
}

public struct OpenSubsonicRetryPolicy: Hashable, Sendable {
    public let maximumAttempts: Int
    public let initialDelayNanoseconds: UInt64
    public let multiplier: Double

    public init(
        maximumAttempts: Int = 3,
        initialDelayNanoseconds: UInt64 = 250_000_000,
        multiplier: Double = 2
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.multiplier = max(1, multiplier)
    }

    public static let standard = OpenSubsonicRetryPolicy()
    public static let disabled = OpenSubsonicRetryPolicy(maximumAttempts: 1, initialDelayNanoseconds: 0)
}

public enum OpenSubsonicRequestFactory {
    public static func descriptor(
        _ endpoint: OpenSubsonicEndpoint,
        parameters: [String: String] = [:]
    ) -> OpenSubsonicRequestDescriptor {
        var values = parameters
        values["f"] = "json"
        return OpenSubsonicRequestDescriptor(endpoint: endpoint, parameters: values)
    }

    public static func descriptor(
        _ endpoint: OpenSubsonicEndpoint,
        parameterItems: [OpenSubsonicParameter]
    ) -> OpenSubsonicRequestDescriptor {
        OpenSubsonicRequestDescriptor(
            endpoint: endpoint,
            parameterItems: parameterItems + [.init("f", "json")]
        )
    }

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
        components.path = "\(path)/rest/\(endpoint.rawValue).view"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw OpenSubsonicClientError.invalidBaseURL }
        return url
    }
}
