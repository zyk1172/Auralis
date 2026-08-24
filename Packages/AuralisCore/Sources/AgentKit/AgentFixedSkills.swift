import AIKit
import Domain
import Foundation
import LocalCatalog

// MARK: - Built-in Fixed Skills
//
// 原则：
// - 稳定、多步骤、mutation 顺序确定的组合任务交给 Skill，LLM 只负责语义选歌；
// - Skill-owned mutation 对模型隐藏（selectedTools 移除 + privateToolNames），
//   由 Skill 内部通过 forcedSkillCall 固定调用 canonical ToolRuntime 工具，
//   继续获得 authorization / lease / validation / confirmation / metrics；
// - Skill 不扩权：requiredOperations 必须 ⊆ 当前 allowedOperations 才激活；
// - completion 只基于真实 canonical tool result + state verification，
//   模型正文永远是 provisional。

// MARK: - 公共 Skill 元数据

public enum QueueReplacePlaybackSkill {
    public static let id = "builtin.queue_replace_playback"
    public static let name = "替换队列并播放"
    public static let requiredOperations: Set<ToolAuthorizationOperation> = [.queueReplace]
    /// Skill 主路径 mutation（对模型隐藏，由 Skill 内部固定调用）。
    public static let ownedMutationTools: Set<String> = [
        "queue_replace", "replaceQueue",
        "playback_play_song", "playTrack",
    ]
}

public enum PlaylistBuildSkill {
    public static let id = "builtin.playlist_build"
    public static let name = "创建歌单并加入歌曲"
    public static let requiredOperations: Set<ToolAuthorizationOperation> = [.playlistCreate, .playlistAdd]
    /// Skill 主路径 mutation（对模型隐藏，由 Skill 内部固定调用）。
    public static let ownedMutationTools: Set<String> = [
        "playlist_create", "createPlaylist",
        "playlist_add_songs", "addTracksToPlaylist",
    ]
}

// MARK: - QueueReplacePlaybackSkill

public struct BuiltInQueueReplacePlaybackSkill: AgentStatefulSkill {
    public init() {}

    public let id = QueueReplacePlaybackSkill.id
    public let name = QueueReplacePlaybackSkill.name
    public let instructions = """
        当前任务由固定 Skill「替换队列并播放」编排：你只负责在音乐库中找到用户想要的歌曲并调用 \
        result_present_tracks(trackIDs=[最终歌曲]) 提交最终候选。不要自己调用 queue_replace / \
        queue_clear / queue_append / queue_play_next 等队列写操作——队列替换与（如获授权）播放由系统 \
        确定性执行并验证。
        """
    public var privateToolNames: Set<String> { QueueReplacePlaybackSkill.ownedMutationTools }
    public var requiredOperations: Set<ToolAuthorizationOperation> { QueueReplacePlaybackSkill.requiredOperations }

    public func canActivate(
        semantics: AgentRequestSemantics,
        userText: String,
        initialTaskState: AgentTaskState?
    ) -> Bool {
        _ = userText
        _ = initialTaskState
        return semantics.requestedOperations.contains(.queueReplace)
    }

    public func makeRuntime(checkpointJSON: String?) -> any AgentStatefulSkillRuntime {
        QueueReplacePlaybackSkillRuntime(checkpointJSON: checkpointJSON)
    }
}

final class QueueReplacePlaybackSkillRuntime: AgentStatefulSkillRuntime, @unchecked Sendable {
    private enum Phase: Equatable {
        case collectingCandidates
        case replacingQueue
        case verifyingQueue
        case startingPlayback
        case verifyingPlayback
        case completed

        var label: String {
            switch self {
            case .collectingCandidates: return "collectingCandidates"
            case .replacingQueue: return "replacingQueue"
            case .verifyingQueue: return "verifyingQueue"
            case .startingPlayback: return "startingPlayback"
            case .verifyingPlayback: return "verifyingPlayback"
            case .completed: return "completed"
            }
        }
    }

    private var phase: Phase = .collectingCandidates
    private var targetCount: Int?
    private var selectedTrackIDs: [String] = []
    private var queueReplacementCommitted = false
    private var allowsPlayback = false
    private var transitionCount = 0

    public var skillID: String { QueueReplacePlaybackSkill.id }
    public var privateToolNames: Set<String> { QueueReplacePlaybackSkill.ownedMutationTools }
    public var ownedToolNames: Set<String> { QueueReplacePlaybackSkill.ownedMutationTools }
    public var requiredOperations: Set<ToolAuthorizationOperation> { QueueReplacePlaybackSkill.requiredOperations }
    public var isCompleted: Bool { phase == .completed }
    public let instructions = BuiltInQueueReplacePlaybackSkill().instructions

    public var facts: [String: String] {
        [
            "queue.skill.phase": phase.label,
            "queue.skill.committed": queueReplacementCommitted ? "true" : "false",
            "queue.skill.transitions": "\(transitionCount)",
            "queue.skill.selectedCount": "\(selectedTrackIDs.count)",
        ]
    }

    init(checkpointJSON: String?) {
        // 短任务：不持久化 checkpoint；resume 语义由 Runtime facts（queue 真实状态）负责。
        _ = checkpointJSON
    }

    public func configure(maxOutputTokens: Int) {}

    public func configure(authorization: SideEffectAuthorizationContext) {
        // 只消费既有授权：Skill 是否播放完全由用户已授权的 operations 决定。
        allowsPlayback = authorization.allowedOperations.contains(.playbackPlay)
    }

    public func nextStep() -> AgentSkillStep {
        switch phase {
        case .collectingCandidates:
            return .freeModelTurn
        case .replacingQueue:
            let ids = selectedTrackIDs.prefix(max(targetCount ?? selectedTrackIDs.count, 1))
            return .executeTool(
                name: "queue_replace",
                arguments: ["trackIDs": .array(ids.map(AIJSONValue.string))]
            )
        case .verifyingQueue:
            return .executeTool(name: "queue_get", arguments: [:])
        case .startingPlayback:
            guard let first = selectedTrackIDs.first else {
                phase = .completed
                return .completed(message: "队列已替换，但没有可播放的歌曲。")
            }
            return .executeTool(
                name: "playback_play_song",
                arguments: ["trackID": .string(first)]
            )
        case .verifyingPlayback:
            return .freeModelTurn
        case .completed:
            return .completed(message: "队列已替换并验证完成。")
        }
    }

    public func consumeModelOutput(_ text: String, contract: AgentSkillOutputContract) -> AgentSkillModelOutput {
        // 候选收集阶段模型不应输出结构化分类数据；返回 retry 引导提交候选。
        _ = contract
        return .retry(AgentSkillRecovery(
            message: "本任务不需要结构化分类输出。请使用音乐库搜索/推荐工具找到候选，然后调用 result_present_tracks(trackIDs=[最终歌曲]) 提交最终选择。",
            dropCurrentBatch: false,
            compactTranscript: false
        ))
    }

    public func prepareToolCall(name: String, arguments: [String: AIJSONValue]) -> [String: AIJSONValue] {
        arguments
    }

    public func validateToolCall(name: String, arguments: [String: AIJSONValue]) -> String? {
        nil
    }

    public func consumeToolResult(name: String, result: ToolResult) -> AgentSkillToolConsumption {
        guard result.success else {
            // 非 Skill-owned（read/selection）工具失败不破坏状态机；owned mutation
            // 失败走确定性失败路径。
            if ownedToolNames.contains(name) {
                return handleToolFailure(name: name, message: result.summary)
            }
            return .none
        }
        switch name {
        case "result_present_tracks":
            // 只有 final selection（非 disambiguation）才是候选提交信号。
            guard result.presentationRole == .finalResult else { return .none }
            guard case let .trackCards(cards) = result.payload else { return .none }
            var seen = Set<String>()
            let ids = cards.map(\.globalID.description).filter { seen.insert($0).inserted }
            guard !ids.isEmpty else { return .none }
            selectedTrackIDs = ids
            transition(to: .replacingQueue)
            return .none
        case "queue_replace", "replaceQueue":
            queueReplacementCommitted = true
            transition(to: .verifyingQueue)
            return .none
        case "queue_get", "getCurrentQueue":
            // 队列替换后的只读验证：queue_get 成功即队列状态可读；数量匹配作为硬校验。
            if let count = Self.queueCount(from: result.summary) {
                let expected = max(targetCount ?? selectedTrackIDs.count, 0)
                if count < expected {
                    return .fail("队列替换后验证失败：队列 \(count) 首，少于预期 \(expected) 首。")
                }
            }
            if allowsPlayback, let first = selectedTrackIDs.first, !first.isEmpty {
                transition(to: .startingPlayback)
            } else {
                transition(to: .completed)
            }
            return .none
        case "playback_play_song", "playTrack":
            transition(to: .completed)
            return .none
        default:
            // 候选收集阶段的 read / recommendation 工具结果：继续收集。
            return .none
        }
    }

    public func handleToolFailure(name: String, message: String) -> AgentSkillToolConsumption {
        switch name {
        case "queue_replace", "replaceQueue":
            // 队列替换失败：直接失败并报告，绝不 fallback 到 queue_clear + queue_append_many。
            return .fail("队列替换失败，未执行任何播放；本次不使用替代队列方案：\(message)")
        case "queue_get", "getCurrentQueue":
            return .fail("队列替换后状态验证失败：\(message)")
        case "playback_play_song", "playTrack":
            // 队列已替换成功；播放失败属于 partial，不重复替换队列。
            return .fail("队列已替换成功，但开始播放失败：\(message)")
        default:
            return .none
        }
    }

    public func handleProviderFailure(_ error: Error) -> AgentSkillRecovery? {
        nil
    }

    public func handleMalformedCall(name: String) -> AgentSkillRecovery? {
        nil
    }

    public func completionDecision(repairAttempts: Int) -> AgentModelAnswerDecision {
        if isCompleted {
            return .accept
        }
        return .continueTask(
            "当前任务需要候选歌曲。请使用音乐库搜索/推荐工具找到用户想要的歌曲，然后调用 result_present_tracks(trackIDs=[真正最终选择的歌曲]) 提交；不要自己直接修改播放队列。"
        )
    }

    public func markCheckpoint(stoppedReason: String?) {
        _ = stoppedReason
    }

    public func checkpointJSON() -> String? {
        nil
    }

    private func transition(to next: Phase) {
        phase = next
        transitionCount += 1
    }

    private static func queueCount(from summary: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"队列\s*(\d+)\s*首"#) else { return nil }
        let range = NSRange(summary.startIndex..<summary.endIndex, in: summary)
        guard let match = regex.firstMatch(in: summary, range: range),
              let capture = Range(match.range(at: 1), in: summary) else { return nil }
        return Int(summary[capture])
    }
}

// MARK: - PlaylistBuildSkill

public struct BuiltInPlaylistBuildSkill: AgentStatefulSkill {
    public init() {}

    public let id = PlaylistBuildSkill.id
    public let name = PlaylistBuildSkill.name
    public let instructions = """
        当前任务由固定 Skill「创建歌单并加入歌曲」编排：你只负责在音乐库中找到用户想要的歌曲并调用 \
        result_present_tracks(trackIDs=[最终歌曲]) 提交最终候选。歌单创建、加歌与验证由系统确定性执行；\
        不要自己调用 playlist_create / playlist_add_songs / playlist_delete。
        """
    public var privateToolNames: Set<String> { PlaylistBuildSkill.ownedMutationTools }
    public var requiredOperations: Set<ToolAuthorizationOperation> { PlaylistBuildSkill.requiredOperations }

    public func canActivate(
        semantics: AgentRequestSemantics,
        userText: String,
        initialTaskState: AgentTaskState?
    ) -> Bool {
        _ = userText
        _ = initialTaskState
        // 只有同时授权 create + add 才进入完整 Skill；仅 create 走单步 canonical 执行。
        return semantics.requestedOperations.contains(.playlistCreate)
            && semantics.requestedOperations.contains(.playlistAdd)
    }

    public func makeRuntime(checkpointJSON: String?) -> any AgentStatefulSkillRuntime {
        PlaylistBuildSkillRuntime(checkpointJSON: checkpointJSON)
    }
}

/// PlaylistBuild 的可恢复 checkpoint（短任务也保留已创建歌单 ID，避免 resume 重复创建）。
private struct PlaylistBuildCheckpoint: Codable {
    var playlistID: String?
    var playlistName: String
    var targetCount: Int?
    var createdPlaylist: Bool

    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ raw: String?) -> PlaylistBuildCheckpoint? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlaylistBuildCheckpoint.self, from: data)
    }
}

final class PlaylistBuildSkillRuntime: AgentStatefulSkillRuntime, @unchecked Sendable {
    private enum Phase: Equatable {
        case collectingCandidates
        case creatingPlaylist
        case addingTracks
        case verifyingPlaylist
        case completed

        var label: String {
            switch self {
            case .collectingCandidates: return "collectingCandidates"
            case .creatingPlaylist: return "creatingPlaylist"
            case .addingTracks: return "addingTracks"
            case .verifyingPlaylist: return "verifyingPlaylist"
            case .completed: return "completed"
            }
        }
    }

    private var phase: Phase
    private var targetCount: Int?
    private var selectedTrackIDs: [String] = []
    private var playlistName: String
    private var createdPlaylistID: String?
    private var playlistCreated = false
    private var tracksAdded = false
    private var transitionCount = 0

    public var skillID: String { PlaylistBuildSkill.id }
    public var privateToolNames: Set<String> { PlaylistBuildSkill.ownedMutationTools }
    public var ownedToolNames: Set<String> { PlaylistBuildSkill.ownedMutationTools }
    public var requiredOperations: Set<ToolAuthorizationOperation> { PlaylistBuildSkill.requiredOperations }
    public var isCompleted: Bool { phase == .completed }
    public let instructions = BuiltInPlaylistBuildSkill().instructions

    public var facts: [String: String] {
        var values = [
            "playlist.skill.phase": phase.label,
            "playlist.skill.playlistName": playlistName,
            "playlist.skill.created": playlistCreated ? "true" : "false",
            "playlist.skill.tracksAdded": tracksAdded ? "true" : "false",
            "playlist.skill.selectedCount": "\(selectedTrackIDs.count)",
            "playlist.skill.transitions": "\(transitionCount)",
        ]
        if let createdPlaylistID {
            values["playlist.skill.playlistID"] = createdPlaylistID
        }
        return values
    }

    init(checkpointJSON: String?, userText: String = "") {
        let checkpoint = PlaylistBuildCheckpoint.decode(checkpointJSON)
        playlistName = checkpoint?.playlistName ?? Self.inferPlaylistName(from: userText)
        targetCount = checkpoint?.targetCount
        createdPlaylistID = checkpoint?.playlistID
        playlistCreated = checkpoint?.createdPlaylist ?? false
        if let createdPlaylistID, !createdPlaylistID.isEmpty {
            // resume：已有真实歌单，从 addingTracks 继续，绝不重新 create。
            phase = .addingTracks
        } else {
            phase = .collectingCandidates
        }
    }

    public func configure(maxOutputTokens: Int) {}

    public func configure(authorization: SideEffectAuthorizationContext) {
        _ = authorization
    }

    public func nextStep() -> AgentSkillStep {
        switch phase {
        case .collectingCandidates:
            return .freeModelTurn
        case .creatingPlaylist:
            return .executeTool(
                name: "playlist_create",
                arguments: ["name": .string(playlistName)]
            )
        case .addingTracks:
            guard let playlistID = createdPlaylistID else {
                phase = .collectingCandidates
                return .freeModelTurn
            }
            let ids = Array(selectedTrackIDs.prefix(max(targetCount ?? selectedTrackIDs.count, 1)))
            return .executeTool(
                name: "playlist_add_songs",
                arguments: [
                    "playlistID": .string(playlistID),
                    "trackIDs": .array(ids.map(AIJSONValue.string)),
                ]
            )
        case .verifyingPlaylist:
            guard let playlistID = createdPlaylistID else {
                transition(to: .completed)
                return .completed(message: "歌单已创建。")
            }
            return .executeTool(
                name: "library_get_playlist",
                arguments: ["playlistID": .string(playlistID)]
            )
        case .completed:
            return .completed(message: "歌单已创建并加入歌曲。")
        }
    }

    public func consumeModelOutput(_ text: String, contract: AgentSkillOutputContract) -> AgentSkillModelOutput {
        _ = contract
        return .retry(AgentSkillRecovery(
            message: "本任务不需要结构化分类输出。请使用音乐库搜索/推荐工具找到候选，然后调用 result_present_tracks(trackIDs=[最终歌曲]) 提交最终选择。",
            dropCurrentBatch: false,
            compactTranscript: false
        ))
    }

    public func prepareToolCall(name: String, arguments: [String: AIJSONValue]) -> [String: AIJSONValue] {
        arguments
    }

    public func validateToolCall(name: String, arguments: [String: AIJSONValue]) -> String? {
        nil
    }

    public func consumeToolResult(name: String, result: ToolResult) -> AgentSkillToolConsumption {
        guard result.success else {
            // 非 Skill-owned（read/selection）工具失败不破坏状态机。
            if ownedToolNames.contains(name) {
                return handleToolFailure(name: name, message: result.summary)
            }
            return .none
        }
        switch name {
        case "result_present_tracks":
            guard result.presentationRole == .finalResult else { return .none }
            guard case let .trackCards(cards) = result.payload else { return .none }
            var seen = Set<String>()
            let ids = cards.map(\.globalID.description).filter { seen.insert($0).inserted }
            guard !ids.isEmpty else { return .none }
            selectedTrackIDs = ids
            if createdPlaylistID != nil {
                transition(to: .addingTracks)
            } else {
                transition(to: .creatingPlaylist)
            }
            return .none
        case "playlist_create", "createPlaylist":
            playlistCreated = true
            // GlobalID 从 payload 文本“名称 · id”提取。
            createdPlaylistID = Self.extractPlaylistID(from: result.payload, fallback: result.summary)
            transition(to: .addingTracks)
            return .none
        case "playlist_add_songs", "addTracksToPlaylist":
            tracksAdded = true
            transition(to: .verifyingPlaylist)
            return .none
        case "library_get_playlist", "getPlaylist":
            // 只读验证成功（歌单可读）即完成。
            transition(to: .completed)
            return .none
        default:
            return .none
        }
    }

    public func handleToolFailure(name: String, message: String) -> AgentSkillToolConsumption {
        switch name {
        case "playlist_create", "createPlaylist":
            return .fail("创建歌单失败：\(message)")
        case "playlist_add_songs", "addTracksToPlaylist":
            // create 已成功、add 失败 → partial completion：不自动删除歌单
            //（playlistDelete 是另一项 destructive 授权），也不重新创建。
            return .fail("歌单已创建，但歌曲加入失败：\(message)")
        case "library_get_playlist", "getPlaylist":
            return .fail("歌单创建后验证失败：\(message)")
        default:
            return .none
        }
    }

    public func handleProviderFailure(_ error: Error) -> AgentSkillRecovery? {
        nil
    }

    public func handleMalformedCall(name: String) -> AgentSkillRecovery? {
        nil
    }

    public func completionDecision(repairAttempts: Int) -> AgentModelAnswerDecision {
        if isCompleted {
            return .accept
        }
        return .continueTask(
            "当前任务需要候选歌曲。请使用音乐库搜索/推荐工具找到用户想要的歌曲，然后调用 result_present_tracks(trackIDs=[真正最终选择的歌曲]) 提交；不要自己直接创建或修改歌单。"
        )
    }

    public func markCheckpoint(stoppedReason: String?) {
        _ = stoppedReason
    }

    public func checkpointJSON() -> String? {
        PlaylistBuildCheckpoint(
            playlistID: createdPlaylistID,
            playlistName: playlistName,
            targetCount: targetCount,
            createdPlaylist: playlistCreated
        ).jsonString
    }

    private func transition(to next: Phase) {
        phase = next
        transitionCount += 1
    }

    /// 从用户文本提取歌单名（“创建一个通勤歌单” → “通勤”）。
    private static func inferPlaylistName(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: #"创建(?:一个)?(?:叫|命名为|名字是)?[\s「『\"']?([^，。！？、\s「」『』\"']{1,16}?)(?:歌单|播放列表)"#),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let capture = Range(match.range(at: 1), in: trimmed) {
            let name = String(trimmed[capture]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return "新建歌单"
    }

    /// playlist_create 的 payload 是 .text("名称 · GlobalID")。
    private static func extractPlaylistID(from payload: AgentMessage?, fallback: String) -> String? {
        if case let .text(text)? = payload, let separator = text.range(of: " · ") {
            let candidate = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            if GlobalID(candidate) != nil { return candidate }
        }
        // fallback：summary 或 payload 中最后一个形如 server:id 的片段。
        let sources = [fallback, payload.map(Self.textValue) ?? ""]
        for source in sources {
            let pieces = source.split(separator: " ").map(String.init)
            for piece in pieces.reversed() {
                let candidate = piece.trimmingCharacters(in: CharacterSet(charactersIn: "。，,；;"))
                if GlobalID(candidate) != nil { return candidate }
            }
        }
        return nil
    }

    private static func textValue(_ payload: AgentMessage) -> String {
        if case let .text(text) = payload { return text }
        return ""
    }
}
