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
//   继续获得 lease / validation / confirmation / metrics；
// - Skill 由语义触发，requiredOperations 仅作为能力/诊断元数据，不是执行 gate；
// - completion 只基于真实 canonical tool result + state verification，
//   模型正文永远是 provisional。

// MARK: - 公共 Skill 元数据

/// 从用户文本确定性提取歌单名（由注册表在激活时编译进
/// `BuiltInSkillActivationContext.compiledPlaylistName`，Skill 不自行解析）。
/// 支持：
/// - “创建一个通勤歌单” / “新建一个通勤歌单” / “建个通勤歌单”
/// - “创建一个叫通勤的歌单” / “创建一个歌单叫通勤” / “创建歌单「通勤」”
/// - “歌单叫通勤”
public enum AgentSkillPlaylistNameParser {
    public static func infer(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 候选捕获：非空白、非标点、非引号的 1-16 字符连续段（非贪婪，
        // 由后缀模式提供回溯锚点，避免把“通勤的”整段吃掉）。
        let nameCapture = #"([^，。！？、\s「」『』\"'“”‘’]{1,16}?)"#
        // 1) 显式“叫/命名为/名字是”：名字在动词后，优先级最高。
        let explicitPattern = #"(?:歌单|播放列表)(?:的)?(?:名字是|叫|命名为|是)[「『\"'“”‘’]?"# + nameCapture + #"(?=$|[，。！？、\s「」『』"'“”‘’])"#
        // 2) “创建一个(叫|命名为)X的歌单”：X 在歌单前（“的”作为可选连接词）。
        let prefixPattern = #"(?:创建|新建|建|做一个?|搞个)(?:一个|个)?(?:叫|命名为|名字是)?[「『\"'“”‘’]?"# + nameCapture + #"(?:的)?(?:歌单|播放列表)"#
        // 3) “创建歌单X” / “创建X歌单”：歌单紧跟创建动词。
        let trailingPattern = #"(?:创建|新建|建|做一个?|搞个)(?:一个|个)?(?:歌单|播放列表)[「『\"'“”‘’]?"# + nameCapture + #"(?=$|[，。！？、\s「」『』"'“”‘’])"#
        // 4) “X歌单”（X 是限定词，如“通勤歌单”）——兜底。
        let barePattern = #"(?:创建|新建|建)(?:一个)?(?:叫|命名为)?[「『\"'“”‘’]?"# + nameCapture + #"(?:的)?歌单"#

        let patterns = [explicitPattern, prefixPattern, trailingPattern, barePattern]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let capture = Range(match.range(at: 1), in: trimmed) else { continue }
            let name = String(trimmed[capture]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains("歌单"), !name.contains("播放列表") {
                return name
            }
        }
        return nil
    }
}

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
        queue_clear / queue_append / queue_play_next 等队列写操作——队列替换与（如请求）播放由系统 \
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
        makeRuntime(checkpointJSON: checkpointJSON, activation: nil)
    }

    public func makeRuntime(
        checkpointJSON: String?,
        activation: BuiltInSkillActivationContext?
    ) -> any AgentStatefulSkillRuntime {
        QueueReplacePlaybackSkillRuntime(checkpointJSON: checkpointJSON, activation: activation)
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

    init(checkpointJSON: String?, activation: BuiltInSkillActivationContext? = nil) {
        // 短任务：不持久化 checkpoint；resume 语义由 Runtime facts（queue 真实状态）负责。
        _ = checkpointJSON
        // 用户请求中的目标数量（“十首 → 10”）在激活时编译进来；模型即使提交超量
        // 候选，Skill 也只取目标数量。
        targetCount = activation?.inferredTargetCount
        if let activation {
            allowsPlayback = activation.semantics.requestedOperations.contains(.playbackPlay)
        } else {
            // Compatibility callers that construct the runtime without an
            // activation context retain the historical combined behavior.
            allowsPlayback = true
        }
    }

    public func configure(maxOutputTokens: Int) {}

    public func configure(authorization: SideEffectAuthorizationContext) {
        // The operation set is telemetry only. Playback follows the semantic
        // request compiled into the activation context, not an exact
        // authorization match.
        _ = authorization
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
            return .executeTool(name: "playback_get_state", arguments: [:])
        case .completed:
            return .completed(message: allowsPlayback
                ? "队列已替换并开始播放，验证完成。"
                : "队列已替换并验证完成。")
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
            // 完整性检查必须在任何 mutation 之前：用户要求 N 首，候选不足时不得先
            // 修改真实状态（队列/播放）再在验证阶段失败。
            if let targetCount, targetCount > 0 {
                guard ids.count >= targetCount else {
                    return .fail("候选不足：只找到 \(ids.count) 首，用户要求 \(targetCount) 首；未执行任何队列/播放修改。")
                }
                // 用户要求 N 首 → 去重后只取前 N 首；模型给多了（如 58 首）必须硬约束到 N。
                selectedTrackIDs = ids.count > targetCount ? Array(ids.prefix(targetCount)) : ids
            } else {
                selectedTrackIDs = ids
            }
            transition(to: .replacingQueue)
            return .none
        case "queue_replace", "replaceQueue":
            queueReplacementCommitted = true
            transition(to: .verifyingQueue)
            return .none
        case "queue_get", "getCurrentQueue":
            // 队列替换后的只读验证：replace 是精确替换，队列数量必须等于提交数量。
            // 数量可从 summary“队列 N 首”解析；解析不到时以工具成功为最低确认。
            if let count = Self.queueCount(from: result.summary) {
                let expected = max(targetCount ?? selectedTrackIDs.count, 0)
                if count != expected {
                    return .fail("队列替换后验证失败：队列 \(count) 首，应为 \(expected) 首。")
                }
            }
            if allowsPlayback, let first = selectedTrackIDs.first, !first.isEmpty {
                transition(to: .startingPlayback)
            } else {
                transition(to: .completed)
            }
            return .none
        case "playback_play_song", "playTrack":
            // 播放已发起；进入 playback 状态验证（verifyingPlayback 不再是死状态）。
            transition(to: .verifyingPlayback)
            return .none
        case "playback_get_state":
            // 播放状态确认：当前必须有正在播放的歌曲。
            if result.summary.contains("当前没有正在播放") {
                return .fail("队列已替换成功，但播放状态验证失败：当前没有正在播放的歌曲。")
            }
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
        case "playback_get_state":
            // 队列与播放已提交，但状态无法确认 → partial，不重复替换队列。
            return .fail("队列已替换成功，但播放状态验证失败：\(message)")
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
        // 只有同时请求 create + add 才进入完整 Skill；仅 create 走单步
        // canonical 执行。这里是组合流程路由，不是本地工具执行许可。
        return semantics.requestedOperations.contains(.playlistCreate)
            && semantics.requestedOperations.contains(.playlistAdd)
    }

    public func makeRuntime(checkpointJSON: String?) -> any AgentStatefulSkillRuntime {
        makeRuntime(checkpointJSON: checkpointJSON, activation: nil)
    }

    public func makeRuntime(
        checkpointJSON: String?,
        activation: BuiltInSkillActivationContext?
    ) -> any AgentStatefulSkillRuntime {
        PlaylistBuildSkillRuntime(
            checkpointJSON: checkpointJSON,
            userText: activation?.currentUserText ?? "",
            targetCount: activation?.inferredTargetCount,
            compiledPlaylistName: activation?.compiledPlaylistName
        )
    }
}

/// PlaylistBuild 的可恢复 checkpoint。恢复所必需的最小状态：已创建歌单 ID、
/// 已选候选、已加歌标记、当前 phase，以及分页验证的断点与已核验歌曲集合。
/// 旧版本 checkpoint 缺少新字段时用 decodeIfPresent 兼容回退。
private struct PlaylistBuildCheckpoint: Codable {
    var playlistID: String?
    var playlistName: String
    var targetCount: Int?
    var createdPlaylist: Bool
    var selectedTrackIDs: [String]?
    var tracksAdded: Bool?
    var phase: String?
    var verificationOffset: Int?
    var verifiedTrackIDs: [String]?

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
    private var verificationOffset = 0
    private var verifiedTrackIDs: Set<String> = []
    private let verificationPageSize = 100

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

    init(
        checkpointJSON: String?,
        userText: String = "",
        targetCount: Int? = nil,
        compiledPlaylistName: String? = nil
    ) {
        let checkpoint = PlaylistBuildCheckpoint.decode(checkpointJSON)
        // 歌单名来源优先级：checkpoint（resume）> activation 编译值（生产路径）>
        // 兜底解析。生产路径不再依赖 Skill 自行 regex。
        playlistName = checkpoint?.playlistName
            ?? compiledPlaylistName
            ?? Self.inferPlaylistName(from: userText)
        // 生产路径 activation 编译的 targetCount 优先；resume 时 checkpoint 值次之。
        self.targetCount = targetCount ?? checkpoint?.targetCount
        createdPlaylistID = checkpoint?.playlistID
        playlistCreated = checkpoint?.createdPlaylist ?? false
        tracksAdded = checkpoint?.tracksAdded ?? false
        selectedTrackIDs = checkpoint?.selectedTrackIDs ?? []
        verificationOffset = max(checkpoint?.verificationOffset ?? 0, 0)
        verifiedTrackIDs = Set(checkpoint?.verifiedTrackIDs ?? [])
        // 完整恢复：按 checkpoint 保存的 phase + 状态推进，而不是无条件 addingTracks。
        switch checkpoint?.phase {
        case "verifyingPlaylist":
            phase = createdPlaylistID != nil ? .verifyingPlaylist : .collectingCandidates
        case "addingTracks", "creatingPlaylist":
            // 已有真实歌单且有候选 → 继续加歌；有歌单但候选丢失（旧 checkpoint）
            // → 回候选收集（保留歌单 ID，绝不重新 create）。
            if createdPlaylistID != nil {
                phase = selectedTrackIDs.isEmpty ? .collectingCandidates : .addingTracks
            } else {
                phase = .collectingCandidates
            }
        default:
            // 旧版 checkpoint（无 phase 字段）：有歌单且有候选 → 继续加歌；
            // 否则回候选收集。
            if createdPlaylistID != nil, !selectedTrackIDs.isEmpty {
                phase = .addingTracks
            } else {
                phase = .collectingCandidates
            }
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
            guard !selectedTrackIDs.isEmpty else {
                // 有歌单但没有候选（旧 checkpoint 恢复）→ 回候选收集，
                // 绝不发出空 trackIDs 的 playlist_add_songs。
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
                arguments: [
                    "playlistID": .string(playlistID),
                    "offset": .number(Double(verificationOffset)),
                    "limit": .number(Double(verificationPageSize)),
                ]
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
            // 完整性检查必须在任何 mutation 之前：候选不足时不得先创建歌单/加歌
            // 再在验证阶段失败。
            if let targetCount, targetCount > 0 {
                guard ids.count >= targetCount else {
                    return .fail("候选不足：只找到 \(ids.count) 首，用户要求 \(targetCount) 首；未创建歌单，未执行任何修改。")
                }
                // 用户要求 N 首 → 去重后只取前 N 首；模型提交超量时硬约束。
                selectedTrackIDs = ids.count > targetCount ? Array(ids.prefix(targetCount)) : ids
            } else {
                selectedTrackIDs = ids
            }
            verificationOffset = 0
            verifiedTrackIDs = []
            if createdPlaylistID != nil {
                transition(to: .addingTracks)
            } else {
                transition(to: .creatingPlaylist)
            }
            return .none
        case "playlist_create", "createPlaylist":
            playlistCreated = true
            // Structured cards are the canonical create result; legacy text is
            // only a compatibility fallback.
            createdPlaylistID = Self.extractPlaylistID(from: result.payload, fallback: result.summary)
            transition(to: .addingTracks)
            return .none
        case "playlist_add_songs", "addTracksToPlaylist":
            tracksAdded = true
            verificationOffset = 0
            verifiedTrackIDs = []
            transition(to: .verifyingPlaylist)
            return .none
        case "library_get_playlist", "getPlaylist":
            // 目标状态确认支持分页：每一页都并入已核验集合，只有所有提交的
            // ID 都出现后才完成；若仍缺失且服务端明确有下一页，则继续读取。
            guard case let .playlistProposal(_, tracks) = result.payload else {
                return .fail("歌单验证失败：验证结果格式无效（\(result.summary)）。")
            }
            verifiedTrackIDs.formUnion(tracks.map(\.globalID.description))
            let missing = selectedTrackIDs.filter { !verifiedTrackIDs.contains($0) }
            if missing.isEmpty {
                transition(to: .completed)
                return .none
            }
            guard result.facts["playlist.hasMore"] == "true" else {
                return .fail("歌单验证失败：有 \(missing.count) 首提交的歌曲未出现在歌单中。")
            }
            let nextOffset = Int(result.facts["playlist.nextOffset"] ?? "")
                ?? (verificationOffset + tracks.count)
            guard nextOffset > verificationOffset else {
                return .fail("歌单验证失败：分页验证没有推进（当前 offset=\(verificationOffset)）。")
            }
            verificationOffset = nextOffset
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
            createdPlaylist: playlistCreated,
            selectedTrackIDs: selectedTrackIDs.isEmpty ? nil : selectedTrackIDs,
            tracksAdded: tracksAdded,
            phase: phase.label,
            verificationOffset: verificationOffset,
            verifiedTrackIDs: verifiedTrackIDs.isEmpty ? nil : verifiedTrackIDs.sorted()
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
        if case let .playlistCards(cards)? = payload, let card = cards.first {
            return card.globalID.description
        }
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
