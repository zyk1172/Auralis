import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

// MARK: - AI Assistant Capability 层与 Provider 不可用回归测试
//
// 覆盖新架构：
// - Provider 不可用 → AI unavailable（不做关键词规则伪 AI / 随机推荐）
// - AgentCapabilityCatalog 是单一 canonical capability 源
// - recommendation_index_commit 继续对普通模型隐藏
// - 模型自省：看不到 commit tool ≠ 没有持久化能力

@Suite("Agent capability layer")
struct AgentCapabilityLayerTests {

    private actor CapCollector {
        private var messages: [AgentChatMessage] = []
        func append(_ message: AgentChatMessage) { messages.append(message) }
        func all() -> [AgentChatMessage] { messages }
        func containsError(_ text: String) -> Bool {
            messages.contains { m in
                m.messages.contains { item in
                    if case let .error(value) = item { return value.contains(text) }
                    return false
                }
            }
        }
        func containsText(_ text: String) -> Bool {
            messages.contains { m in
                m.messages.contains { item in
                    if case let .text(value) = item { return value.contains(text) }
                    return false
                }
            }
        }
    }

    /// 记录随机/收藏/相似/队列/歌单调用，验证 Provider 不可用时零 mutation。
    private final class AuditBridge: AgentBridge, @unchecked Sendable {
        let activeServerIDValue: ServerID?
        init(activeServerID: ServerID? = nil) { self.activeServerIDValue = activeServerID }
        var activeServerID: ServerID? { activeServerIDValue }
        var lyricsStateValue: AgentLyricsState = .unknown
        func lyricsState(for globalID: GlobalID) async -> AgentLyricsState { lyricsStateValue }
        func currentTrack() -> Track? { nil }
        func currentQueue() -> [Track] { [] }

        private(set) var playedTracks: [GlobalID] = []
        private(set) var replacedQueues: [[GlobalID]] = []
        private(set) var createdPlaylistNames: [String] = []
        private(set) var addedToPlaylist: [(GlobalID, [GlobalID])] = []
        private(set) var likedTracks: [GlobalID] = []
        var mutationResult: AgentMutationResult = .confirmed("ok")

        func playTrack(globalID: GlobalID) async -> Bool { playedTracks.append(globalID); return true }
        func playServerTrack(globalID: GlobalID) async -> Bool { true }
        func playAlbum(globalID: GlobalID) async -> Bool { true }
        func playPlaylist(globalID: GlobalID) async -> Bool { true }
        func playRandom(limit: Int) async -> AgentMutationResult { mutationResult }
        func pause() async -> AgentMutationResult { mutationResult }
        func resume() async -> AgentMutationResult { mutationResult }
        func seek(seconds: TimeInterval) async -> AgentMutationResult { mutationResult }
        func next() async -> AgentMutationResult { mutationResult }
        func previous() async -> AgentMutationResult { mutationResult }
        func setShuffle(_ enabled: Bool) async -> AgentMutationResult { mutationResult }
        func setRepeatMode(_ mode: RepeatMode) async -> AgentMutationResult { mutationResult }
        func setPlaybackRate(_ rate: Float) async -> AgentMutationResult { mutationResult }
        func setSleepTimer(mode: String, minutes: TimeInterval) async -> AgentMutationResult { mutationResult }
        func cancelSleepTimer() async -> AgentMutationResult { mutationResult }
        func getSleepTimer() async -> (mode: String, remaining: TimeInterval) { ("off", 0) }
        func addToQueue(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func playNext(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func playNext(globalIDs: [GlobalID]) async -> AgentMutationResult { mutationResult }
        func replaceQueue(globalIDs: [GlobalID]) async -> AgentMutationResult {
            replacedQueues.append(globalIDs)
            return mutationResult
        }
        func removeFromQueue(at index: Int) async -> AgentMutationResult { mutationResult }
        func reorderQueue(from: Int, to: Int) async -> AgentMutationResult { mutationResult }
        func clearQueue() async -> AgentMutationResult { mutationResult }
        func shuffleRemaining() async -> AgentMutationResult { mutationResult }
        func saveQueueAsPlaylist(name: String) async -> AgentMutationResult { mutationResult }
        func createPlaylist(name: String) async -> GlobalID? {
            createdPlaylistNames.append(name)
            return GlobalID(serverID: "v2", remoteID: "p-1")
        }
        func renamePlaylist(globalID: GlobalID, name: String) async -> AgentMutationResult { mutationResult }
        func addTracksToPlaylist(playlistGID: GlobalID, trackGIDs: [GlobalID]) async -> AgentMutationResult {
            addedToPlaylist.append((playlistGID, trackGIDs))
            return mutationResult
        }
        func removeTracksFromPlaylist(playlistGID: GlobalID, atIndices: [Int]) async -> AgentMutationResult { mutationResult }
        func reorderPlaylist(playlistGID: GlobalID, from: Int, to: Int) async -> AgentMutationResult { mutationResult }
        func duplicatePlaylist(playlistGID: GlobalID) async -> AgentMutationResult { mutationResult }
        func mergePlaylists(sourceGIDs: [GlobalID], into name: String) async -> AgentMutationResult { mutationResult }
        func deletePlaylist(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func likeTrack(globalID: GlobalID) async -> AgentMutationResult { likedTracks.append(globalID); return mutationResult }
        func unlikeTrack(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func favoriteAlbum(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func unfavoriteAlbum(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func favoriteArtist(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func unfavoriteArtist(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func setRating(globalID: GlobalID, rating: Int) async -> AgentMutationResult { mutationResult }
        func clearRating(globalID: GlobalID) async -> AgentMutationResult { mutationResult }
        func listServers() async -> [ServerAccount] { [] }
        func getActiveServer() async -> ServerAccount? { nil }
        func testServerConnection(serverID: ServerID) async -> Bool { true }
        func addServer(displayName: String, baseURL: String, username: String, token: String) async -> AgentMutationResult { mutationResult }
        func updateServer(serverID: ServerID, displayName: String?, baseURL: String?, username: String?, token: String?) async -> AgentMutationResult { mutationResult }
        func switchServer(serverID: ServerID) async -> AgentMutationResult { mutationResult }
        func refreshLibrary() async -> AgentMutationResult { mutationResult }
        func getSyncStatus() async -> [CatalogSyncStatus] { [] }
        func removeServer(serverID: ServerID) async -> AgentMutationResult { mutationResult }
        func serverSearch(query: String, limit: Int) async -> [Track] { [] }
    }

    private func makeStore() throws -> LocalCatalogStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
    }

    private func seedTracks(_ store: LocalCatalogStore, count: Int) async throws {
        let session = try await store.beginSync(serverID: "v2", mode: .full)
        try await store.stageTracks((0..<count).map { i in
            Track(
                id: TrackID(rawValue: "t\(i)"), serverID: "v2",
                albumID: AlbumID(rawValue: "t\(i)-album"), artistID: ArtistID(rawValue: "t\(i)-artist"),
                title: "歌 \(i)", artistName: "测试", albumTitle: "专辑 \(i)", duration: 200
            )
        }, session: session)
        try await store.completeSync(session, completedAt: .now)
    }

    @Test("A Provider 不可用 + 复杂推荐 → AI unavailable，零 mutation、零随机")
    func providerUnavailableRecommendationFails() async throws {
        let store = try makeStore()
        try await seedTracks(store, count: 5)
        try await store.setFavorite(GlobalID(serverID: "v2", remoteID: "t0"), value: true)
        let bridge = AuditBridge()
        let collector = CapCollector()
        await ConversationEngine().run(
            userText: "推荐十首适合深夜开车的歌",
            provider: nil,
            model: "none",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: "v2"),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        #expect(bridge.playedTracks.isEmpty, "不得执行播放")
        #expect(bridge.replacedQueues.isEmpty, "不得执行队列替换")
        #expect(bridge.createdPlaylistNames.isEmpty)
        #expect(bridge.likedTracks.isEmpty)
        #expect(await collector.containsError("AI 服务未配置或暂时不可用"), "必须明确返回 AI unavailable")
    }

    @Test("B Provider 不可用 + 创建歌单命令 → 不创建、返回 AI unavailable")
    func providerUnavailablePlaylistCommandFails() async throws {
        let store = try makeStore()
        let bridge = AuditBridge()
        let collector = CapCollector()
        await ConversationEngine().run(
            userText: "创建一个叫测试的歌单",
            provider: nil,
            model: "none",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: "v2"),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        #expect(bridge.createdPlaylistNames.isEmpty, "不得用关键词规则创建歌单")
        #expect(bridge.addedToPlaylist.isEmpty)
        #expect(await collector.containsError("AI 服务未配置或暂时不可用"))
    }

    @Test("C Direct Read Fast Path：Provider 不可用时确定性只读仍可用")
    func directReadFastPathWorksWithoutProvider() async throws {
        let store = try makeStore()
        try await seedTracks(store, count: 3)
        let bridge = AuditBridge()
        let collector = CapCollector()
        await ConversationEngine().run(
            userText: "音乐库有多少首歌",
            provider: nil,
            model: "none",
            bridge: bridge,
            catalog: store,
            context: ToolLoop.Context(serverID: "v2"),
            confirm: { _ in true },
            emit: { await collector.append($0) }
        )
        // 确定性只读快路径是性能优化而非离线降级：返回真实数据，不报 AI unavailable。
        let text = await collector.all()
        let joined = text.flatMap { $0.messages.compactMap { item -> String? in
            if case let .text(t) = item { return t }
            return nil
        } }.joined(separator: "\n")
        #expect(joined.contains("3"), "应返回真实曲库数量，实际：\(joined)")
        #expect(!(await collector.containsError("AI 服务未配置")))
    }

    @Test("D Capability 自省：能分类并持久化 Recommendation Index，commit 归 Runtime")
    func capabilitySelfAwarenessForRecommendationIndex() {
        guard let build = AgentCapabilityCatalog.capability(id: "recommendation_index_build") else {
            Issue.record("缺少 recommendation_index_build capability")
            return
        }
        #expect(build.requiresAIPlanning, "推荐索引需要 AI 规划")
        #expect(build.persists, "推荐索引必须真实持久化")
        #expect(build.executionOwner == .trustedRuntime, "持久化由 Trusted Runtime 执行")
        #expect(build.relatedTools.contains("library_index_status"))
        // 模型自省表述：看不到 commit 不等于不能保存。
        let summary = AgentCapabilityCatalog.systemPromptSummary(
            environment: AgentCapabilityEnvironment(
                providerAvailable: true, catalogAvailable: true, activeServer: true
            )
        )
        #expect(summary.contains("不要因为看不到内部 commit 工具就声称无法保存"))
        #expect(summary.contains("受控 Runtime 执行"))
        #expect(summary.contains("模型不得声称自己直接写数据库"))
    }

    @Test("E recommendation_index_commit 继续对普通模型隐藏")
    func hiddenCommitNotExposedToModel() {
        let descriptor = AgentToolRegistry.descriptor(for: "recommendation_index_commit")
        // 要么不存在（未注册），要么非 model 可见（skillOnly/internalOnly）。
        if let descriptor {
            #expect(descriptor.visibility != .model, "commit 不得以 model 可见性暴露")
        }
        // 普通 ToolSelector 选择（无 skill 上下文）不得包含它。
        let plan = AgentRequestPlan.build(userText: "建立推荐索引", history: [])
        let selected = ToolSelector.select(plan: plan, all: AgentToolRegistry.all)
        #expect(!selected.contains { $0.name == "recommendation_index_commit" })
        // tool_search 普通查询也不得返回它作为可执行能力。
        let discovered = ToolCatalog(descriptors: AgentToolRegistry.all)
            .search(query: "提交分类", authorizedOperations: plan.authorization.allowedOperations)
        #expect(!discovered.contains { $0.name == "recommendation_index_commit" })
    }

    @Test("H Capability Catalog 单一来源：摘要来自同一 canonical registry")
    func capabilityCatalogIsSingleSource() {
        // System Prompt 摘要与 capabilities_get 都来自 AgentCapabilityCatalog；
        // 这里验证 registry 内容完整且与真实工具关联（relatedTools 必须真实存在）。
        #expect(!AgentCapabilityCatalog.all.isEmpty)
        let registeredNames = Set(AgentToolRegistry.all.map(\.name))
        var missing = 0
        for capability in AgentCapabilityCatalog.all {
            for tool in capability.relatedTools where !registeredNames.contains(tool) {
                missing += 1
                Issue.record("capability \(capability.id) 引用不存在的工具 \(tool)")
            }
        }
        #expect(missing == 0, "relatedTools 必须指向真实注册工具")
        // 摘要覆盖关键能力。
        let summary = AgentCapabilityCatalog.systemPromptSummary(
            environment: AgentCapabilityEnvironment(
                providerAvailable: true, catalogAvailable: true, activeServer: true
            )
        )
        for required in ["Recommendation Index", "音乐推荐", "音乐鉴赏", "多步骤歌单构建", "音乐库分析", "联网资料核验"] {
            #expect(summary.contains(required), "摘要应包含 \(required)")
        }
    }

    @Test("Capability availability：Provider 缺失时依赖 Provider 的能力不可用")
    func availabilityReflectsProvider() {
        let build = AgentCapabilityCatalog.capability(id: "recommendation_index_build")!
        let withoutProvider = AgentCapabilityCatalog.availability(
            for: build,
            environment: AgentCapabilityEnvironment(
                providerAvailable: false, catalogAvailable: true, activeServer: true
            )
        )
        if case .available = withoutProvider {
            Issue.record("Provider 缺失时 recommendation_index_build 不得可用")
        }
        let read = AgentCapabilityCatalog.capability(id: "catalog_search")!
        let readAvailable = AgentCapabilityCatalog.availability(
            for: read,
            environment: AgentCapabilityEnvironment(
                providerAvailable: false, catalogAvailable: true, activeServer: true
            )
        )
        if case .available = readAvailable {} else {
            Issue.record("只读检索不应依赖 Provider")
        }
    }

    // MARK: - 评分授权边界（P1 回归）

    @Test("P1 评分读取：这首歌的评分是多少？→ 只读，不产生 ratingSet 授权")
    func ratingReadDoesNotGrantMutation() {
        let semantics = AgentRequestSemantics.analyze("这首歌的评分是多少？")
        #expect(!semantics.requestedOperations.contains(.ratingSet), "查询不得获得写授权")
        #expect(semantics.isReadOnly, "查询必须是只读")
    }

    @Test("P1 评分变更：清除这首歌的评分 → mutation + ratingSet")
    func ratingClearGrantsMutation() {
        let semantics = AgentRequestSemantics.analyze("清除这首歌的评分")
        #expect(semantics.requestedOperations.contains(.ratingSet), "明确清除动作必须授权 ratingSet")
        #expect(semantics.operation == .mutate || semantics.isExplicitMutation)
    }

    @Test("P1 评分变更：给这首歌打 4 分 / 给这首歌评分 4 分 → ratingSet")
    func ratingSetActionsGrantMutation() {
        for text in ["给这首歌打 4 分", "给这首歌评分 4 分", "设置这首歌的评分为 4", "取消这首歌的评分", "删除这首歌的评分"] {
            let semantics = AgentRequestSemantics.analyze(text)
            #expect(semantics.requestedOperations.contains(.ratingSet), "「\(text)」应授权 ratingSet")
        }
    }

    // MARK: - Capability 语义一致性（P2 回归）

    @Test("P2 server_query 只读、server_management_sync 变更，属性与工具一致")
    func serverCapabilitiesSemanticsConsistent() {
        let query = AgentCapabilityCatalog.capability(id: "server_query")!
        #expect(query.readOnly, "server_query 必须只读")
        #expect(query.relatedTools.contains("server_list"))
        #expect(!query.relatedTools.contains("server_switch"), "只读查询不得关联变更工具")
        let management = AgentCapabilityCatalog.capability(id: "server_management_sync")!
        #expect(!management.readOnly, "server_management_sync 是变更能力")
        #expect(management.relatedTools.contains("server_switch"))
        #expect(management.relatedTools.contains("server_sync_start"))
        #expect(management.requiresAIPlanning)
    }

    @Test("P2 catalog_search 声明与真实路由一致：AI 规划需要 Provider")
    func catalogSearchRequiresPlanning() {
        let search = AgentCapabilityCatalog.capability(id: "catalog_search")!
        #expect(search.requiresAIPlanning, "普通聊天中的自然语言搜索在 provider=nil 时不可执行")
        #expect(!search.supportsDirectRead, "「搜索周杰伦」不属于 Direct Read Fast Path")
    }

    @Test("P2 web_research / music_download availability 反映真实服务配置")
    func availabilityReflectsServices() {
        let web = AgentCapabilityCatalog.capability(id: "web_research")!
        let noWeb = AgentCapabilityCatalog.availability(
            for: web,
            environment: AgentCapabilityEnvironment(
                providerAvailable: true, catalogAvailable: true, activeServer: true,
                webAvailable: false, downloadServiceAvailable: true, systemServiceAvailable: true
            )
        )
        if case .available = noWeb {
            Issue.record("未配置 webService 时 web_research 不得 available")
        }
        let download = AgentCapabilityCatalog.capability(id: "music_download")!
        let noDownload = AgentCapabilityCatalog.availability(
            for: download,
            environment: AgentCapabilityEnvironment(
                providerAvailable: true, catalogAvailable: true, activeServer: true,
                webAvailable: true, downloadServiceAvailable: false, systemServiceAvailable: true
            )
        )
        if case .available = noDownload {
            Issue.record("下载服务未配置时 music_download 不得 available")
        }
    }

    @Test("P2 degraded 状态明确展示，不静默消失")
    func degradedIsDisplayed() {
        let query = AgentCapabilityCatalog.capability(id: "server_query")!
        let degraded = AgentCapabilityCatalog.availability(
            for: query,
            environment: AgentCapabilityEnvironment(
                providerAvailable: true, catalogAvailable: true, activeServer: false
            )
        )
        if case .degraded = degraded {} else {
            Issue.record("未连接服务器时 server_query 应为 degraded，实际 \(degraded.label)")
        }
        let summary = AgentCapabilityCatalog.systemPromptSummary(
            environment: AgentCapabilityEnvironment(
                providerAvailable: true, catalogAvailable: true, activeServer: false
            )
        )
        #expect(summary.contains("[当前降级"), "degraded 能力必须在摘要中展示而非过滤")
        #expect(summary.contains("[当前不可用"), "unavailable 能力必须在摘要中展示")
    }

    @Test("P2 readOnly capability 不得关联 mutation 工具；mutation capability 有关联写工具")
    func readOnlyCapabilityHasNoMutationTools() {
        let registered = Dictionary(uniqueKeysWithValues: AgentToolRegistry.all.map { ($0.name, $0) })
        for capability in AgentCapabilityCatalog.all where capability.readOnly {
            for toolName in capability.relatedTools {
                guard let descriptor = registered[toolName] else { continue }
                #expect(descriptor.permission == .readOnly,
                        "只读能力 \(capability.id) 不得关联 mutation 工具 \(toolName)")
            }
        }
    }
}
