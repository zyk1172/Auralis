import Application
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import OpenSubsonicKit
import Persistence
import SecurityKit
import Testing

// MARK: - 按 host 匹配的 URLProtocol（R01 路由测试用；MockURLProtocol 是队列式，
// 不适合 A/B 并发请求场景）

private final class RoutingURLProtocol: URLProtocol, @unchecked Sendable {
    struct Rule: Sendable {
        let hostSuffix: String
        let data: Data
        let errorCode: URLError.Code?
    }

    private static let lock = NSLock()
    // 受上方 NSLock 保护（reset/hosts/startLoading 全部走 lock），
    // nonisolated(unsafe) 声明该外部同步契约，满足 Swift 6 并发检查。
    private static nonisolated(unsafe) var rules: [Rule] = []
    private static nonisolated(unsafe) var capturedHosts: [String] = []

    static func reset(rules: [Rule]) {
        lock.lock(); defer { lock.unlock() }
        Self.rules = rules
        capturedHosts = []
    }

    static var hosts: [String] {
        lock.lock(); defer { lock.unlock() }
        return capturedHosts
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let rule: Rule?
        RoutingURLProtocol.lock.lock()
        RoutingURLProtocol.capturedHosts.append(host)
        rule = RoutingURLProtocol.rules.first { host.hasSuffix($0.hostSuffix) }
        RoutingURLProtocol.lock.unlock()
        guard let rule else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if let errorCode = rule.errorCode {
            client?.urlProtocol(self, didFailWithError: URLError(errorCode))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: rule.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func routingSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutingURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// 空资料库同步源：restoreConnection 路径不触发网络分页。
private struct EmptyRoutingSyncSource: LibrarySyncSource {
    func artistsPage(serverID: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Artist> {
        LibraryPage(items: [])
    }
    func albumsPage(serverID: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Album> {
        LibraryPage(items: [])
    }
    func tracksPage(serverID: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Track> {
        LibraryPage(items: [])
    }
}

// MARK: - R01 回归测试：多服务器客户端路由

/// 验证 R01：客户端按 ServerID 管理，涉及远程实体的请求显式路由到对应服务器，
/// 相同 TrackID 在不同服务器之间绝不串扰；迟到的端点探测不会改回 UI 当前服务器。
@Suite("R01 多服务器客户端路由", .serialized)
struct ServerRoutingRegressionTests {
    private func makeTrack(serverID: ServerID, remoteID: String, title: String) -> Track {
        Track(
            id: TrackID(rawValue: remoteID), serverID: serverID,
            albumID: "a", artistID: "r",
            title: title, artistName: "Artist", albumTitle: "Album", duration: 120
        )
    }

    private func makeConnector(
        persistence: any AuralisPersisting,
        vault: any CredentialVault,
        session: URLSession
    ) -> ProductionServerConnector {
        ProductionServerConnector(
            credentialVault: vault,
            persistence: persistence,
            catalogStore: try! LocalCatalogStore(url: URL(string: "file::memory:")!),
            session: session,
            sourceFactory: { _ in EmptyRoutingSyncSource() }
        )
    }

    private func seedAccounts(
        persistence: any AuralisPersisting,
        vault: InMemoryCredentialVault,
        serverAExternal: URL? = nil
    ) async throws -> (ServerID, ServerID) {
        let a: ServerID = "a"
        let b: ServerID = "b"
        let accountA = ServerAccount(
            id: a, displayName: "A", baseURL: URL(string: "http://a.internal.test")!,
            externalBaseURL: serverAExternal, username: "u",
            credentialReference: "opensubsonic.a"
        )
        let accountB = ServerAccount(
            id: b, displayName: "B", baseURL: URL(string: "http://b.test")!,
            username: "u", credentialReference: "opensubsonic.b"
        )
        try await persistence.saveAccount(accountA)
        try await persistence.saveAccount(accountB)
        try await vault.store("pw", for: CredentialID(rawValue: "opensubsonic.a"))
        try await vault.store("pw", for: CredentialID(rawValue: "opensubsonic.b"))
        return (a, b)
    }

    private static let emptyOK = Data(
        #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8
    )
    private static let syncedLyricsOK = Data(
        #"{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[{"displayArtist":"Artist","lang":"chi","synced":true,"line":[{"start":0,"value":"第一句"}]}]}}}"#.utf8
    )

    /// 相同 remoteID 的曲目：A 的歌请求发往 A 服务器，B 的歌请求发往 B 服务器。
    @Test("相同 TrackID 按 serverID 路由，A/B 互不串扰")
    func sameTrackIDRoutesToOwnServer() async throws {
        let persistence = InMemoryPersistence()
        let vault = InMemoryCredentialVault()
        let (a, b) = try await seedAccounts(persistence: persistence, vault: vault)

        RoutingURLProtocol.reset(rules: [
            .init(hostSuffix: "a.internal.test", data: Self.syncedLyricsOK, errorCode: nil),
            .init(hostSuffix: "b.test", data: Self.emptyOK, errorCode: nil),
        ])
        let connector = makeConnector(persistence: persistence, vault: vault, session: routingSession())

        _ = try await connector.restoreConnection(serverID: a)
        _ = try await connector.restoreConnection(serverID: b)

        // 相同 remoteID "X"，分别属于 A 与 B。
        let trackA = makeTrack(serverID: a, remoteID: "X", title: "A 的 X")
        let trackB = makeTrack(serverID: b, remoteID: "X", title: "B 的 X")

        let lyricsA = try await connector.fetchLyrics(for: trackA)
        let lyricsB = try await connector.fetchLyrics(for: trackB)

        // A 返回结构化歌词，B 明确无歌词（返回 nil 而非抛出）。
        #expect(lyricsA?.lines.first?.text == "第一句")
        #expect(lyricsB == nil)

        // 请求按 track.serverID 路由到各自 host。
        let hosts = RoutingURLProtocol.hosts
        #expect(hosts.contains { $0 == "a.internal.test" })
        #expect(hosts.contains { $0 == "b.test" })
    }

    /// 延迟的端点探测（内外网选择）不得把 UI 当前服务器改回旧服务器。
    @Test("迟到端点探测不改回 activeServerID")
    func delayedEndpointProbeDoesNotRevertActiveServer() async throws {
        let persistence = InMemoryPersistence()
        let vault = InMemoryCredentialVault()
        // A 配了外网地址 → restoreConnection 会启动后台端点探测 Task。
        let (a, b) = try await seedAccounts(
            persistence: persistence,
            vault: vault,
            serverAExternal: URL(string: "http://a.external.test")!
        )

        // A 内网可达（成功响应）、外网不可达；B 成功。
        RoutingURLProtocol.reset(rules: [
            .init(hostSuffix: "a.internal.test", data: Self.emptyOK, errorCode: nil),
            .init(hostSuffix: "a.external.test", data: Data(), errorCode: .cannotConnectToHost),
            .init(hostSuffix: "b.test", data: Self.emptyOK, errorCode: nil),
        ])
        let connector = makeConnector(persistence: persistence, vault: vault, session: routingSession())

        _ = try await connector.restoreConnection(serverID: a)
        // 探测 Task 已启动；立刻切到 B。
        _ = try await connector.restoreConnection(serverID: b)
        #expect(await connector.activeServerID == b)

        // 等待 A 的内网探测请求被发出（探测完成并写入 clients[A]）。
        for _ in 0..<50 {
            if RoutingURLProtocol.hosts.contains("a.internal.test") { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        // 再给探测 Task 收尾时间，然后断言：UI 当前服务器仍是 B。
        try await Task.sleep(for: .milliseconds(100))
        #expect(await connector.activeServerID == b)
    }
}
