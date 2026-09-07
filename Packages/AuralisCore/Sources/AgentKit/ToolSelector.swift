import AIKit
import Foundation

/// Schema shortlist ranking derived from the canonical ToolDescriptor catalog.
///
/// This type is deliberately not a second registry.  Group, namespace, tags,
/// permission and canonical operation metadata are used to rank a first-round
/// shortlist. A model-visible tool that is not
/// shortlisted remains discoverable through tool_search and executable through
/// ToolRuntime.
public enum ToolSelector {
    /// Legacy aliases are an input-compatibility map, not model-visible tools.
    /// Keeping this map here is intentional: it is the one compatibility
    /// boundary used when deduplicating old names into canonical schemas.
    static let canonicalAliases: [String: String] = [
        "searchTracks": "library_search",
        "searchAlbums": "library_search",
        "searchArtists": "library_search",
        "getTrack": "library_get_song",
        "getAlbum": "library_get_album",
        "getArtist": "library_get_artist",
        "getFavorites": "library_get_starred",
        "getRecentHistory": "library_get_recently_played",
        "getSimilarTracks": "library_get_similar_songs",
        "getPlaylist": "library_get_playlist",
        "playTrack": "playback_play_song",
        "playAlbum": "playback_play_album",
        "playPlaylist": "playback_play_playlist",
        "pause": "playback_pause",
        "resume": "playback_resume",
        "next": "playback_next",
        "previous": "playback_previous",
        "seek": "playback_seek",
        "addToQueue": "queue_append",
        "playNext": "queue_play_next",
        "replaceQueue": "queue_replace",
        "clearQueue": "queue_clear",
        "addTracksToPlaylist": "playlist_add_songs",
        "listPlaylists": "playlist_list",
        "listServers": "server_list",
        "getActiveServer": "server_get_current",
        "testServerConnection": "server_test_connection",
        "likeTrack": "favorite_set",
        "unlikeTrack": "favorite_set",
        "favoriteAlbum": "favorite_set",
        "unfavoriteAlbum": "favorite_set",
        "favoriteArtist": "favorite_set",
        "unfavoriteArtist": "favorite_set",
        "getLeastPlayed": "library_get_least_played",
        "getDownloadedTracks": "library_get_downloaded",
        "removeFromQueue": "queue_remove",
        "renamePlaylist": "playlist_rename",
        "removeTracksFromPlaylist": "playlist_remove_songs",
        "reorderPlaylist": "playlist_move",
        "duplicatePlaylist": "playlist_duplicate",
        "mergePlaylists": "playlist_merge",
        "deletePlaylist": "playlist_delete",
        "setRating": "rating_set",
        "clearRating": "rating_set",
        "switchServer": "server_switch",
        "removeServer": "server_remove",
    ]

    static func resolvedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names
            .map { canonicalAliases[$0] ?? $0 }
            .filter { seen.insert($0).inserted }
    }

    public static func select(for userText: String, all: [ToolDescriptor]) -> [ToolDescriptor] {
        select(
            for: userText,
            all: all,
            allowAmbiguousContinuation: true,
            activeSkillID: nil
        )
    }

    /// Production entry point：消费一次 turn 的共享 `AgentRequestPlan`，不再
    /// 自己重新分析用户文本（避免与 Authorization / Intent 的 split-brain）。
    /// 同时接收 operation metadata。它只影响相关性排序，不把普通 mutation
    /// schema 变成 exact-operation 白名单。
    public static func select(
        plan: AgentRequestPlan,
        all: [ToolDescriptor],
        activeSkillID: String? = nil
    ) -> [ToolDescriptor] {
        shortlist(
            semantics: plan.semantics,
            intent: plan.intent,
            all: all,
            activeSkillID: activeSkillID,
            allowedOperations: plan.authorization.allowedOperations,
            userText: plan.currentUserText
        )
    }

    private static func select(
        for userText: String,
        all: [ToolDescriptor],
        allowAmbiguousContinuation: Bool,
        activeSkillID: String?
    ) -> [ToolDescriptor] {
        let historyText = allowAmbiguousContinuation
            ? AgentHistoryPolicy.relevantHistoryText(for: userText, in: [])
            : ""
        let semantics = AgentRequestSemantics.analyze(userText, historyText: historyText)
        return shortlist(
            semantics: semantics,
            intent: nil,
            all: all,
            activeSkillID: activeSkillID,
            allowedOperations: nil
        )
    }

    /// Intent-aware overload retained for compatibility. Intent contributes a
    /// ranking hint only; the descriptor catalog still supplies every name.
    /// 注意：这里没有 relevant history（兼容旧调用方）；production 路径请使用
    /// `select(plan:all:activeSkillID:)`。
    public static func select(
        for userText: String,
        intent: AgentTaskIntent,
        policy: AgentTaskPolicy,
        all: [ToolDescriptor],
        activeSkillID: String? = nil
    ) -> [ToolDescriptor] {
        _ = policy
        let semantics = AgentRequestSemantics.analyze(userText)
        return shortlist(
            semantics: semantics,
            intent: intent,
            all: all,
            activeSkillID: activeSkillID,
            allowedOperations: nil
        )
    }

    private static func shortlist(
        semantics: AgentRequestSemantics,
        intent: AgentTaskIntent?,
        all: [ToolDescriptor],
        activeSkillID: String?,
        allowedOperations: Set<ToolAuthorizationOperation>?,
        userText: String = ""
    ) -> [ToolDescriptor] {
        let visible = all.filter { $0.isVisible(toSkillID: activeSkillID) }
        var selected: [ToolDescriptor] = []
        var selectedNames = Set<String>()

        func append(_ descriptors: [ToolDescriptor]) {
            for descriptor in descriptors {
                // A pure recommendation is discovery-only. Keep this guard at
                // the shared append boundary so intent hints, broker recall,
                // and recommendation expansion cannot re-introduce an
                // unrelated reversible mutation after the semantic pass.
                // Explicit requests such as “推荐并加入队列” carry the
                // concrete operation and therefore remain eligible.
                guard !(semantics.domain == .recommendation
                    && semantics.requestedOperations.isEmpty
                    && descriptor.permission != .readOnly) else { continue }
                let canonical = canonicalAliases[descriptor.name] ?? descriptor.name
                guard canonical == descriptor.name, selectedNames.insert(canonical).inserted else {
                    continue
                }
                selected.append(descriptor)
            }
        }

        if let directReadCapability = semantics.directReadCapability {
            append(visible.filter { $0.name == directReadCapability.toolName })
            return selected
        }

        append(visible.filter { $0.isCoreInfrastructure })

        // High-confidence read queries have a single canonical entry point.
        // This prevents a bare “列出歌单” from receiving detail/mutation
        // adjacent schemas and avoids making the model rediscover a simple
        // local read through tool_search.
        if semantics.domain == .playlist, semantics.operation == .read {
            append(visible.filter { $0.name == "playlist_list" })
            return selected
        }

        // Appreciation has one canonical evidence collector. Keep it explicitly
        // admitted so weak models do not mistake a generic library search for
        // the first step of “鉴赏这首歌”.
        if semantics.isMusicAppreciation {
            append(visible.filter { $0.name == "music_appreciate" })
        }

        append(visible.filter { descriptor in
            matches(descriptor, semantics: semantics, allowedOperations: allowedOperations)
        })

        // A discovery request often contains a playback verb (for example
        // “给我放一组适合通勤的歌”).  Keep the semantic domain as the source
        // of truth, but add the catalog/queue/annotation capabilities that a
        // music-discovery workflow may need.  This is descriptor metadata,
        // not a second name registry; descriptor risk decides whether a
        // mutation needs visible confirmation.
        if semantics.isMusicContext,
           semantics.suggestedToolNamespaces.contains("recommendation") {
            append(visible.filter { descriptor in
                discoveryExpansionMatches(
                    descriptor,
                    semantics: semantics,
                    allowedOperations: allowedOperations
                )
            })
        }

        // A legacy classifier can still provide a useful ranking hint while
        // the semantic analyzer remains conservative.  It must never broaden
        // ordinary conversation or non-music requests.
        if let intent {
            append(visible.filter { descriptor in
                intentMatches(descriptor, intent: intent, semantics: semantics, allowedOperations: allowedOperations)
            })
        }

        // Stateful control tools are never surfaced; only status/read are
        // model-visible. Skill-only descriptors are included only when the
        // active skill explicitly owns them.
        if semantics.isRecommendationIndex || intent == .libraryManagement {
            append(visible.filter { descriptor in
                descriptor.tags.contains { $0.lowercased().contains("recommendation-index") }
                    || descriptor.name == "library_index_status"
                    || descriptor.name == "library_index_read"
            })
        }

        if let activeSkillID {
            append(visible.filter { $0.requiredSkillID == activeSkillID })
        }

        // Tool Broker：轻量确定性 relevance ranking（纯本地计算，不产生许可）。
        // 先做宽松召回：即使保守 semantics 第一层没有把工具放进 selected，
        // utteranceExample bigram 重叠或 operation metadata 命中的工具也会补进来。
        // priority 只参与相关工具间排序，不参与执行许可判定。
        let brokered = selected + brokerExtraRecall(
            visible: visible,
            selectedNames: selectedNames,
            userText: userText,
            semantics: semantics,
            allowedOperations: allowedOperations
        )
        let ranked = brokered.sorted { lhs, rhs in
            semanticScore(lhs, userText: userText, semantics: semantics) + lhs.discoveryMetadata.priority
                > semanticScore(rhs, userText: userText, semantics: semantics) + rhs.discoveryMetadata.priority
        }
        var finalSet = ranked
        var finalNames = Set(finalSet.map(\.name))
        // 前置依赖补全：mutation 工具需要真实 TrackID / PlaylistID 时，
        // 自动把解析/查找入口放进 shortlist（模型不用自己猜工具依赖）。
        var prerequisiteNames = Set<String>()
        let visibleByName = Dictionary(uniqueKeysWithValues: visible.map { ($0.name, $0) })
        let needsTrackResolution = ranked.contains { descriptor in
            descriptor.semanticInputs.contains("TrackID") || descriptor.semanticInputs.contains("TrackIDs")
        }
        if needsTrackResolution, !finalNames.contains("library_search"), !finalNames.contains("library_resolve_entity") {
            for name in ["library_search", "library_resolve_entity"] {
                if let tool = visibleByName[name], tool.permission == .readOnly, finalNames.insert(name).inserted {
                    prerequisiteNames.insert(name)
                    finalSet.append(tool)
                }
            }
        }
        let needsPlaylistResolution = ranked.contains { descriptor in
            descriptor.semanticInputs.contains("PlaylistID")
        }
        if needsPlaylistResolution, !finalNames.contains("playlist_list") {
            if let tool = visibleByName["playlist_list"], tool.permission == .readOnly, finalNames.insert("playlist_list").inserted {
                prerequisiteNames.insert("playlist_list")
                finalSet.append(tool)
            }
        }
        // Top-K：保底保留核心基础设施（tool_search / capabilities_get / result_present_tracks）。
        // 相关工具（score > 0）全部保留，只截断无关工具（score == 0）——保证模型
        // 需要的真实工具不被 Top-K 误伤，同时把无关 schema 挡在首轮之外。
        // 固定 Skill 激活时（activeSkillID != nil）完全不截断：候选收集阶段模型需要
        // 完整的只读检索面，截断会破坏"搜索 → 选歌"链路。
        if needsTrackResolution {
            prerequisiteNames.formUnion(finalNames.intersection(["library_search", "library_resolve_entity"]))
        }
        if needsPlaylistResolution { prerequisiteNames.insert("playlist_list") }
        let core = finalSet.filter { $0.isCoreInfrastructure || $0.name == "result_present_tracks" }
        let rest = finalSet.filter { !($0.isCoreInfrastructure || $0.name == "result_present_tracks") }
        if activeSkillID != nil {
            return core + rest
        }
        // legacy 调用方（allowedOperations == nil，无 authorization plan）保持完整
        // shortlist：兼容面不裁剪，避免破坏既有行为契约。
        // conversation 域（普通对话/模糊搜索）不裁剪：对话可能涉及任意能力，
        // 且模糊搜索（如“搜索胡广生”）需要保留两个检索入口供模型选择。
        if allowedOperations == nil || semantics.domain == .conversation {
            return core + rest
        }
        // A pronoun may give an entity resolver no lexical score. Preserve
        // execution prerequisites even when the Top-K filler budget is full.
        let relevant = rest.filter {
            prerequisiteNames.contains($0.name) || semanticScore($0, userText: userText, semantics: semantics) > 0
        }
        let fillerCount = max(ToolBrokerTopK - core.count - relevant.count, 0)
        let filler = rest.filter {
            !prerequisiteNames.contains($0.name) && semanticScore($0, userText: userText, semantics: semantics) == 0
        }
            .prefix(fillerCount)
        return core + relevant + filler
    }

    /// 宽松召回：保守 semantics 未命中的工具，只要 utteranceExample bigram 与用户
    /// 文本重叠、或 operation metadata 命中，就补进 shortlist。
    private static func brokerExtraRecall(
        visible: [ToolDescriptor],
        selectedNames: Set<String>,
        userText: String,
        semantics: AgentRequestSemantics,
        allowedOperations: Set<ToolAuthorizationOperation>?
    ) -> [ToolDescriptor] {
        let lower = userText.lowercased()
        let userGrams = cjkBigrams(of: lower)
        var result: [ToolDescriptor] = []
        for descriptor in visible {
            guard !selectedNames.contains(descriptor.name) else { continue }
            // Broker recall is still a relevance pass, but a discovery-only
            // request must not regain mutation schemas through an utterance
            // example (or a broad bigram) after recommendation expansion has
            // intentionally filtered them. Explicit mutation semantics may
            // use example recall when operation inference is incomplete.
            if descriptor.permission != .readOnly {
                guard semantics.isExplicitMutation else { continue }
                if !semantics.requestedOperations.isEmpty {
                    guard let operation = descriptor.authorizationOperation,
                          semantics.requestedOperations.contains(operation)
                    else { continue }
                }
            }
            let exampleHit = descriptor.utteranceExamples.contains { example in
                let exampleLower = example.lowercased()
                // 完整示例子串命中 = 高置信度 admission。
                if lower.contains(exampleLower) || exampleLower.contains(lower) { return true }
                // 宽松召回最低门槛：至少 2 个 bigram 重叠才纳入——单个高频二字词
                // （歌曲/播放/歌单/适合）不构成 admission 依据，防止 schema inflation。
                let overlap = userGrams.intersection(cjkBigrams(of: exampleLower))
                return overlap.count >= 2
            }
            let operationHit = descriptor.authorizationOperation.map {
                semantics.requestedOperations.contains($0)
            } ?? false
            if exampleHit || operationHit {
                result.append(descriptor)
            }
        }
        return result
    }

    /// CJK/ASCII bigram：连续字母段生成 2-gram，用于宽松示例匹配。
    private static func cjkBigrams(of text: String) -> Set<String> {
        let chars = Array(text.filter { $0.isLetter || $0.isNumber })
        guard chars.count >= 2 else { return [] }
        var grams = Set<String>()
        for i in 0...(chars.count - 2) {
            grams.insert(String(chars[i...i + 1]))
        }
        return grams
    }

    /// 模型首轮 schema 的 Top-K 目标规模（core 工具不占名额）。
    private static let ToolBrokerTopK = 10

    /// 轻量确定性语义 relevance score。**不含 priority**：priority 只参与相关
    /// 工具之间的排序，不决定"是否相关"——否则默认 priority 会让所有工具 score>0，
    /// Top-K 完全失效。数值是 ranking 提示，不是授权。
    private static func semanticScore(
        _ descriptor: ToolDescriptor,
        userText: String,
        semantics: AgentRequestSemantics
    ) -> Int {
        var score = 0
        let lower = userText.lowercased()
        if semantics.isMusicAppreciation, descriptor.name == "music_appreciate" {
            score += 10_000
        }
        // 1) 精确授权操作命中（最相关）。
        if let operation = descriptor.authorizationOperation,
           semantics.requestedOperations.contains(operation) {
            score += 1000
        }
        // 2) 自然语言示例命中（完整示例子串）。
        for example in descriptor.utteranceExamples where lower.contains(example.lowercased()) {
            score += 500
            break
        }
        // 3) 示例 bigram 重叠命中（宽松召回，正确分词：CJK 2-gram）。
        let userGrams = cjkBigrams(of: lower)
        for example in descriptor.utteranceExamples {
            let overlap = userGrams.intersection(cjkBigrams(of: example.lowercased()))
            if !overlap.isEmpty {
                score += 120
                break
            }
        }
        // 4) domain / namespace 匹配。
        if descriptor.namespace == semantics.domain.rawValue
            || descriptor.group.rawValue == semantics.domain.rawValue {
            score += 150
        }
        // 5) tags 命中。
        if descriptor.tags.contains(where: { $0.lowercased().count >= 2 && lower.contains($0.lowercased()) }) {
            score += 100
        }
        // 6) summary 关键词弱命中。
        if descriptor.summary.count >= 2, lower.count >= 2,
           descriptor.summary.lowercased().contains(lower.prefix(2)) {
            score += 40
        }
        return score
    }

    private static func matches(
        _ descriptor: ToolDescriptor,
        semantics: AgentRequestSemantics,
        allowedOperations: Set<ToolAuthorizationOperation>?
    ) -> Bool {
        guard descriptor.visibility == .model else { return false }
        guard descriptor.name != "tool_search" else { return false }
        guard descriptor.requiredSkillID == nil else { return false }

        let metadata = descriptor.discoveryMetadata
        let tags = Set(descriptor.tags.map { $0.lowercased() })
        let name = descriptor.name.lowercased()
        let isReadRequest = semantics.operation == .read || semantics.operation == .discover
        let exactOperation = descriptor.authorizationOperation.map {
            semantics.requestedOperations.contains($0)
        } ?? false

        if exactOperation {
            // Explicitly named operations win relevance ranking; they are not
            // a runtime permission grant.
            return true
        }

        func has(_ values: String...) -> Bool {
            values.contains { value in
                let lower = value.lowercased()
                return name.contains(lower)
                    || tags.contains(where: { $0.contains(lower) })
                    || metadata.capabilities.contains(where: { $0.lowercased().contains(lower) })
            }
        }

        func readOnly(_ value: Bool = isReadRequest) -> Bool {
            // Read/discovery requests only receive read schemas. Once the
            // semantic domain is an explicit mutation, relevant reversible or
            // destructive tools remain discoverable; confirmation is decided
            // by the descriptor at execution time.
            !value || descriptor.permission == .readOnly
        }

        func mutationRelevant() -> Bool {
            // This is shortlist relevance, not an authorization decision. If
            // the classifier has no operation metadata, keep the local
            // mutation visible so a model/tool_search can still recover from
            // an imperfect semantic parse. When it does have a concrete
            // operation, avoid flooding an explicit request such as “暂停”
            // with unrelated queue or playlist schemas.
            guard descriptor.permission != .readOnly else { return true }
            guard !semantics.requestedOperations.isEmpty else { return true }
            guard let operation = descriptor.authorizationOperation else { return true }
            return semantics.requestedOperations.contains(operation)
        }

        func relevantMutationOrRead() -> Bool {
            readOnly() && mutationRelevant()
        }

        let domain = semantics.domain
        switch domain {
        case .conversation:
            // Generic chat starts compact. For an ambiguous “search” request,
            // expose both search entrances, with web ranked by its metadata.
            guard semantics.suggestedToolNamespaces.contains("web")
                || semantics.suggestedToolNamespaces.contains("catalog") else {
                return false
            }
            return descriptor.permission == .readOnly && has("search", "resolve", "web")

        case .web:
            // Public-web requests must not surface local library search just
            // because both descriptors contain the word "search". The
            // catalog entrance remains available through tool_search when a
            // user explicitly asks for a local-library lookup.
            return descriptor.permission == .readOnly
                && descriptor.group == .server
                && has("web", "search", "fetch")

        case .system:
            return descriptor.permission == .readOnly
                && (descriptor.group == .catalog || has("device", "app", "network", "storage", "siri", "shortcut"))

        case .musicLibrary:
            if descriptor.group == .catalog || descriptor.group == .server {
                return relevantMutationOrRead()
            }
            return false

        case .playback:
            if descriptor.group == .playback {
                // Queue tools are routed through the queue domain even though
                // the legacy registry stores them in the playback group.
                if descriptor.permission != .readOnly, descriptor.sideEffectPolicy == .queue {
                    return false
                }
                return relevantMutationOrRead()
            }
            return descriptor.permission == .readOnly && has("search", "resolve", "current", "now playing")

        case .queue:
            if has("queue") || descriptor.sideEffectPolicy == .queue {
                return relevantMutationOrRead()
            }
            return false

        case .playlist:
            if descriptor.group == .playlist || has("playlist") {
                return relevantMutationOrRead()
            }
            return descriptor.permission == .readOnly && has("search", "resolve")

        case .recommendation:
            // Recommendation is a read/discovery hint. Any mutation must be
            // explicitly represented by a matching operation or routed to its
            // concrete domain instead.
            return descriptor.permission == .readOnly
                && (descriptor.group == .catalog
                    || descriptor.group == .playback
                    || has("recommend", "similar", "random", "mood", "constraint"))

        case .diagnostics:
            return descriptor.permission == .readOnly
                && (has("diagnostic", "error", "cache", "duplicate", "metadata", "unplayable", "storage", "stats")
                    || descriptor.group == .catalog)

        case .download:
            return (descriptor.group == .download || has("download", "offline"))
                && relevantMutationOrRead()

        case .memory:
            return descriptor.group == .memory && relevantMutationOrRead()
        case .server:
            return descriptor.group == .server && relevantMutationOrRead()
        case .customTool:
            return relevantMutationOrRead()
                && (descriptor.namespace == "tool_builder" || descriptor.customToolID != nil)
        }

    }

    private static func discoveryExpansionMatches(
        _ descriptor: ToolDescriptor,
        semantics: AgentRequestSemantics,
        allowedOperations: Set<ToolAuthorizationOperation>?
    ) -> Bool {
        guard descriptor.visibility == .model, descriptor.requiredSkillID == nil else { return false }

        // Recommendation is a discovery/read workflow. Do not widen it into
        // an implicit mutation surface: a recommendation request commonly has
        // no requestedOperations at all, and exposing queue/favorite/playback
        // mutations here would let a weak model perform an unrelated local
        // write now that Runtime no longer uses exact-operation authorization
        // as a blanket execution gate. Mutation schemas are admitted only when
        // semantics carries the concrete operation (or a fixed Skill owns the
        // workflow and bypasses this model-visible shortlist).
        let mutationIsRelevant: Bool = {
            guard descriptor.permission != .readOnly else { return true }
            guard semantics.isExplicitMutation, !semantics.requestedOperations.isEmpty else { return false }
            guard let operation = descriptor.authorizationOperation else { return true }
            return semantics.requestedOperations.contains(operation)
        }()

        switch descriptor.group {
        case .catalog, .annotation:
            return descriptor.permission == .readOnly || mutationIsRelevant
        case .playback:
            // Queue and playback descriptors are grouped together in the
            // canonical registry. Read-only state is always useful; mutation
            // schemas are discoverable for explicit music workflows.
            // Destructive descriptors still use the visible confirmation path.
            return descriptor.permission == .readOnly || mutationIsRelevant
        default:
            return false
        }
    }

    private static func intentMatches(
        _ descriptor: ToolDescriptor,
        intent: AgentTaskIntent,
        semantics: AgentRequestSemantics,
        allowedOperations: Set<ToolAuthorizationOperation>?
    ) -> Bool {
        guard descriptor.visibility == .model,
              descriptor.requiredSkillID == nil,
              intent != .conversation
        else { return false }

        func relevantMutationOrRead(_ descriptor: ToolDescriptor) -> Bool {
            guard descriptor.permission != .readOnly else { return true }
            guard !semantics.requestedOperations.isEmpty else { return true }
            guard let operation = descriptor.authorizationOperation else { return true }
            return semantics.requestedOperations.contains(operation)
        }

        let name = descriptor.name.lowercased()
        let tags = descriptor.tags.map { $0.lowercased() }
        func has(_ terms: String...) -> Bool {
            terms.contains { term in
                let value = term.lowercased()
                return name.contains(value) || tags.contains(where: { $0.contains(value) })
            }
        }

        switch intent {
        case .librarySearch:
            return descriptor.permission == .readOnly && (descriptor.group == .catalog || has("search", "resolve", "catalog"))
        case .playbackControl:
            guard descriptor.group == .playback else { return false }
            if descriptor.permission != .readOnly, descriptor.sideEffectPolicy == .queue {
                return false
            }
            return relevantMutationOrRead(descriptor)
        case .playbackQuery:
            return descriptor.permission == .readOnly && (descriptor.group == .playback || has("playback", "current", "queue"))
        case .musicDiscovery:
            return discoveryExpansionMatches(
                descriptor,
                semantics: semantics,
                allowedOperations: allowedOperations
            )
        case .queueManagement, .queueQuery:
            if (descriptor.group == .playback && descriptor.sideEffectPolicy == .queue) || has("queue") {
                return relevantMutationOrRead(descriptor)
            }
            return descriptor.permission == .readOnly && has("genre", "select", "catalog")
        case .playlistManagement, .playlistQuery:
            if descriptor.group == .playlist || has("playlist") {
                return relevantMutationOrRead(descriptor)
            }
            return descriptor.permission == .readOnly && has("search", "catalog")
        case .libraryManagement:
            return descriptor.group == .catalog
        case .serverManagement:
            return descriptor.group == .server && relevantMutationOrRead(descriptor)
        case .diagnostics:
            return descriptor.permission == .readOnly && (descriptor.group == .catalog || has("diagnostic", "error", "cache", "stats"))
        case .musicAppreciation:
            return descriptor.permission == .readOnly && (descriptor.group == .catalog || has("music", "evidence", "search"))
        case .musicDownload:
            return (descriptor.group == .download || has("download", "offline", "server"))
                && relevantMutationOrRead(descriptor)
        case .memoryManagement:
            return descriptor.group == .memory && relevantMutationOrRead(descriptor)
        case .conversation:
            return false
        }
    }

    public static func toolDefinitions(from descriptors: [ToolDescriptor]) -> [AIToolDefinition] {
        toolDefinitions(from: descriptors, strict: false)
    }

    public static func toolDefinitions(
        from descriptors: [ToolDescriptor],
        strict: Bool,
        activeSkillID: String? = nil
    ) -> [AIToolDefinition] {
        descriptors
            .filter { $0.isVisible(toSkillID: activeSkillID) }
            .map { descriptor in
                AIToolDefinition(
                    name: descriptor.name,
                    description: descriptor.summary,
                    parametersJSON: Self.parametersJSON(for: descriptor),
                    strict: strict
                )
            }
    }

    /// 由 ToolParameter 生成最小 JSON Schema。
    static func parametersJSON(for descriptor: ToolDescriptor) -> String? {
        var properties: [String: Any] = [:]
        for parameter in descriptor.parameters {
            if let schemaJSON = parameter.schemaJSON,
               let data = schemaJSON.data(using: .utf8),
               var schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                schema["description"] = parameter.description
                properties[parameter.name] = schema
            } else {
                properties[parameter.name] = [
                    "type": "string",
                    "description": parameter.description,
                ]
            }
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": descriptor.parameters.filter { $0.required }.map { $0.name },
            "additionalProperties": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: schema) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

