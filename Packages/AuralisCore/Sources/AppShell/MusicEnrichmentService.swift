import AgentKit
import Domain
import Foundation
import LocalCatalog

/// App 级公开音乐资料服务。
///
/// 歌曲信息 UI、Agent（music_appreciate / music_get_public_evidence）与
/// “无歌词后的低优先级补全”共用**同一个实例**，共享 SQLite 缓存、in-flight 去重、
/// 限速与身份匹配。公开音乐资料不是 Agent 私有功能。
public actor MusicEnrichmentService: AgentExternalMusicService {
    private let engine: MusicBrainzExternalMusicService
    private let catalog: LocalCatalogStore
    /// 同一 GlobalID 并发触发（歌曲信息 + Agent + 歌词补全）时共享同一个请求。
    private var inFlight: [EnrichmentKey: Task<AgentExternalMusicResult, Never>] = [:]

    private struct EnrichmentKey: Hashable {
        let globalID: GlobalID
        let forceRefresh: Bool
    }

    public init(
        catalog: LocalCatalogStore,
        session: URLSession = .shared,
        userAgent: String = "Auralis/1.0.2 (https://github.com/zyk1172/Auralis)"
    ) {
        self.catalog = catalog
        self.engine = MusicBrainzExternalMusicService(
            catalog: catalog,
            session: session,
            userAgent: userAgent
        )
    }

    /// 对外统一入口：in-flight dedupe 后转真实引擎。
    public func enrich(track: Track, globalID: GlobalID) async -> AgentExternalMusicResult {
        await enrich(track: track, globalID: globalID, forceRefresh: false)
    }

    /// 带强制刷新版本；in-flight 去重键含 refresh 标志，避免普通与刷新请求互相吞并。
    public func enrich(track: Track, globalID: GlobalID, forceRefresh: Bool) async -> AgentExternalMusicResult {
        let key = EnrichmentKey(globalID: globalID, forceRefresh: forceRefresh)
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task { [engine] in
            await engine.enrich(track: track, globalID: globalID, forceRefresh: forceRefresh)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return await task.value
    }

    /// 普通清缓存（保留 Stable Identity）。
    public func clearCache() async throws {
        try await engine.clearCache()
    }

    /// 高级“重置音乐身份匹配”。
    public func resetIdentity() async throws {
        try await engine.resetIdentity()
    }

    /// 读取已缓存的详情 Evidence（无网络）；nil 表示尚未缓存。
    public func cachedEvidence(for globalID: GlobalID) async -> CommunityMusicEvidence? {
        try? await catalog.communityMusicEvidence(for: globalID)
    }

    /// 无歌词后的低优先级补全：不阻塞播放/歌词界面/主线程。
    public func prefetchForMissingLyrics(track: Track) async {
        let globalID = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        _ = await enrich(track: track, globalID: globalID)
    }
}
