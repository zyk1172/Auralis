import AIKit
import Domain
import Foundation
import LocalCatalog

/// 单个工具参数的声明，用于参数校验与系统提示生成。
public struct ToolParameter: Sendable, Hashable {
    public let name: String
    public let required: Bool
    public let description: String
    /// 可选的完整 JSON Schema 片段。未提供时参数仍按字符串声明；用于索引批次这类
    /// 原生结构化参数，避免模型先把数组转义成字符串再传回工具。
    public let schemaJSON: String?

    public init(name: String, required: Bool, description: String, schemaJSON: String? = nil) {
        self.name = name
        self.required = required
        self.description = description
        self.schemaJSON = schemaJSON
    }
}

public enum ToolCachePolicy: String, Sendable, Hashable {
    case none
    case task
}

public enum ToolSideEffectPolicy: String, Codable, Sendable, Hashable {
    case none
    case playback
    case queue
    case playlist
    case annotation
    case server
    case download
    case memory
}

/// Least-privilege operation names used by the side-effect boundary.  A broad
/// `ToolSideEffectPolicy` remains as a compatibility fallback for descriptors
/// that have not yet declared a more specific operation.
public enum ToolAuthorizationOperation: String, Codable, Sendable, Hashable, CaseIterable {
    case playbackPlay
    case playbackPause
    case playbackNavigation
    case playbackSeek
    case playbackMode
    case playbackTimer
    case queueAppend
    case queuePlayNext
    case queueReplace
    case queueClear
    case queueRemove
    case queueMove
    case queueShuffle
    case playlistCreate
    case playlistAdd
    case playlistRemove
    case playlistMove
    case playlistRename
    case playlistDuplicate
    case playlistMerge
    case playlistDelete
    case playlistSaveQueue
    case favoriteSet
    case ratingSet
    case dislikedSet
    case recommendationIndexWrite
    case serverSync
    case serverSwitch
    case serverRemove
    case serverConfigure
    case downloadSubmit
    case downloadHistoryRemove
    case downloadHistoryClean
    case offlineDownload
    case memorySave
    case memoryDelete
    case memoryClear
    case skillCreate
    case skillDelete
    case customToolCreate
    case customToolUpdate
    case customToolEnable
    case customToolDisable
    case customToolDelete
    case customToolRepair
}

/// The authorization result is deliberately typed. A missing operation is
/// never a textual hint for the model or the user to reinterpret as consent.
/// The only interactive approval path is `ToolDescriptor.confirmationPolicy`.
public enum ToolAuthorizationDecision: Sendable, Equatable {
    case allowed
    case denied(reason: String)
}

/// Authorization is derived once from the semantic result at the task/session
/// boundary. External tool data is never added to this set, so a web page
/// cannot authorize a later queue, playlist, download, server, playback or
/// memory mutation. A short continuation is not a new authorization source;
/// it may only inherit the already-created execution lineage.
public struct SideEffectAuthorizationContext: Sendable, Hashable {
    public let originalUserRequest: String
    public let explicitlyRequestedEffects: Set<ToolSideEffectPolicy>
    public let allowedOperations: Set<ToolAuthorizationOperation>
    public let allowedScopes: Set<MutationScope>

    public init(
        originalUserRequest: String,
        semantics: AgentRequestSemantics? = nil
    ) {
        self.originalUserRequest = originalUserRequest
        let resolvedSemantics = semantics ?? AgentRequestSemantics.analyze(originalUserRequest)
        let operations = resolvedSemantics.requestedOperations
        self.allowedOperations = operations
        self.allowedScopes = Set(operations.compactMap(Self.scope(for:)))
        self.explicitlyRequestedEffects = Set(operations.compactMap(Self.effect(for:)))
    }

    public init(sourceRequest: String, semantics: AgentRequestSemantics) {
        self.init(originalUserRequest: sourceRequest, semantics: semantics)
    }

    private init(
        originalUserRequest: String,
        explicitlyRequestedEffects: Set<ToolSideEffectPolicy>,
        allowedOperations: Set<ToolAuthorizationOperation>,
        allowedScopes: Set<MutationScope>
    ) {
        self.originalUserRequest = originalUserRequest
        self.explicitlyRequestedEffects = explicitlyRequestedEffects
        self.allowedOperations = allowedOperations
        self.allowedScopes = allowedScopes
    }

    /// A declarative Custom Tool may contain several canonical operations.
    /// Children inherit only those exact operations. A scope is deliberately
    /// not expanded into every operation in that scope: authorizing playlist
    /// add must not authorize playlist rename/remove/delete.
    public func granting(operations: Set<ToolAuthorizationOperation>) -> SideEffectAuthorizationContext {
        guard !operations.isEmpty else { return self }
        let scopes = Set(operations.compactMap(\.mutationScope))
        let effects = explicitlyRequestedEffects.union(Set(operations.compactMap(Self.effect(for:))))
        return SideEffectAuthorizationContext(
            originalUserRequest: originalUserRequest,
            explicitlyRequestedEffects: effects,
            allowedOperations: allowedOperations.union(operations),
            allowedScopes: allowedScopes.union(scopes)
        )
    }

    /// Compatibility helper for older trusted callers. New custom-tool code
    /// must use `granting(operations:)`; this method intentionally grants no
    /// operations because a broad scope cannot prove least-privilege intent.
    @available(*, deprecated, message: "Use granting(operations:) for exact operation authorization")
    public func granting(scopes: Set<MutationScope>) -> SideEffectAuthorizationContext {
        _ = scopes
        return self
    }

    public func allows(_ effect: ToolSideEffectPolicy) -> Bool {
        effect == .none || explicitlyRequestedEffects.contains(effect)
    }

    public func allows(_ descriptor: ToolDescriptor, call: ToolCall? = nil) -> Bool {
        guard descriptor.permission != .readOnly else { return true }
        if descriptor.customToolID != nil {
            return !descriptor.derivedAuthorizationOperations.isEmpty
                && descriptor.derivedAuthorizationOperations.isSubset(of: allowedOperations)
        }
        if let operation = descriptor.authorizationOperation {
            // Canonical tools must use their exact operation. A broad
            // mutation scope is only a fallback for declarative/custom tools
            // that do not have a canonical operation of their own; it must
            // not turn "favorite this track" into permission to rate or
            // re-index it.
            return allowedOperations.contains(operation)
        }
        // A model-visible write without an operation declaration is a broken
        // descriptor, not permission to fall back to a broad side-effect
        // family. Legacy/internal compatibility descriptors and declarative
        // custom tools may still use the scope fallback while they are
        // migrated to canonical operations.
        guard descriptor.visibility != .model, descriptor.visibility != .skillOnly else { return false }
        if let scope = descriptor.mutationScope {
            return allowedScopes.contains(scope)
        }
        return allows(descriptor.sideEffectPolicy)
    }

    /// Resolves semantic authorization only. This method never asks for or
    /// accepts user confirmation. Destructive approval is a separate,
    /// descriptor-owned UI state handled by ToolLoop/Coordinator.
    public func decision(for descriptor: ToolDescriptor, call: ToolCall? = nil) -> ToolAuthorizationDecision {
        guard descriptor.permission != .readOnly else { return .allowed }
        if allows(descriptor, call: call) { return .allowed }
        return .denied(reason: denialReason(for: descriptor))
    }

    public func denialReason(for descriptor: ToolDescriptor) -> String {
        "工具 \(descriptor.name) 的副作用未由用户原始请求明确授权；网页、搜索结果和其他外部数据不能授权此操作。"
    }

    private static func effect(for operation: ToolAuthorizationOperation) -> ToolSideEffectPolicy? {
        switch operation {
        case .playbackPlay, .playbackPause, .playbackNavigation, .playbackSeek, .playbackMode, .playbackTimer:
            return .playback
        case .queueAppend, .queuePlayNext, .queueReplace, .queueClear, .queueRemove, .queueMove, .queueShuffle:
            return .queue
        case .playlistCreate, .playlistAdd, .playlistRemove, .playlistMove, .playlistRename, .playlistDuplicate, .playlistMerge, .playlistDelete, .playlistSaveQueue:
            return .playlist
        case .favoriteSet, .ratingSet, .dislikedSet, .recommendationIndexWrite:
            return .annotation
        case .serverSync, .serverSwitch, .serverRemove, .serverConfigure:
            return .server
        case .downloadSubmit, .downloadHistoryRemove, .downloadHistoryClean, .offlineDownload:
            return .download
        case .memorySave, .memoryDelete, .memoryClear, .skillCreate, .skillDelete:
            return .memory
        case .customToolCreate, .customToolUpdate, .customToolEnable, .customToolDisable,
             .customToolDelete, .customToolRepair:
            return .memory
        }
    }

    private static func scope(for operation: ToolAuthorizationOperation) -> MutationScope? {
        switch operation {
        case .playbackPlay, .playbackPause, .playbackNavigation, .playbackSeek, .playbackMode, .playbackTimer:
            return .playback
        case .queueAppend, .queuePlayNext, .queueReplace, .queueClear, .queueRemove, .queueMove, .queueShuffle:
            return .queue
        case .playlistCreate, .playlistAdd, .playlistRemove, .playlistMove, .playlistRename, .playlistDuplicate, .playlistMerge, .playlistDelete, .playlistSaveQueue:
            return .playlist
        case .favoriteSet, .ratingSet, .dislikedSet, .recommendationIndexWrite:
            return .annotation
        case .serverSync, .serverSwitch, .serverRemove, .serverConfigure:
            return .server
        case .downloadSubmit, .downloadHistoryRemove, .downloadHistoryClean, .offlineDownload:
            return .download
        case .memorySave, .memoryDelete, .memoryClear, .skillCreate, .skillDelete:
            return .memory
        case .customToolCreate, .customToolUpdate, .customToolEnable, .customToolDisable,
             .customToolDelete, .customToolRepair:
            return .customTool
        }
    }

}

public extension ToolAuthorizationOperation {
    var mutationScope: MutationScope? {
        switch self {
        case .playbackPlay, .playbackPause, .playbackNavigation, .playbackSeek, .playbackMode, .playbackTimer:
            return .playback
        case .queueAppend, .queuePlayNext, .queueReplace, .queueClear, .queueRemove, .queueMove, .queueShuffle:
            return .queue
        case .playlistCreate, .playlistAdd, .playlistRemove, .playlistMove, .playlistRename, .playlistDuplicate, .playlistMerge, .playlistDelete, .playlistSaveQueue:
            return .playlist
        case .favoriteSet, .ratingSet, .dislikedSet, .recommendationIndexWrite:
            return .annotation
        case .serverSync, .serverSwitch, .serverRemove, .serverConfigure:
            return .server
        case .downloadSubmit, .downloadHistoryRemove, .downloadHistoryClean, .offlineDownload:
            return .download
        case .memorySave, .memoryDelete, .memoryClear, .skillCreate, .skillDelete:
            return .memory
        case .customToolCreate, .customToolUpdate, .customToolEnable, .customToolDisable,
             .customToolDelete, .customToolRepair:
            return .customTool
        }
    }
}

public enum ToolEvidencePolicy: String, Sendable, Hashable {
    case none
    case localCatalog
    case playbackState
    case server
    case externalAPI
}

/// Controls which boundary may expose a registered tool.
///
/// Visibility is not an execution permission. Runtime lookup deliberately
/// keeps all three classes executable so old persisted calls and aliases keep
/// working, while model discovery and provider schemas only use `.model`,
/// unless a trusted built-in Stateful Skill explicitly activates `.skillOnly`.
public enum ToolVisibility: String, Codable, Sendable, Hashable {
    case model
    case skillOnly
    case legacyOnly
    case internalOnly
}

/// 工具元数据：分组、权限、展示角色、参数。
public struct ToolDescriptor: Sendable, Hashable {
    public let name: String
    public let namespace: String
    public let group: ToolGroup
    public let permission: ToolPermission
    /// Explicit approval is independent from mutation and authorization.
    public let confirmationPolicy: ToolConfirmationPolicy
    public let summary: String
    public let parameters: [ToolParameter]
    public let cachePolicy: ToolCachePolicy
    public let sideEffectPolicy: ToolSideEffectPolicy
    public let authorizationOperation: ToolAuthorizationOperation?
    public let evidencePolicy: ToolEvidencePolicy
    /// 执行该工具必须具备的任务能力域（deprecated / diagnostics-only）：
    /// permissive runtime 不再因缺少 scope 拒绝已注册工具，保留仅为迁移/日志兼容。
    public let requiredScopes: Set<GrantedScope>
    /// 默认展示角色：决定工具结果进入候选池 / 最终 / 歧义（Tool 执行可覆盖）。
    public let defaultPresentationRole: ToolPresentationRole
    public let maxResultCharacters: Int
    /// Searchable terms are part of the descriptor rather than a second
    /// keyword table owned by ToolSelector.
    public let tags: [String]
    public let outputSchemaJSON: String?
    public let idempotent: Bool
    public let parallelSafe: Bool
    public let networkAccess: Bool
    public let aliases: [String]
    public let visibility: ToolVisibility
    /// Built-in skill identifier required for a `.skillOnly` descriptor.
    /// User-authored prompt skills are never sufficient to unlock it.
    public let requiredSkillID: String?
    /// Non-nil only for a descriptor materialized from a persisted declarative
    /// Custom Tool manifest. These fields are derived by the registry and are
    /// never accepted from the manifest as user-controlled risk claims.
    public let customToolID: UUID?
    public let customToolVersion: Int?
    public let derivedMutationScopes: Set<MutationScope>
    public let derivedMutationResources: Set<MutationResource>
    public let derivedAuthorizationOperations: Set<ToolAuthorizationOperation>
    public let derivedRisk: ToolRisk?
    /// Canonical descriptors may declare reversibility explicitly. Custom
    /// descriptors use `derivedRisk`; ordinary writes default to reversible.
    public let declaredRisk: ToolRisk?

    public init(
        name: String,
        group: ToolGroup,
        permission: ToolPermission,
        confirmationPolicy: ToolConfirmationPolicy = .none,
        summary: String,
        parameters: [ToolParameter] = [],
        cachePolicy: ToolCachePolicy? = nil,
        sideEffectPolicy: ToolSideEffectPolicy? = nil,
        authorizationOperation: ToolAuthorizationOperation? = nil,
        evidencePolicy: ToolEvidencePolicy? = nil,
        requiredScopes: Set<GrantedScope>? = nil,
        defaultPresentationRole: ToolPresentationRole = .candidate,
        maxResultCharacters: Int = ContextManager.maxToolResultCharacters,
        namespace: String? = nil,
        tags: [String] = [],
        outputSchemaJSON: String? = nil,
        idempotent: Bool? = nil,
        parallelSafe: Bool? = nil,
        networkAccess: Bool? = nil,
        aliases: [String] = [],
        visibility: ToolVisibility? = nil,
        requiredSkillID: String? = nil,
        customToolID: UUID? = nil,
        customToolVersion: Int? = nil,
        derivedMutationScopes: Set<MutationScope> = [],
        derivedMutationResources: Set<MutationResource> = [],
        derivedAuthorizationOperations: Set<ToolAuthorizationOperation> = [],
        derivedRisk: ToolRisk? = nil,
        declaredRisk: ToolRisk? = nil
    ) {
        self.name = name
        self.namespace = namespace ?? group.rawValue
        self.group = group
        self.permission = permission
        self.confirmationPolicy = confirmationPolicy
        self.summary = summary
        self.parameters = parameters
        self.cachePolicy = cachePolicy ?? (permission == .readOnly ? .task : .none)
        let resolvedSideEffectPolicy = sideEffectPolicy ?? Self.defaultSideEffectPolicy(name: name, group: group, permission: permission)
        self.sideEffectPolicy = resolvedSideEffectPolicy
        self.authorizationOperation = authorizationOperation ?? Self.defaultAuthorizationOperation(name: name, group: group, permission: permission)
        self.evidencePolicy = evidencePolicy ?? Self.defaultEvidencePolicy(group: group, permission: permission)
        self.requiredScopes = requiredScopes ?? Self.defaultRequiredScopes(
            name: name,
            group: group,
            permission: permission,
            sideEffectPolicy: resolvedSideEffectPolicy
        )
        self.defaultPresentationRole = defaultPresentationRole
        self.maxResultCharacters = maxResultCharacters
        self.tags = tags.isEmpty ? [name, group.rawValue, summary] : tags
        self.outputSchemaJSON = outputSchemaJSON
        self.idempotent = idempotent ?? (permission == .readOnly)
        self.parallelSafe = parallelSafe ?? (permission == .readOnly)
        self.networkAccess = networkAccess ?? (group == .server || group == .download)
        self.aliases = aliases
        self.visibility = visibility ?? Self.defaultVisibility(for: name)
        self.requiredSkillID = requiredSkillID
        self.customToolID = customToolID
        self.customToolVersion = customToolVersion
        self.derivedMutationScopes = derivedMutationScopes
        self.derivedMutationResources = derivedMutationResources
        self.derivedAuthorizationOperations = derivedAuthorizationOperations
        self.derivedRisk = derivedRisk
        self.declaredRisk = declaredRisk
    }

    public func isVisible(toSkillID skillID: String? = nil) -> Bool {
        switch visibility {
        case .model:
            return true
        case .skillOnly:
            guard let requiredSkillID, let skillID else { return false }
            return requiredSkillID == skillID
        case .legacyOnly, .internalOnly:
            return false
        }
    }

    private static func defaultVisibility(for name: String) -> ToolVisibility {
        // These descriptors are retained as an execution/persistence
        // compatibility layer. Their canonical replacements are registered
        // separately and are the only schemas exposed to the model.
        let legacyNames: Set<String> = [
            "searchTracks", "searchAlbums", "searchArtists", "getTrack", "getAlbum", "getArtist",
            "getFavorites", "getRecentHistory", "getLeastPlayed", "getDownloadedTracks",
            "getSimilarTracks", "getCurrentTrack", "getCurrentQueue",
            "playTrack", "playAlbum", "playPlaylist", "pause", "resume", "seek", "next", "previous",
            "addToQueue", "playNext", "replaceQueue", "removeFromQueue", "reorderQueue", "clearQueue",
            "music_download",
            "listPlaylists", "getPlaylist", "createPlaylist", "renamePlaylist", "addTracksToPlaylist",
            "removeTracksFromPlaylist", "reorderPlaylist", "duplicatePlaylist", "mergePlaylists", "deletePlaylist",
            "likeTrack", "unlikeTrack", "favoriteAlbum", "unfavoriteAlbum", "favoriteArtist", "unfavoriteArtist",
            "setRating", "clearRating",
            "listServers", "getActiveServer", "testServerConnection", "addServer", "updateServer",
            "switchServer", "refreshLibrary", "getSyncStatus", "removeServer",
        ]
        return legacyNames.contains(name) ? .legacyOnly : .model
    }

    private static func defaultRequiredScopes(
        name: String,
        group: ToolGroup,
        permission: ToolPermission,
        sideEffectPolicy: ToolSideEffectPolicy
    ) -> Set<GrantedScope> {
        // 少数工具的注册分组是为了兼容旧 schema；它们的真实能力域必须按实际行为声明。
        switch name {
        case "music_appreciate":
            return [.catalogRead, .externalRead]
        case "recommendation_index_commit":
            return [.catalogRead, .annotationWrite]
        case "media_download_offline":
            return [.catalogRead, .downloadWrite]
        default:
            break
        }

        switch group {
        case .catalog:
            return permission == .readOnly ? [.catalogRead] : [.annotationWrite]
        case .playback:
            if permission == .readOnly { return [.catalogRead] }
            return sideEffectPolicy == .queue ? [.queueWrite] : [.playbackWrite]
        case .playlist:
            return permission == .readOnly ? [.catalogRead] : [.playlistWrite]
        case .annotation:
            return permission == .readOnly ? [.catalogRead] : [.annotationWrite]
        case .server:
            return permission == .readOnly ? [.serverRead] : [.serverWrite]
        case .download:
            return permission == .readOnly ? [.serverRead] : [.downloadWrite]
        case .memory:
            return permission == .readOnly ? [.memoryRead] : [.memoryWrite]
        }
    }

    private static func defaultEvidencePolicy(group: ToolGroup, permission: ToolPermission) -> ToolEvidencePolicy {
        guard permission == .readOnly else { return .none }
        return switch group {
        case .catalog: .localCatalog
        case .playback: .playbackState
        case .server, .download: .server
        case .playlist, .annotation, .memory: .none
        }
    }

    private static func defaultSideEffectPolicy(name: String, group: ToolGroup, permission: ToolPermission) -> ToolSideEffectPolicy {
        guard permission != .readOnly else { return .none }
        return switch group {
        case .playback: name.hasPrefix("queue_") || name == "replaceQueue" || name == "addToQueue" || name == "playNext" || name == "clearQueue" ? .queue : .playback
        case .playlist: .playlist
        case .annotation: .annotation
        case .server: .server
        case .download: .download
        case .memory: .memory
        case .catalog: name == "recommendation_index_commit" ? .annotation : .none
        }
    }

    private static func defaultAuthorizationOperation(
        name: String,
        group: ToolGroup,
        permission: ToolPermission
    ) -> ToolAuthorizationOperation? {
        guard permission != .readOnly else { return nil }
        switch name {
        case "playTrack", "playAlbum", "playPlaylist", "playback_play_song", "playback_play_album", "playback_play_artist", "playback_play_playlist", "playback_play_random":
            return .playbackPlay
        case "pause", "resume", "playback_pause", "playback_resume": return .playbackPause
        case "next", "previous", "playback_next", "playback_previous": return .playbackNavigation
        case "seek", "playback_seek": return .playbackSeek
        case "playback_set_shuffle", "playback_set_repeat", "playback_set_speed": return .playbackMode
        case "playback_set_sleep_timer", "playback_cancel_sleep_timer": return .playbackTimer
        case "addToQueue", "queue_append", "queue_append_many": return .queueAppend
        case "playNext", "queue_play_next", "queue_play_next_many": return .queuePlayNext
        case "replaceQueue", "queue_replace": return .queueReplace
        case "clearQueue", "queue_clear": return .queueClear
        case "removeFromQueue", "queue_remove": return .queueRemove
        case "reorderQueue", "queue_move": return .queueMove
        case "queue_shuffle_remaining": return .queueShuffle
        case "createPlaylist", "playlist_create": return .playlistCreate
        case "addTracksToPlaylist", "playlist_add_songs": return .playlistAdd
        case "removeTracksFromPlaylist", "playlist_remove_songs": return .playlistRemove
        case "reorderPlaylist", "playlist_move": return .playlistMove
        case "renamePlaylist", "playlist_rename": return .playlistRename
        case "duplicatePlaylist", "playlist_duplicate": return .playlistDuplicate
        case "mergePlaylists", "playlist_merge": return .playlistMerge
        case "deletePlaylist", "playlist_delete": return .playlistDelete
        case "queue_save_as_playlist": return .playlistSaveQueue
        case "likeTrack", "unlikeTrack", "favoriteAlbum", "unfavoriteAlbum", "favoriteArtist", "unfavoriteArtist", "favorite_set": return .favoriteSet
        case "setRating", "clearRating", "rating_set": return .ratingSet
        case "preference_set_disliked": return .dislikedSet
        case "recommendation_index_commit": return .recommendationIndexWrite
        case "server_sync_start": return .serverSync
        case "server_switch", "switchServer": return .serverSwitch
        case "server_remove", "removeServer": return .serverRemove
        case "addServer", "updateServer": return .serverConfigure
        case "music_download_submit": return .downloadSubmit
        case "music_download_history_remove": return .downloadHistoryRemove
        case "music_download_history_clean": return .downloadHistoryClean
        case "media_download_offline": return .offlineDownload
        case "memory_save": return .memorySave
        case "memory_delete": return .memoryDelete
        case "memory_clear": return .memoryClear
        case "skill_create": return .skillCreate
        case "skill_delete": return .skillDelete
        case "tool_builder_create": return .customToolCreate
        case "tool_builder_update": return .customToolUpdate
        case "tool_builder_enable": return .customToolEnable
        case "tool_builder_disable": return .customToolDisable
        case "tool_builder_delete": return .customToolDelete
        case "tool_repair": return .customToolRepair
        default:
            // Keep descriptors in newly-added groups executable while the
            // request analyzer still supplies the broader effect fallback.
            _ = group
            return nil
        }
    }
}

/// 全部 Agent 工具注册表。集中声明权限与确认要求，供 Runner 校验与 UI 展示。
public enum AgentToolRegistry {
    /// 原生 Function Calling 直接接收数组。固定音乐分析维度
    /// （mood/scene/vocal/texture/style/energy/tempo/acousticness/danceability）保持规范；
    /// 另外支持开放语义标签 semanticTags（dimension='tag'，数量无硬上限）。
    static let recommendationClassificationArraySchema = #"""
    {
      "type": "array",
      "minItems": 1,
      "maxItems": 100,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "id": {"type": "string"},
          "moods": {"type": "array", "items": {"type": "string"}},
          "scenes": {"type": "array", "items": {"type": "string"}},
          "energy": {"type": "integer", "minimum": 1, "maximum": 10},
          "tempo": {"type": "integer", "minimum": 1, "maximum": 5},
          "acousticness": {"type": "integer", "minimum": 1, "maximum": 5},
          "danceability": {"type": "integer", "minimum": 1, "maximum": 5},
          "vocals": {"type": "array", "items": {"type": "string"}},
          "textures": {"type": "array", "items": {"type": "string"}},
          "styles": {"type": "array", "items": {"type": "string"}},
          "semanticTags": {
            "type": "array",
            "items": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "value": {"type": "string"},
                "confidence": {"type": "number", "minimum": 0, "maximum": 1}
              },
              "required": ["value", "confidence"]
            }
          },
          "mode": {"type": "string", "enum": ["full", "semanticTagsOnly"]},
          "confidence": {"type": "number", "minimum": 0, "maximum": 1}
        },
        "required": ["id"]
      }
    }
    """#

    public static let all: [ToolDescriptor] = [
        // MARK: Runtime discovery and generic capabilities
        .init(name: "tool_search", group: .catalog, permission: .readOnly,
              summary: "按名称、描述、标签或命名空间发现可用工具；发现后下一轮即可使用其完整 schema",
              parameters: [
                .init(name: "query", required: true, description: "工具名称、能力或自然语言描述"),
                .init(name: "namespace", required: false, description: "可选命名空间，如 catalog/playback/web"),
                .init(name: "limit", required: false, description: "返回数量，默认 8，最多 50",
                      schemaJSON: #"{"type":"integer","minimum":1,"maximum":50}"#),
              ],
              tags: ["core", "discover", "capability", "schema", "工具发现"],
              aliases: ["tools_list"]),
        .init(name: "capabilities_get", group: .catalog, permission: .readOnly,
              summary: "查询当前 Provider、原生工具、联网与主要 App 能力摘要",
              tags: ["core", "capability", "provider", "web", "能力"]),
        .init(name: "memory_search", group: .memory, permission: .readOnly,
              summary: "按关键词搜索长期记忆，只返回与当前问题相关的记忆",
              parameters: [
                .init(name: "query", required: true, description: "记忆关键词或问题"),
                .init(name: "limit", required: false, description: "返回数量，默认 10",
                      schemaJSON: #"{"type":"integer","minimum":1,"maximum":50}"#),
              ],
              tags: ["memory", "search", "长期记忆"]),
        .init(name: "web_search", group: .server, permission: .readOnly,
              summary: "搜索互联网并返回带标题、URL、域名和摘要的来源",
              parameters: [
                .init(name: "query", required: true, description: "互联网搜索问题"),
                .init(name: "limit", required: false, description: "返回数量，默认 5",
                      schemaJSON: #"{"type":"integer","minimum":1,"maximum":10}"#),
              ],
              evidencePolicy: .externalAPI,
              namespace: "web",
              tags: ["web", "search", "internet", "联网"]),
        .init(name: "web_fetch", group: .server, permission: .readOnly,
              summary: "读取本轮 web_search 已返回的 HTTPS 网页正文摘要；不会把凭据带入请求",
              parameters: [
                .init(name: "url", required: true, description: "本轮 web_search 返回的 HTTPS URL"),
              ],
              evidencePolicy: .externalAPI,
              namespace: "web",
              tags: ["web", "fetch", "internet", "网页"]),
        .init(name: "library_resolve_entity", group: .catalog, permission: .readOnly,
              summary: "按自然语言解析歌曲、专辑、艺术家或歌单，并返回真实 Global ID",
              parameters: [
                .init(name: "query", required: true, description: "歌曲、专辑、艺术家或歌单名称"),
                .init(name: "kind", required: false, description: "song/album/artist/playlist，默认自动"),
                .init(name: "limit", required: false, description: "返回数量，默认 5，最多 20",
                      schemaJSON: #"{"type":"integer","minimum":1,"maximum":20}"#),
              ],
              tags: ["catalog", "resolve", "entity", "ID", "解析"]),
        .init(name: "library_get_songs_batch", group: .catalog, permission: .readOnly,
              summary: "一次读取多首歌曲的真实详情，避免逐首调用 getTrack",
              parameters: [
                .init(name: "trackIDs", required: true, description: "GlobalTrackID JSON 数组",
                      schemaJSON: #"{"type":"array","minItems":1,"maxItems":100,"items":{"type":"string"}}"#),
              ],
              tags: ["catalog", "batch", "songs", "批量"]),

        // MARK: Music download canonical split tools
        .init(name: "music_download_search", group: .download, permission: .readOnly,
              summary: "在 MoviePilot 中搜索音乐下载候选，不提交下载",
              parameters: [
                .init(name: "artist", required: false, description: "艺人名"),
                .init(name: "album", required: false, description: "专辑名"),
                .init(name: "album_aliases", required: false, description: "专辑英文名/别名"),
                .init(name: "keyword", required: false, description: "关键词"),
                .init(name: "year", required: false, description: "年份"),
                .init(name: "limit", required: false, description: "返回数量",
                      schemaJSON: #"{"type":"integer","minimum":1,"maximum":50}"#),
                .init(name: "prefer_lossless", required: false, description: "是否优先无损",
                      schemaJSON: #"{"type":"boolean"}"#),
                .init(name: "min_seeders", required: false, description: "最低做种数",
                      schemaJSON: #"{"type":"integer","minimum":0}"#),
                .init(name: "kind", required: false, description: "single/album/auto"),
              ],
              tags: ["download", "moviepilot", "music", "search"],
              aliases: ["music_download.action=search"]),
        .init(name: "music_download_submit", group: .download, permission: .reversible,
              summary: "提交一个已确认候选的音乐下载任务",
              parameters: [
                .init(name: "ref", required: false, description: "搜索结果引用"),
                .init(name: "site_id", required: false, description: "站点 ID"),
                .init(name: "index", required: false, description: "站点候选序号"),
                .init(name: "magnet", required: false, description: "磁力链接"),
                .init(name: "title", required: false, description: "资源标题"),
                .init(name: "max_size_gb", required: false, description: "搜索结果返回的体积上限",
                      schemaJSON: #"{"type":"number","minimum":0}"#),
                .init(name: "verify_song", required: false, description: "单曲校验歌名"),
                .init(name: "verify_artist", required: false, description: "单曲校验艺人"),
              ],
              tags: ["download", "moviepilot", "submit"]),
        .init(name: "music_download_status", group: .download, permission: .readOnly,
              summary: "查询 MoviePilot 音乐下载插件配置和目录状态",
              tags: ["download", "moviepilot", "status"]),
        .init(name: "music_download_tasks", group: .download, permission: .readOnly,
              summary: "查询当前音乐下载任务",
              parameters: [.init(name: "status", required: false, description: "downloading/completed/failed/paused")],
              tags: ["download", "tasks"]),
        .init(name: "music_download_history", group: .download, permission: .readOnly,
              summary: "查看音乐下载历史",
              tags: ["download", "history"]),
        .init(name: "music_download_history_remove", group: .download, permission: .reversible,
              summary: "移除一条音乐下载历史记录",
              parameters: [.init(name: "hash", required: true, description: "下载任务 hash")],
              tags: ["download", "history", "remove"]),
        .init(name: "music_download_history_clean", group: .download, permission: .reversible,
              summary: "按状态、保留数量或孤儿记录清理下载历史",
              parameters: [
                .init(name: "status", required: false, description: "按状态清理"),
                .init(name: "keep", required: false, description: "只保留最近 N 条",
                      schemaJSON: #"{"type":"integer","minimum":0}"#),
                .init(name: "orphans", required: false, description: "是否清理孤儿记录",
                      schemaJSON: #"{"type":"boolean"}"#),
              ],
              tags: ["download", "history", "clean"]),

        // MARK: Catalog
        .init(name: "searchTracks", group: .catalog, permission: .readOnly, summary: "按关键词搜索单曲",
              parameters: [.init(name: "q", required: true, description: "搜索关键词")]),
        .init(name: "searchAlbums", group: .catalog, permission: .readOnly, summary: "按关键词搜索专辑",
              parameters: [.init(name: "q", required: true, description: "搜索关键词")]),
        .init(name: "searchArtists", group: .catalog, permission: .readOnly, summary: "按关键词搜索艺术家",
              parameters: [.init(name: "q", required: true, description: "搜索关键词")]),
        .init(name: "getTrack", group: .catalog, permission: .readOnly, summary: "获取单曲详情",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "getAlbum", group: .catalog, permission: .readOnly, summary: "获取专辑详情",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "getArtist", group: .catalog, permission: .readOnly, summary: "获取艺术家详情",
              parameters: [.init(name: "artistID", required: true, description: "GlobalArtistID")]),
        .init(name: "getFavorites", group: .catalog, permission: .readOnly, summary: "获取收藏的单曲"),
        .init(name: "getRecentHistory", group: .catalog, permission: .readOnly, summary: "获取最近播放历史",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 50")]),
        .init(name: "getLeastPlayed", group: .catalog, permission: .readOnly, summary: "获取最少播放的单曲",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 50")]),
        .init(name: "getDownloadedTracks", group: .catalog, permission: .readOnly, summary: "获取已下载的单曲"),
        .init(name: "getSimilarTracks", group: .catalog, permission: .readOnly, summary: "获取相似单曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "getCurrentTrack", group: .catalog, permission: .readOnly, summary: "获取当前播放的单曲"),
        .init(name: "getCurrentQueue", group: .catalog, permission: .readOnly, summary: "获取当前播放队列"),

        // MARK: 最终展示协议（确定性 Presentation，模型不能决定 UI）
        .init(name: "result_present_tracks", group: .catalog, permission: .readOnly,
              summary: "明确把一组歌曲作为本次任务的最终展示结果（只传入真正打算展示给用户的最终歌曲，不要传整个候选池）",
              parameters: [
                .init(name: "trackIDs", required: true, description: "最终歌曲的 GlobalTrackID 数组",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
                .init(name: "kind", required: false, description: "final=最终推荐结果（默认）；disambiguation=存在多个匹配需要用户选择",
                      schemaJSON: #"{"type":"string","enum":["final","disambiguation"]}"#),
              ],
              defaultPresentationRole: .finalResult),

        // MARK: Canonical 新式工具（旧别名仍注册，仅供执行兼容；schema 只暴露 canonical）
        .init(name: "library_get_least_played", group: .catalog, permission: .readOnly, summary: "获取最少播放的单曲",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 50")]),
        .init(name: "library_get_downloaded", group: .catalog, permission: .readOnly, summary: "获取已下载的单曲"),
        .init(name: "queue_remove", group: .playback, permission: .reversible, summary: "从队列移除指定位置",
              parameters: [.init(name: "index", required: true, description: "队列索引（从 0）")]),
        .init(name: "playlist_rename", group: .playlist, permission: .reversible, summary: "重命名歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "name", required: true, description: "新名称")]),
        .init(name: "playlist_remove_songs", group: .playlist, permission: .reversible, summary: "从歌单移除曲目",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "indices", required: false, description: "要移除的曲目索引数组（歌单内 0 基索引）",
                                 schemaJSON: #"{"type":"array","items":{"type":"integer","minimum":0}}"#)]),
        .init(name: "playlist_move", group: .playlist, permission: .reversible, summary: "调整歌单内曲目顺序",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "from", required: true, description: "原索引"),
                           .init(name: "to", required: true, description: "目标索引")]),
        .init(name: "playlist_duplicate", group: .playlist, permission: .reversible, summary: "复制歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "playlist_merge", group: .playlist, permission: .reversible, summary: "把多个歌单合并成新歌单",
              parameters: [.init(name: "name", required: true, description: "新歌单名称"),
                           .init(name: "sourceIDs", required: true, description: "源歌单 GlobalPlaylistID 数组",
                                 schemaJSON: #"{"type":"array","items":{"type":"string"}}"#)]),
        .init(name: "playlist_delete", group: .playlist, permission: .destructive,
              confirmationPolicy: .explicitUserApproval(reason: "删除歌单不可逆，且不会自动生成恢复副本"),
              summary: "删除歌单（不可逆，需要用户批准）",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")],
              declaredRisk: .irreversibleDelete),
        .init(name: "rating_set", group: .annotation, permission: .reversible, summary: "设置单曲评分（value 0 表示清除）",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID"),
                           .init(name: "value", required: true, description: "评分 1-5；0 表示清除评分",
                                 schemaJSON: #"{"type":"integer","minimum":0,"maximum":5}"#)]),
        .init(name: "server_switch", group: .server, permission: .reversible, summary: "切换服务器",
              parameters: [.init(name: "serverID", required: true, description: "服务器 ID")]),
        .init(name: "server_remove", group: .server, permission: .reversible, summary: "删除服务器（仅本地清理）",
              parameters: [.init(name: "serverID", required: true, description: "服务器 ID")]),

        // MARK: Playback
        .init(name: "playTrack", group: .playback, permission: .reversible, summary: "播放指定单曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "playAlbum", group: .playback, permission: .reversible, summary: "播放指定专辑",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "playPlaylist", group: .playback, permission: .reversible, summary: "播放指定歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "pause", group: .playback, permission: .reversible, summary: "暂停播放"),
        .init(name: "resume", group: .playback, permission: .reversible, summary: "继续播放"),
        .init(name: "seek", group: .playback, permission: .reversible, summary: "拖动播放进度",
              parameters: [.init(name: "seconds", required: true, description: "目标秒数")]),
        .init(name: "next", group: .playback, permission: .reversible, summary: "下一首"),
        .init(name: "previous", group: .playback, permission: .reversible, summary: "上一首"),
        .init(name: "addToQueue", group: .playback, permission: .reversible, summary: "加入队列末尾",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "playNext", group: .playback, permission: .reversible, summary: "下一首播放",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "replaceQueue", group: .playback, permission: .reversible, summary: "替换整个队列",
              parameters: [.init(name: "trackIDs", required: true, description: "逗号分隔的 GlobalTrackID")]),
        .init(name: "removeFromQueue", group: .playback, permission: .reversible, summary: "从队列移除",
              parameters: [.init(name: "index", required: true, description: "队列索引（从 0）")]),
        .init(name: "reorderQueue", group: .playback, permission: .reversible, summary: "调整队列顺序",
              parameters: [.init(name: "from", required: true, description: "原索引"),
                           .init(name: "to", required: true, description: "目标索引")]),
        .init(name: "clearQueue", group: .playback, permission: .reversible, summary: "清空队列"),

        // MARK: 音乐下载（MoviePilot / MoviePilot）
        .init(name: "music_download", group: .download, permission: .reversible, summary: "从 MoviePilot（MoviePilot）搜索并下载音乐资源",
              parameters: [
                .init(name: "action", required: true, description: "search=搜索候选 | download=提交下载 | tasks=查询下载任务 | history=查看下载历史 | status=查询插件状态 | history_remove=移除单条历史 | history_clean=按条件清理历史"),
                .init(name: "artist", required: false, description: "艺人名（search）"),
                .init(name: "album", required: false, description: "专辑名（search）"),
                .init(name: "album_aliases", required: false, description: "专辑英文/别名，逗号分隔；中文专辑务必提供（search）"),
                .init(name: "keyword", required: false, description: "搜索关键词（search）"),
                .init(name: "year", required: false, description: "年份（search）"),
                .init(name: "limit", required: false, description: "返回条数，默认 10（search）"),
                .init(name: "prefer_lossless", required: false, description: "优先无损 true/false（search）"),
                .init(name: "min_seeders", required: false, description: "最低做种数（search）"),
                .init(name: "kind", required: false, description: "single=单曲 | album=专辑合集 | auto=自动（search，v0.5.x）"),
                .init(name: "ref", required: false, description: "搜索结果条目引用（hash:id，download 推荐）"),
                .init(name: "site_id", required: false, description: "站点 ID（download，配合 index）"),
                .init(name: "index", required: false, description: "候选序号（download，配合 site_id）"),
                .init(name: "magnet", required: false, description: "磁力链接（download）"),
                .init(name: "title", required: false, description: "资源标题（download/magnet）"),
                .init(name: "max_size_gb", required: false, description: "体积上限 GB：把 search 返回的 size_limit_gb 原样传回（download，v0.5.x）"),
                .init(name: "verify_song", required: false, description: "目标歌曲名：单曲自动下载必传，插件会校验种子确实包含该曲（download）"),
                .init(name: "verify_artist", required: false, description: "目标艺人名：单曲自动下载配合 verify_song 使用（download）"),
                .init(name: "status", required: false, description: "任务状态过滤（tasks）；清理目标状态 downloading/completed/failed/paused（history_clean）"),
                .init(name: "hash", required: false, description: "目标下载 hash（history_remove，必传）"),
                .init(name: "keep", required: false, description: "只保留最近 N 条记录（history_clean）"),
                .init(name: "orphans", required: false, description: "是否清理下载器已不存在的孤儿记录 true/false（history_clean）"),
              ]),

        // MARK: Playlist
        .init(name: "listPlaylists", group: .playlist, permission: .readOnly, summary: "列出歌单"),
        .init(name: "getPlaylist", group: .playlist, permission: .readOnly, summary: "获取歌单详情",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "createPlaylist", group: .playlist, permission: .reversible, summary: "新建歌单",
              parameters: [.init(name: "name", required: true, description: "歌单名称")]),
        .init(name: "renamePlaylist", group: .playlist, permission: .reversible, summary: "重命名歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "name", required: true, description: "新名称")]),
        .init(name: "addTracksToPlaylist", group: .playlist, permission: .reversible, summary: "向歌单添加曲目",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "trackIDs", required: true, description: "逗号分隔的 GlobalTrackID")]),
        .init(name: "removeTracksFromPlaylist", group: .playlist, permission: .reversible, summary: "从歌单移除曲目",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "indices", required: true, description: "逗号分隔的位置索引")]),
        .init(name: "reorderPlaylist", group: .playlist, permission: .reversible, summary: "调整歌单内顺序",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                           .init(name: "from", required: true, description: "原索引"),
                           .init(name: "to", required: true, description: "目标索引")]),
        .init(name: "duplicatePlaylist", group: .playlist, permission: .reversible, summary: "复制歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "mergePlaylists", group: .playlist, permission: .reversible, summary: "合并歌单",
              parameters: [.init(name: "sourceIDs", required: true, description: "逗号分隔的 GlobalPlaylistID"),
                           .init(name: "name", required: true, description: "新歌单名称")]),
        .init(name: "deletePlaylist", group: .playlist, permission: .destructive,
              confirmationPolicy: .explicitUserApproval(reason: "删除歌单不可逆，且不会自动生成恢复副本"),
              summary: "删除歌单（不可逆，需要用户批准）",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")],
              declaredRisk: .irreversibleDelete),

        // MARK: Annotation
        .init(name: "likeTrack", group: .annotation, permission: .reversible, summary: "收藏单曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "unlikeTrack", group: .annotation, permission: .reversible, summary: "取消收藏单曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "favoriteAlbum", group: .annotation, permission: .reversible, summary: "收藏专辑",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "unfavoriteAlbum", group: .annotation, permission: .reversible, summary: "取消收藏专辑",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "favoriteArtist", group: .annotation, permission: .reversible, summary: "收藏艺术家",
              parameters: [.init(name: "artistID", required: true, description: "GlobalArtistID")]),
        .init(name: "unfavoriteArtist", group: .annotation, permission: .reversible, summary: "取消收藏艺术家",
              parameters: [.init(name: "artistID", required: true, description: "GlobalArtistID")]),
        .init(name: "setRating", group: .annotation, permission: .reversible, summary: "设置评分",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID"),
                           .init(name: "rating", required: true, description: "1-5 整数")]),
        .init(name: "clearRating", group: .annotation, permission: .reversible, summary: "清除评分",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),

        // MARK: Server
        .init(name: "listServers", group: .server, permission: .readOnly, summary: "列出已连接服务器"),
        .init(name: "getActiveServer", group: .server, permission: .readOnly, summary: "获取当前服务器"),
        .init(name: "testServerConnection", group: .server, permission: .readOnly, summary: "测试服务器连接",
              parameters: [.init(name: "serverID", required: true, description: "ServerID")]),
        .init(name: "addServer", group: .server, permission: .reversible, summary: "添加服务器（打开原生表单录入凭据）",
              parameters: [.init(name: "displayName", required: true, description: "显示名称"),
                           .init(name: "baseURL", required: true, description: "服务器地址")]),
        .init(name: "updateServer", group: .server, permission: .reversible, summary: "更新服务器",
              parameters: [.init(name: "serverID", required: true, description: "ServerID")]),
        .init(name: "switchServer", group: .server, permission: .reversible, summary: "切换服务器",
              parameters: [.init(name: "serverID", required: true, description: "ServerID")]),
        .init(name: "refreshLibrary", group: .server, permission: .reversible, summary: "刷新本地目录"),
        .init(name: "getSyncStatus", group: .server, permission: .readOnly, summary: "获取同步状态"),
        .init(name: "removeServer", group: .server, permission: .reversible, summary: "删除服务器（仅本地清理）",
              parameters: [.init(name: "serverID", required: true, description: "ServerID")]),

        // MARK: 第一阶段统一命名工具（v2 工具集）

        // App / 设备状态
        .init(name: "app_get_context", group: .catalog, permission: .readOnly, summary: "获取 App 上下文（页面/服务器/当前歌曲/播放状态/网络）", tags: ["core", "context", "app"]),
        .init(name: "app_open_page", group: .catalog, permission: .readOnly, summary: "打开指定页面",
              parameters: [.init(name: "page", required: true, description: "首页/音乐库/搜索/AI助手/设置/当前播放/歌词/播放队列/下载管理/服务器管理")]),
        .init(name: "app_get_feature_status", group: .catalog, permission: .readOnly, summary: "查询后台播放/Siri/快捷指令/本地网络等能力状态"),
        .init(name: "device_get_network_status", group: .catalog, permission: .readOnly, summary: "获取网络类型与服务器可达性"),
        .init(name: "device_get_audio_route", group: .catalog, permission: .readOnly, summary: "获取当前音频输出设备"),
        .init(name: "device_get_storage_status", group: .catalog, permission: .readOnly, summary: "获取存储占用与剩余空间"),

        // 服务器
        .init(name: "server_list", group: .server, permission: .readOnly, summary: "列出已配置的服务器"),
        .init(name: "server_get_current", group: .server, permission: .readOnly, summary: "获取当前服务器信息（不含凭据）"),
        .init(name: "server_test_connection", group: .server, permission: .readOnly, summary: "对指定服务器执行真实连通性测试",
              parameters: [.init(name: "serverID", required: true, description: "要测试的服务器 ID")]),
        .init(name: "server_get_capabilities", group: .server, permission: .readOnly, summary: "获取当前服务器支持的 OpenSubsonic 能力"),
        .init(name: "server_sync_status", group: .server, permission: .readOnly, summary: "查看资料库同步状态与上次同步时间"),
        .init(name: "server_sync_start", group: .server, permission: .reversible, summary: "触发一次音乐库增量同步（后台执行，本地未找到歌曲时可先同步）"),
        .init(name: "server_search", group: .server, permission: .readOnly, summary: "在服务器上在线搜索歌曲（HTTP，本地无结果时使用）",
              parameters: [
                .init(name: "query", required: true, description: "搜索关键词"),
                .init(name: "limit", required: false, description: "返回数量，默认 20"),
              ]),

        // 本地库
        .init(name: "library_get_summary", group: .catalog, permission: .readOnly, summary: "获取本地资料库统计摘要"),
        .init(name: "library_search", group: .catalog, permission: .readOnly, summary: "统一搜索歌曲/专辑/艺术家/歌单/流派/歌词",
              parameters: [
                .init(name: "query", required: true, description: "搜索关键词"),
                .init(name: "kind", required: false, description: "song/album/artist/playlist/genre/lyrics，默认全部"),
                .init(name: "limit", required: false, description: "返回数量，默认 30，最多 100"),
                .init(name: "onlyFavorites", required: false, description: "只搜收藏（true/false）"),
                .init(name: "onlyOffline", required: false, description: "只搜离线（true/false）"),
              ]),
        .init(name: "library_get_catalog_index", group: .catalog, permission: .readOnly, summary: "查看曲库分类索引（歌手/专辑/流派/语言/年代/总览），了解曲库里有什么，推荐前先用它",
              parameters: [.init(name: "category", required: false, description: "artists/albums/genres/languages/years/overview，默认 overview")],
              maxResultCharacters: ContextManager.maxIndexCharacters),
        .init(name: "library_get_catalog_tracks", group: .catalog, permission: .readOnly, summary: "按分类取歌曲清单（artist/album/genre/language/year/favorites/recent/popular/all），只含元数据，供推荐筛选",
              parameters: [
                .init(name: "category", required: true, description: "artist/album/genre/language/year/favorites/recent/popular/all"),
                .init(name: "value", required: false, description: "分类值（如 周杰伦 / 中文 / 摇滚 / 2020）"),
                .init(name: "limit", required: false, description: "返回数量，默认 100，最多 500"),
              ], maxResultCharacters: ContextManager.maxIndexCharacters),
        .init(name: "library_index_status", group: .catalog, permission: .readOnly, summary: "查看推荐索引的总数、已完成和待分类数量",
              maxResultCharacters: 24_000, tags: ["recommendation-index", "index", "status", "read"], aliases: [RecommendationIndexCompatibility.legacyStatusTool]),
        .init(name: "library_index_read", group: .catalog, permission: .readOnly, summary: "读取已完成的推荐索引条目及分类标签，可按维度和标签筛选",
              parameters: [
                .init(name: "dimension", required: false, description: "mood/scene/vocal/texture/style/energy/tempo/acousticness/danceability/tag"),
                .init(name: "value", required: false, description: "要匹配的标签值，如 通勤、深夜、平静"),
                .init(name: "limit", required: false, description: "返回 1-100 条，默认 50"),
              ], maxResultCharacters: 24_000, tags: ["recommendation-index", "index", "read", "catalog"], aliases: [RecommendationIndexCompatibility.legacyReadTool]),
        .init(name: "recommendation_index_commit", group: .catalog, permission: .reversible,
              summary: "由 Recommendation Index Runtime 提交已验证的当前批次分类；模型不可见",
              parameters: [
                .init(name: "batchID", required: true, description: "Runtime 当前批次 ID"),
                .init(name: "revision", required: true, description: "Runtime 当前批次修订号",
                      schemaJSON: #"{"type":"integer","minimum":1}"#),
                .init(name: "items", required: true, description: "Runtime 已验证的分类数组",
                      schemaJSON: Self.recommendationClassificationArraySchema),
              ],
              maxResultCharacters: 24_000,
              visibility: .internalOnly, requiredSkillID: "recommendation-index"),
        .init(name: "library_select_tracks", group: .catalog, permission: .readOnly, summary: "集合查询：一次筛选语言/流派/艺术家/年代，按本地热度代理排序，返回候选歌曲清单（多首任务优先用这个，不要逐个歌手搜索）",
              parameters: [
                .init(name: "languages", required: false, description: "语言数组，如 [\"中文\",\"粤语\"]",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
                .init(name: "genres", required: false, description: "流派数组",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
                .init(name: "artists", required: false, description: "艺术家数组",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
                .init(name: "yearFrom", required: false, description: "起始年份"),
                .init(name: "yearTo", required: false, description: "结束年份"),
                .init(name: "favoritesOnly", required: false, description: "true=只要收藏"),
                .init(name: "excludeRecentlyPlayed", required: false, description: "true=排除最近播放"),
                .init(name: "recentDays", required: false, description: "排除最近 N 天，默认 7"),
                .init(name: "excludeTrackIDs", required: false, description: "要排除的 GlobalID 数组",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
                .init(name: "playableOnly", required: false, description: "deprecated：不再按瞬时 streamURL 过滤；Auralis 播放时会向服务器刷新/在线流播（默认 false）"),
                .init(name: "sort", required: false, description: "popularityProxy/favorites/recentlyPlayed/title/random，默认 popularityProxy（recentlyAdded 由 library_get_recently_added 提供）"),
                .init(name: "limit", required: false, description: "返回数量，默认 50，最多 100"),
              ]),
        .init(name: "library_get_song", group: .catalog, permission: .readOnly, summary: "获取单曲详情（含格式/码率/收藏/评分/离线状态）",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "music_appreciate", group: .catalog, permission: .readOnly, summary: "为正在播放或指定歌曲准备分层鉴赏证据：已核验元数据、私人播放数据与可用的外部大众评价；没有 Community Evidence 时明确标记不可用",
              parameters: [.init(name: "trackID", required: false, description: "可选 GlobalTrackID；省略时鉴赏当前正在播放的歌曲")]),
        .init(name: "library_get_album", group: .catalog, permission: .readOnly, summary: "获取专辑详情",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "library_get_artist", group: .catalog, permission: .readOnly, summary: "获取艺术家详情",
              parameters: [.init(name: "artistID", required: true, description: "GlobalArtistID")]),
        .init(name: "library_get_artists", group: .catalog, permission: .readOnly, summary: "列出本地资料库中的艺术家",
              parameters: [.init(name: "limit", required: false, description: "最多返回多少位艺术家，默认 100，最大 500")],
              tags: ["catalog", "artists", "list", "read"]),
        .init(name: "library_get_albums", group: .catalog, permission: .readOnly, summary: "列出本地资料库中的专辑",
              parameters: [.init(name: "limit", required: false, description: "最多返回多少张专辑，默认 100，最大 500")],
              tags: ["catalog", "albums", "list", "read"]),
        .init(name: "library_get_playlist", group: .catalog, permission: .readOnly, summary: "获取歌单详情",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "playlist_list", group: .playlist, permission: .readOnly, summary: "列出当前音乐服务器的歌单（只读）",
              parameters: [.init(name: "limit", required: false, description: "最多返回多少个歌单，默认 100，最大 100")],
              tags: ["playlist", "list", "query", "read", "catalog"], aliases: ["listPlaylists"]),
        .init(name: "library_get_recently_added", group: .catalog, permission: .readOnly, summary: "获取最近添加的歌曲",
              parameters: [
                .init(name: "days", required: false, description: "最近 N 天，默认 30"),
                .init(name: "limit", required: false, description: "返回数量，默认 20"),
              ]),
        .init(name: "library_get_most_played", group: .catalog, permission: .readOnly, summary: "获取最常播放的歌曲",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 20")]),
        .init(name: "library_get_recently_played", group: .catalog, permission: .readOnly, summary: "获取最近播放",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 20")]),
        .init(name: "library_get_starred", group: .catalog, permission: .readOnly, summary: "获取收藏的歌曲"),
        .init(name: "library_get_random_songs", group: .catalog, permission: .readOnly, summary: "获取随机歌曲",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 10")]),
        .init(name: "library_get_similar_songs", group: .catalog, permission: .readOnly, summary: "获取相似歌曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "library_get_genres", group: .catalog, permission: .readOnly, summary: "获取全部流派及其歌曲数量（按歌曲数降序）",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 30")]),
        .init(name: "library_get_tracks_by_genre", group: .catalog, permission: .readOnly, summary: "获取某流派下的歌曲（按流派浏览）",
              parameters: [
                .init(name: "genre", required: true, description: "流派名（大小写不敏感，如 爵士/Jazz）"),
                .init(name: "limit", required: false, description: "返回数量，默认 20"),
              ]),

        // 播放
        .init(name: "playback_get_state", group: .playback, permission: .readOnly, summary: "获取播放器状态"),
        .init(name: "playback_play_song", group: .playback, permission: .reversible, summary: "播放指定歌曲",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "playback_play_album", group: .playback, permission: .reversible, summary: "播放指定专辑",
              parameters: [.init(name: "albumID", required: true, description: "GlobalAlbumID")]),
        .init(name: "playback_play_artist", group: .playback, permission: .reversible, summary: "播放指定艺术家的歌曲",
              parameters: [
                .init(name: "artistID", required: true, description: "GlobalArtistID"),
                .init(name: "scope", required: false, description: "top/全部/random/专辑名"),
              ]),
        .init(name: "playback_play_playlist", group: .playback, permission: .reversible, summary: "播放指定歌单",
              parameters: [.init(name: "playlistID", required: true, description: "GlobalPlaylistID")]),
        .init(name: "playback_play_random", group: .playback, permission: .reversible, summary: "随机播放资料库歌曲",
              parameters: [.init(name: "limit", required: false, description: "队列数量，默认 30")]),
        .init(name: "playback_pause", group: .playback, permission: .reversible, summary: "暂停播放"),
        .init(name: "playback_resume", group: .playback, permission: .reversible, summary: "继续播放"),
        .init(name: "playback_next", group: .playback, permission: .reversible, summary: "下一首"),
        .init(name: "playback_previous", group: .playback, permission: .reversible, summary: "上一首"),
        .init(name: "playback_seek", group: .playback, permission: .reversible, summary: "跳到指定秒数",
              parameters: [.init(name: "seconds", required: true, description: "目标秒数")]),
        .init(name: "playback_set_shuffle", group: .playback, permission: .reversible, summary: "设置随机播放",
              parameters: [.init(name: "enabled", required: true, description: "true/false")]),
        .init(name: "playback_set_repeat", group: .playback, permission: .reversible, summary: "设置循环模式（off/all/one）",
              parameters: [.init(name: "mode", required: true, description: "off/all/one")]),
        .init(name: "playback_set_speed", group: .playback, permission: .reversible, summary: "设置播放速度（0.5x–2.0x）",
              parameters: [.init(name: "rate", required: true, description: "播放速度，如 1.0 / 1.25 / 1.5")]),
        .init(name: "playback_set_sleep_timer", group: .playback, permission: .reversible, summary: "设置睡眠定时（off/afterMinutes/afterCurrentTrack/afterCurrentAlbum/afterCurrentQueue）",
              parameters: [
                .init(name: "mode", required: true, description: "off/afterMinutes/afterCurrentTrack/afterCurrentAlbum/afterCurrentQueue"),
                .init(name: "minutes", required: false, description: "afterMinutes 时分钟数，默认 30"),
              ]),
        .init(name: "playback_cancel_sleep_timer", group: .playback, permission: .reversible, summary: "取消睡眠定时"),
        .init(name: "playback_get_sleep_timer", group: .playback, permission: .readOnly, summary: "查询睡眠定时状态"),

        // 队列
        .init(name: "queue_get", group: .playback, permission: .readOnly, summary: "获取当前播放队列"),
        .init(name: "queue_append", group: .playback, permission: .reversible, summary: "把歌曲追加到队列末尾",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "queue_append_many", group: .playback, permission: .reversible, summary: "一次把多首歌曲追加到队列末尾",
              parameters: [.init(name: "trackIDs", required: true, description: "GlobalTrackID JSON 数组",
                                 schemaJSON: #"{"type":"array","minItems":1,"maxItems":100,"items":{"type":"string"}}"#)],
              tags: ["queue", "batch", "append", "批量"]),
        .init(name: "queue_play_next", group: .playback, permission: .reversible, summary: "把歌曲插入到当前歌曲之后播放",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")],
              aliases: ["playNext", "下一首播放", "接下来播放", "插到下一首"]),
        .init(name: "queue_play_next_many", group: .playback, permission: .reversible, summary: "一次把多首歌曲按顺序插入到当前歌曲之后播放",
              parameters: [.init(name: "trackIDs", required: true, description: "GlobalTrackID JSON 数组",
                                 schemaJSON: #"{"type":"array","minItems":1,"maxItems":100,"items":{"type":"string"}}"#)],
              tags: ["queue", "batch", "play_next", "批量"],
              aliases: ["playNextMany", "下一首播放多首", "接下来播放多首"]),
        .init(name: "queue_replace", group: .playback, permission: .reversible, summary: "替换整个播放队列",
              parameters: [.init(name: "trackIDs", required: true, description: "GlobalTrackID 数组",
                                 schemaJSON: #"{"type":"array","items":{"type":"string"}}"#)]),
        .init(name: "queue_clear", group: .playback, permission: .reversible, summary: "清空播放队列"),
        .init(name: "queue_shuffle_remaining", group: .playback, permission: .reversible, summary: "只随机尚未播放的剩余队列"),
        .init(name: "queue_move", group: .playback, permission: .reversible, summary: "调整队列中歌曲顺序",
              parameters: [
                .init(name: "from", required: true, description: "原索引"),
                .init(name: "to", required: true, description: "目标索引"),
              ]),
        .init(name: "queue_save_as_playlist", group: .playlist, permission: .reversible, summary: "把当前队列保存为歌单",
              parameters: [.init(name: "name", required: true, description: "歌单名称")]),

        // 收藏 / 歌单 / 歌词 / 下载 / 缓存 / 统计 / 诊断
        .init(name: "favorite_set", group: .annotation, permission: .reversible, summary: "设置收藏（歌曲/专辑/艺术家）",
              parameters: [
                .init(name: "targetType", required: true, description: "song/album/artist"),
                .init(name: "targetID", required: true, description: "GlobalID"),
                .init(name: "value", required: true, description: "true=收藏 / false=取消收藏"),
              ]),
        .init(name: "playlist_create", group: .playlist, permission: .reversible, summary: "新建歌单",
              parameters: [.init(name: "name", required: true, description: "歌单名称")]),
        .init(name: "playlist_add_songs", group: .playlist, permission: .reversible, summary: "把歌曲加入歌单",
              parameters: [
                .init(name: "playlistID", required: true, description: "GlobalPlaylistID"),
                .init(name: "trackIDs", required: true, description: "GlobalTrackID 数组",
                      schemaJSON: #"{"type":"array","items":{"type":"string"}}"#),
              ]),
        .init(name: "preference_set_disliked", group: .annotation, permission: .reversible, summary: "设置/取消“不喜欢”：不喜欢的歌曲不会再出现在任何自动推荐、随机播放、相似歌曲、智能队列或发现模块中；显式搜索、打开专辑/歌单或直接点播仍然允许播放",
              parameters: [
                .init(name: "trackID", required: true, description: "GlobalTrackID"),
                .init(name: "value", required: true, description: "true=标记不喜欢 / false=取消不喜欢"),
              ]),
        .init(name: "library_get_disliked", group: .catalog, permission: .readOnly, summary: "读取已标记“不喜欢”的歌曲（含标题/艺术家/专辑）",
              parameters: [
                .init(name: "limit", required: false, description: "返回数量，默认 50，最大 200"),
              ]),
        .init(name: "music_get_public_evidence", group: .catalog, permission: .readOnly, summary: "获取当前/指定歌曲的真实公开音乐资料证据（MusicBrainz 身份与评分、CritiqueBrainz 聚合与少量评论摘要、ListenBrainz 收听统计）；没有真实数据时不得编造大众评价",
              parameters: [
                .init(name: "trackID", required: false, description: "GlobalTrackID；省略时使用当前播放歌曲"),
                .init(name: "refresh", required: false, description: "true=忽略缓存强制刷新，默认 false"),
              ]),
        .init(name: "lyrics_get", group: .catalog, permission: .readOnly, summary: "获取歌词状态与正文（仅在隐私设置允许时回传正文）",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "media_download_offline", group: .catalog, permission: .reversible, summary: "下载歌曲到本地离线缓存",
              parameters: [.init(name: "trackID", required: true, description: "GlobalTrackID")]),
        .init(name: "cache_get_status", group: .catalog, permission: .readOnly, summary: "获取缓存容量（封面/歌词/离线音频）"),
        .init(name: "recommend_by_mood", group: .catalog, permission: .readOnly, summary: "按情绪推荐歌曲（深夜/放松/通勤/学习/运动/伤感/治愈/怀旧/安静/高能量）",
              parameters: [
                .init(name: "mood", required: true, description: "情绪：深夜/放松/通勤/学习/运动/伤感/治愈/怀旧/安静/高能量"),
                .init(name: "limit", required: false, description: "返回数量，默认 10"),
              ]),
        .init(name: "recommend_by_constraints", group: .catalog, permission: .readOnly, summary: "组合约束推荐（中文/收藏/排除最近/年代/流派/时长/无损/离线/排除艺术家）",
              parameters: [
                .init(name: "languages", required: false, description: "逗号分隔语言，如 中文"),
                .init(name: "genres", required: false, description: "逗号分隔流派"),
                .init(name: "yearFrom", required: false, description: "起始年份"),
                .init(name: "yearTo", required: false, description: "结束年份"),
                .init(name: "favoritesOnly", required: false, description: "true=只从收藏选择"),
                .init(name: "excludeRecentlyPlayed", required: false, description: "true=排除最近播放"),
                .init(name: "onlyOffline", required: false, description: "true=只要离线歌曲"),
                .init(name: "excludeArtist", required: false, description: "排除的艺术家名"),
                .init(name: "maxTotalMinutes", required: false, description: "限定总时长（分钟）"),
                .init(name: "losslessOnly", required: false, description: "true=只要无损（FLAC/ALAC/WAV/AIFF）"),
                .init(name: "limit", required: false, description: "返回数量，默认 20"),
              ]),
        .init(name: "smart_queue_generate", group: .catalog, permission: .readOnly, summary: "生成智能队列预览（不替换队列；确认后请用 queue_replace）",
              parameters: [.init(name: "limit", required: false, description: "数量，默认 20")]),
        .init(name: "diagnostics_export_report", group: .catalog, permission: .readOnly, summary: "导出脱敏诊断报告"),
        .init(name: "diagnostics_now_playing", group: .catalog, permission: .readOnly, summary: "对比控制中心/锁屏与 App 内播放状态"),
        .init(name: "ios_siri_get_status", group: .catalog, permission: .readOnly, summary: "查询 Siri 集成状态"),
        .init(name: "ios_shortcuts_list", group: .catalog, permission: .readOnly, summary: "列出快捷指令 App 中可用的操作"),
        .init(name: "library_find_duplicates", group: .catalog, permission: .readOnly, summary: "查找疑似重复歌曲（只报告，不删除）",
              parameters: [.init(name: "limit", required: false, description: "最多报告组数，默认 10")]),
        .init(name: "library_find_metadata_issues", group: .catalog, permission: .readOnly, summary: "查找元数据问题（缺艺术家/专辑/年份/流派/封面/异常时长）",
              parameters: [.init(name: "limit", required: false, description: "最多报告条数，默认 10")]),
        .init(name: "library_find_broken_artwork", group: .catalog, permission: .readOnly, summary: "查找封面标识存在但本地磁盘缓存缺失的歌曲",
              parameters: [.init(name: "limit", required: false, description: "最多报告条数，默认 10")]),
        .init(name: "library_find_stale_cache", group: .catalog, permission: .readOnly, summary: "查找本地音频缓存中已不存在的曲目（陈旧缓存）",
              parameters: [.init(name: "limit", required: false, description: "最多报告条数，默认 10")]),
        .init(name: "library_find_unplayable", group: .catalog, permission: .readOnly, summary: "查找无播放地址且未离线的歌曲",
              parameters: [.init(name: "limit", required: false, description: "最多报告条数，默认 10")]),
        .init(name: "stats_get_top_items", group: .catalog, permission: .readOnly, summary: "获取最常听的艺术家/专辑/歌曲",
              parameters: [
                .init(name: "kind", required: true, description: "artist/album/track"),
                .init(name: "limit", required: false, description: "返回数量，默认 10"),
              ]),
        .init(name: "stats_get_format_distribution", group: .catalog, permission: .readOnly, summary: "获取音频格式分布"),
        .init(name: "stats_get_storage_distribution", group: .catalog, permission: .readOnly, summary: "获取存储/缓存分布"),
        .init(name: "stats_get_listening_summary", group: .catalog, permission: .readOnly, summary: "获取收听统计摘要"),
        .init(name: "diagnostics_playback", group: .catalog, permission: .readOnly, summary: "诊断播放器状态（缓冲/来源/错误/音频会话/队列）"),
        .init(name: "diagnostics_get_recent_errors", group: .catalog, permission: .readOnly, summary: "获取最近脱敏错误记录",
              parameters: [.init(name: "limit", required: false, description: "返回数量，默认 20")]),

        // MARK: Declarative Custom Tool builder / doctor
        .init(name: "tool_builder_list", group: .memory, permission: .readOnly,
              summary: "列出已保存的声明式自建工具及版本状态",
              namespace: "tool_builder", tags: ["core", "custom", "tool_builder", "list"]),
        .init(name: "tool_builder_inspect", group: .memory, permission: .readOnly,
              summary: "查看自建工具的 manifest、schema 和当前版本",
              parameters: [.init(name: "tool", required: true, description: "自建工具名称或 UUID")],
              namespace: "tool_builder", tags: ["custom", "tool_builder", "inspect"]),
        .init(name: "tool_builder_create", group: .memory, permission: .reversible,
              summary: "创建一个声明式自建工具；只能组合已有 canonical 工具或安全网页读取",
              parameters: [.init(name: "manifest", required: true, description: "CustomToolManifest JSON object", schemaJSON: #"{"type":"object","additionalProperties":true}"#)],
              namespace: "tool_builder", tags: ["custom", "tool_builder", "create"]),
        .init(name: "tool_builder_update", group: .memory, permission: .reversible,
              summary: "更新自建工具并生成新版本；旧版本保留用于回滚",
              parameters: [.init(name: "manifest", required: true, description: "CustomToolManifest JSON object", schemaJSON: #"{"type":"object","additionalProperties":true}"#)],
              namespace: "tool_builder", tags: ["custom", "tool_builder", "update"]),
        .init(name: "tool_builder_validate", group: .memory, permission: .readOnly,
              summary: "校验自建工具 schema、子工具、绑定和派生权限",
              parameters: [.init(name: "manifest", required: false, description: "待校验 manifest；省略时检查已保存工具", schemaJSON: #"{"type":"object","additionalProperties":true}"#), .init(name: "tool", required: false, description: "已保存工具名称")],
              namespace: "tool_builder", tags: ["custom", "tool_builder", "validate"]),
        .init(name: "tool_builder_test", group: .memory, permission: .readOnly,
              summary: "对自建工具做不产生副作用的 dry-run，报告派生风险、scope 和步骤",
              parameters: [.init(name: "tool", required: true, description: "自建工具名称")],
              namespace: "tool_builder", tags: ["custom", "tool_builder", "dry-run"]),
        .init(name: "tool_builder_enable", group: .memory, permission: .reversible,
              summary: "启用一个已保存的自建工具",
              parameters: [.init(name: "tool", required: true, description: "自建工具名称")],
              namespace: "tool_builder", tags: ["custom", "tool_builder", "enable"]),
        .init(name: "tool_builder_disable", group: .memory, permission: .reversible,
              summary: "停用一个已保存的自建工具",
              parameters: [.init(name: "tool", required: true, description: "自建工具名称")],
              namespace: "tool_builder", tags: ["custom", "tool_builder", "disable"]),
        .init(name: "tool_builder_delete", group: .memory, permission: .destructive,
              confirmationPolicy: .explicitUserApproval(reason: "删除自建工具不可逆，且不会自动生成恢复副本"),
              summary: "删除一个已保存的自建工具（不可逆，需要 UI 批准）",
              parameters: [.init(name: "tool", required: true, description: "自建工具名称")],
              namespace: "tool_builder", tags: ["custom", "tool_builder", "delete"],
              declaredRisk: .irreversibleDelete),
        .init(name: "tool_diagnose", group: .catalog, permission: .readOnly,
              summary: "诊断工具定义、参数 schema、执行器和最近一次结构化失败",
              parameters: [.init(name: "toolName", required: true, description: "canonical 工具名")],
              namespace: "tool_builder", tags: ["custom", "diagnostics", "tool_doctor"]),
        .init(name: "tool_repair", group: .memory, permission: .reversible,
              summary: "应用经过版本校验的自建工具修复 proposal；不能修改内建 Swift 工具",
              parameters: [.init(name: "proposal", required: true, description: "ToolRepairProposal JSON object", schemaJSON: #"{"type":"object","additionalProperties":true}"#)],
              namespace: "tool_builder", tags: ["custom", "tool_repair"]),

        // MARK: 记忆与技能
        .init(name: "memory_save", group: .memory, permission: .reversible, summary: "记住关于主人的一条信息（跨会话有效）",
              parameters: [
                .init(name: "key", required: true, description: "字段名，如 名字 / 喜欢的歌手 / 生日"),
                .init(name: "value", required: true, description: "要记住的内容"),
              ]),
        .init(name: "memory_list", group: .memory, permission: .readOnly, summary: "查看已记住的关于主人的信息"),
        .init(name: "memory_delete", group: .memory, permission: .destructive,
              confirmationPolicy: .explicitUserApproval(reason: "删除记忆不可逆，且不会自动生成恢复副本"),
              summary: "删除一条记忆（不可逆，需要用户批准）",
              parameters: [.init(name: "key", required: true, description: "要删除的记忆字段名")],
              declaredRisk: .irreversibleDelete),
        .init(name: "memory_clear", group: .memory, permission: .destructive,
              confirmationPolicy: .explicitUserApproval(reason: "清空全部记忆不可逆，且不会自动生成恢复副本"),
              summary: "清空全部记忆（不可逆，需要用户批准）", declaredRisk: .irreversibleDelete),
        .init(name: "skill_create", group: .memory, permission: .reversible, summary: "创建一段可复用指令（skill 文件），之后可读取使用",
              parameters: [
                .init(name: "name", required: true, description: "技能名，简短英文或中文"),
                .init(name: "instructions", required: true, description: "完整技能指令"),
              ]),
        .init(name: "skill_list", group: .memory, permission: .readOnly, summary: "查看已创建的技能列表"),
        .init(name: "skill_read", group: .memory, permission: .readOnly, summary: "读取某个技能的完整指令",
              parameters: [.init(name: "name", required: true, description: "技能名")]),
        .init(name: "skill_delete", group: .memory, permission: .destructive,
              confirmationPolicy: .explicitUserApproval(reason: "删除技能不可逆，且不会自动生成恢复副本"),
              summary: "删除一个技能（不可逆，需要用户批准）",
              parameters: [.init(name: "name", required: true, description: "技能名")],
              declaredRisk: .irreversibleDelete),

    ]

    /// Canonical definition view. Metadata and executable behavior are now
    /// published together. Existing built-in implementations are wrapped by
    /// an explicit compatibility executor while domain executors migrate out
    /// of `AgentToolkit`; new tools must provide a closure here rather than a
    /// second selector or executor registry.
    public static let definitions: [ToolDefinition] = all.map { descriptor in
        let executorKind: ToolExecutorKind
        if descriptor.requiredSkillID != nil || descriptor.name == "recommendation_index_commit" {
            executorKind = .recommendationSkill
        } else if descriptor.name == "tool_search" || descriptor.name == "capabilities_get" {
            executorKind = .catalog
        } else if descriptor.name == "web_search" || descriptor.name == "web_fetch" {
            executorKind = .web
        } else if SystemToolNames.contains(descriptor.name) {
            executorKind = .systemService
        } else if descriptor.visibility == .legacyOnly {
            executorKind = .legacyCompatibility
        } else {
            executorKind = .agentBridge
        }
        return ToolDefinition(descriptor: descriptor, executorKind: executorKind) { context, call in
            await Self.executeLegacy(call, descriptor: descriptor, context: context)
        }
    }

    /// Resolve a canonical alias before a legacy descriptor with the same
    /// exact name. This makes compatibility names such as `listPlaylists`
    /// execute through the canonical `playlist_list` metadata and executor.
    private static func canonicalAliasDescriptor(
        for name: String,
        in descriptors: [ToolDescriptor]
    ) -> ToolDescriptor? {
        descriptors.first {
            $0.visibility != .legacyOnly && $0.aliases.contains(name)
        }
    }

    public static func descriptor(for name: String) -> ToolDescriptor? {
        canonicalAliasDescriptor(for: name, in: all)
            ?? all.first { $0.name == name }
            ?? all.first { $0.aliases.contains(name) }
    }

    public static func definition(for name: String) -> ToolDefinition? {
        definitions.first {
            $0.descriptor.visibility != .legacyOnly
                && $0.descriptor.aliases.contains(name)
        }
        ?? definitions.first { $0.descriptor.name == name }
        ?? definitions.first { $0.descriptor.aliases.contains(name) }
    }

    public static func coverageAudit() -> ToolCoverageAudit {
        var issues: [ToolCoverageIssue] = []
        var names = Set<String>()
        var aliasOwners: [String: [String]] = [:]
        let descriptors = definitions.map(\.descriptor)
        let canonicalNames = Set(
            descriptors
                .filter { $0.visibility != .legacyOnly }
                .map(\.name)
        )
        for definition in definitions {
            let descriptor = definition.descriptor
            if !names.insert(descriptor.name).inserted {
                issues.append(.duplicateCanonicalName(descriptor.name))
            }
            if descriptor.permission != .readOnly {
                if descriptor.visibility == .model, descriptor.authorizationOperation == nil {
                    issues.append(.modelMutationMissingOperation(descriptor.name))
                }
                if descriptor.mutationScope == nil {
                    issues.append(.modelMutationMissingScope(descriptor.name))
                }
            }
            if descriptor.risk == .irreversibleDelete,
               !descriptor.confirmationPolicy.requiresExplicitUserApproval {
                issues.append(.irreversibleDeleteMissingApproval(descriptor.name))
            }
            switch definition.executorKind {
            case .catalog, .web, .systemService, .agentBridge, .recommendationSkill, .legacyCompatibility:
                break
            }
            for alias in descriptor.aliases {
                if alias.isEmpty {
                    issues.append(.emptyAlias(target: descriptor.name))
                    continue
                }
                if !Self.isValidAlias(alias) {
                    issues.append(.invalidAlias(alias: alias, target: descriptor.name))
                }
                // A legacy exact name is an allowed compatibility target;
                // another canonical name is an accidental collision.
                if alias == descriptor.name || canonicalNames.contains(alias) {
                    issues.append(.aliasCanonicalConflict(alias: alias, target: descriptor.name))
                }
                aliasOwners[alias, default: []].append(descriptor.name)
            }
        }

        for (alias, owners) in aliasOwners {
            let uniqueOwners = Array(Set(owners)).sorted()
            if owners.count > 1 {
                issues.append(.duplicateAlias(alias: alias, targets: uniqueOwners))
            }
            guard let expected = uniqueOwners.first else { continue }
            let actual = Self.descriptor(for: alias)?.name
            if actual != expected {
                issues.append(.aliasLookupMismatch(alias: alias, expected: expected, actual: actual))
            }
        }
        return ToolCoverageAudit(issues: issues)
    }

    private static func isValidAlias(_ alias: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.="))
        return alias.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 元数据查找与执行的唯一公开入口。调用方无需再判断系统工具或旧工具分支。
    public static func execute(
        _ incomingCall: ToolCall,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        allowsLyrics: Bool = false,
        providerCapabilities: ModelCapabilities? = nil,
        webService: (any AgentWebService)? = nil,
        activeSkillID: String? = nil,
        recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry = RecommendationIndexExecutionRegistry(),
        executionContext: ToolExecutorContext? = nil
    ) async -> ToolResult {
        guard let definition = definition(for: incomingCall.name) else {
            if let executionContext,
               let customDescriptor = await executionContext.customToolRegistry.descriptor(named: incomingCall.name) {
                return await executionContext.customToolRegistry.execute(
                    incomingCall,
                    descriptor: customDescriptor,
                    context: executionContext
                )
            }
            return ToolResult(
                call: incomingCall,
                permission: .readOnly,
                success: false,
                summary: "未知工具：\(incomingCall.name)",
                failure: ToolFailureEnvelope(
                    toolName: incomingCall.name,
                    phase: .discovery,
                    code: "unknown_tool",
                    retryable: false
                )
            )
        }
        let descriptor = definition.descriptor
        // Canonical aliases own the resolved metadata. If the incoming name
        // is also a retained legacy exact descriptor, keep that spelling in
        // the result for source compatibility; the canonical descriptor still
        // controls permission and execution.
        let call: ToolCall = if all.contains(where: {
            $0.name == incomingCall.name && $0.visibility == .legacyOnly
        }) {
            incomingCall
        } else if incomingCall.name == descriptor.name {
            incomingCall
        } else {
            ToolCall(name: descriptor.name, arguments: incomingCall.arguments)
        }
        let context = executionContext ?? ToolExecutorContext(
            bridge: bridge,
            catalog: catalog,
            serverID: serverID,
            systemService: systemService,
            externalMusicService: externalMusicService,
            allowsLyrics: allowsLyrics,
            providerCapabilities: providerCapabilities,
            webService: webService,
            authorizationContext: nil,
            activeSkillID: activeSkillID,
            executionAuthority: nil,
            executionLease: ToolExecutionLease(
                runID: UUID(),
                sessionID: UUID(),
                generation: 0
            ),
            resourceLeaseRegistry: MutationResourceLeaseRegistry(),
            recommendationIndexExecutionRegistry: recommendationIndexExecutionRegistry
        )
        return await definition.executor(context, call)
    }

    /// Compatibility dispatcher for built-in tools. It is intentionally not
    /// the public selection/execution API; `ToolDefinition.executor` is the
    /// canonical entry point above. Keeping this method private to the
    /// registry makes the migration auditable and prevents callers from
    /// maintaining another switch of their own.
    static func executeLegacy(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        context: ToolExecutorContext
    ) async -> ToolResult {
        let providerCapabilities = context.providerCapabilities
        let webService = context.webService
        let systemService = context.systemService
        let activeSkillID = context.activeSkillID
        let externalMusicService = context.externalMusicService
        let allowsLyrics = context.allowsLyrics
        let bridge = context.bridge
        let catalog = context.catalog
        let serverID = context.serverID
        let recommendationIndexExecutionRegistry = context.recommendationIndexExecutionRegistry
        let incomingCall = call
        let canonicalDescriptor = descriptor
        // Metadata lookup gives a canonical descriptor precedence over a
        // legacy exact descriptor with the same spelling. Preserve that
        // legacy spelling in the actual call, however, so compatibility
        // callers retain their result name while the canonical descriptor
        // still supplies permission/schema/executor metadata.
        let canonicalCall: ToolCall = if all.contains(where: {
            $0.name == incomingCall.name && $0.visibility == .legacyOnly
        }) {
            incomingCall
        } else if incomingCall.name == canonicalDescriptor.name {
            incomingCall
        } else {
            ToolCall(name: canonicalDescriptor.name, arguments: incomingCall.arguments)
        }

        if canonicalDescriptor.customToolID != nil {
            return await context.customToolRegistry.execute(
                canonicalCall,
                descriptor: canonicalDescriptor,
                context: context
            )
        }
        if canonicalCall.name.hasPrefix("tool_builder_")
            || canonicalCall.name == "tool_diagnose"
            || canonicalCall.name == "tool_repair" {
            return await context.customToolRegistry.executeBuilder(
                canonicalCall,
                descriptor: canonicalDescriptor,
                context: context
            )
        }

        switch canonicalCall.name {
        case "tool_search":
            let query = canonicalCall.optionalString("query") ?? ""
            let namespace = canonicalCall.optionalString("namespace")
            let limit = min(max(Int(canonicalCall.optionalString("limit") ?? "8") ?? 8, 1), 50)
            // 授权感知：当前 run 的 allowedOperations 传入检索，mutation 结果携带
            // authorized 标记（能力存在但当前请求未授权 = false），模型能直接看到，
            // 而不是只在下一轮 schema 阶段被悄悄过滤。
            let authorizedOperations = context.authorizationContext?.allowedOperations
            let entries = ToolCatalog(descriptors: context.availableToolDescriptors)
                .search(
                    query: query,
                    namespace: namespace,
                    limit: limit,
                    activeSkillID: activeSkillID,
                    authorizedOperations: authorizedOperations
                )
            let text = entries.isEmpty
                ? "未找到匹配工具。可以换一个能力描述、工具名或命名空间再搜索。"
                : entries.map { entry in
                    let flags = [
                        entry.sideEffect == .none ? "只读" : "会改变状态",
                        entry.networkAccess ? "联网" : nil,
                    ].compactMap { $0 }.joined(separator: " · ")
                    let authFlag: String
                    if let authorized = entry.authorized {
                        authFlag = authorized ? "当前请求已授权" : "当前请求未授权（不要调用，Runtime 会拒绝）"
                    } else {
                        authFlag = ""
                    }
                    return "\(entry.name) [\(entry.namespace)]：\(entry.summary)（\(flags)）\(authFlag.isEmpty ? "" : "；\(authFlag)")"
                }.joined(separator: "\n")
            return .ok(canonicalCall, canonicalDescriptor, "发现 \(entries.count) 个工具", .text(text))
        case "capabilities_get":
            let capabilities = providerCapabilities ?? .conservative
            let mode = capabilities.toolMode.rawValue
            let providerText = capabilities.supportsToolCalling ? "原生工具调用=支持" : "原生工具调用=不支持"
            let webText = [
                capabilities.supportsHostedWebSearch ? "Provider 搜索" : nil,
                capabilities.supportsHostedWebFetch ? "Provider 网页读取" : nil,
                webService == nil ? nil : "App 网页能力",
            ].compactMap { $0 }.joined(separator: "、")
            let text = [
                "工具协议：\(mode)",
                providerText,
                "并行工具=\(capabilities.supportsParallelTools ? "支持" : "不支持") · tool_choice=\(capabilities.supportsToolChoice ? "支持" : "不支持") · strict schema=\(capabilities.supportsStrictSchema ? "支持" : "不支持")",
                "上下文约 \(capabilities.maxContextTokens) tokens · 输出约 \(capabilities.maxOutputTokens) tokens",
                "联网能力：\(webText.isEmpty ? "未配置" : webText)",
            ].joined(separator: "\n")
            return .ok(canonicalCall, canonicalDescriptor, "已读取当前能力摘要", .text(text))
        case "web_search":
            guard let webService else {
                return .fail(canonicalCall, canonicalDescriptor, "联网能力未配置；当前 Provider 也没有托管搜索能力。")
            }
            do {
                let query = canonicalCall.optionalString("query") ?? ""
                let limit = min(max(Int(canonicalCall.optionalString("limit") ?? "5") ?? 5, 1), 10)
                let result = try await webService.search(query: query, limit: limit)
                return .ok(
                    canonicalCall,
                    canonicalDescriptor,
                    "联网搜索找到 \(result.sources.count) 个来源",
                    .webSources(result.sources),
                    trustLevel: .externalUntrusted
                )
            } catch {
                return .fail(canonicalCall, canonicalDescriptor, "联网搜索失败：\(error.localizedDescription)")
            }
        case "web_fetch":
            guard let webService else {
                return .fail(canonicalCall, canonicalDescriptor, "网页读取能力未配置。")
            }
            guard let rawURL = canonicalCall.optionalString("url"), let url = URL(string: rawURL) else {
                return .fail(canonicalCall, canonicalDescriptor, "网页地址无效。")
            }
            do {
                let document = try await webService.fetch(url: url)
                return .ok(
                    canonicalCall,
                    canonicalDescriptor,
                    "已读取网页：\(document.source.title)",
                    .text("来源：\(document.source.title)\nURL：\(document.source.url.absoluteString)\n\n\(document.text)"),
                    trustLevel: .externalUntrusted
                )
            } catch {
                return .fail(canonicalCall, canonicalDescriptor, "网页读取失败：\(error.localizedDescription)")
            }
        case "music_download_search", "music_download_submit", "music_download_status",
             "music_download_tasks", "music_download_history", "music_download_history_remove",
             "music_download_history_clean":
            guard let systemService, let legacyDescriptor = Self.descriptor(for: "music_download") else {
                return .fail(canonicalCall, canonicalDescriptor, "音乐下载系统服务不可用。")
            }
            var legacyArguments = canonicalCall.arguments
            let action: String
            switch canonicalCall.name {
            case "music_download_search": action = "search"
            case "music_download_submit": action = "download"
            case "music_download_status": action = "status"
            case "music_download_tasks": action = "tasks"
            case "music_download_history": action = "history"
            case "music_download_history_remove": action = "history_remove"
            default: action = "history_clean"
            }
            legacyArguments["action"] = .string(action)
            return await SystemToolExecutor.execute(
                ToolCall(name: "music_download", arguments: legacyArguments),
                descriptor: legacyDescriptor,
                systemService: systemService,
                allowsLyrics: allowsLyrics
            )
        default:
            break
        }
        if SystemToolNames.contains(canonicalCall.name) {
            guard let systemService else {
                return ToolResult(call: canonicalCall, permission: canonicalDescriptor.permission, success: false, summary: "系统服务不可用：当前设备未提供该系统能力。")
            }
            return await SystemToolExecutor.execute(
                canonicalCall,
                descriptor: canonicalDescriptor,
                systemService: systemService,
                allowsLyrics: allowsLyrics
            )
        }
        return await AgentToolkit.executeRegistered(
            canonicalCall,
            descriptor: canonicalDescriptor,
            bridge: bridge,
            catalog: catalog,
            serverID: serverID,
            externalMusicService: externalMusicService,
            allowsLyrics: allowsLyrics,
            recommendationIndexExecutionRegistry: recommendationIndexExecutionRegistry
        )
    }

    /*
     * The old implementation body was intentionally moved into the closure
     * adapter above.  Keep the old source-level API below as a thin bridge for
     * integrations compiled against the pre-definition registry.
     */
    public static func executeLegacy(
        _ incomingCall: ToolCall,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        allowsLyrics: Bool = false,
        providerCapabilities: ModelCapabilities? = nil,
        webService: (any AgentWebService)? = nil,
        activeSkillID: String? = nil,
        recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry = RecommendationIndexExecutionRegistry()
    ) async -> ToolResult {
        guard let descriptor = descriptor(for: incomingCall.name) else {
            return ToolResult(call: incomingCall, permission: .readOnly, success: false, summary: "未知工具：\(incomingCall.name)")
        }
        let context = ToolExecutorContext(
            bridge: bridge,
            catalog: catalog,
            serverID: serverID,
            systemService: systemService,
            externalMusicService: externalMusicService,
            allowsLyrics: allowsLyrics,
            providerCapabilities: providerCapabilities,
            webService: webService,
            authorizationContext: nil,
            activeSkillID: activeSkillID,
            executionAuthority: nil,
            executionLease: ToolExecutionLease(runID: UUID(), sessionID: UUID(), generation: 0),
            resourceLeaseRegistry: MutationResourceLeaseRegistry(),
            recommendationIndexExecutionRegistry: recommendationIndexExecutionRegistry
        )
        return await executeLegacy(incomingCall, descriptor: descriptor, context: context)
    }
}
