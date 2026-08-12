import Domain
import Foundation
import LocalCatalog

/// 工具结果对 UI 的展示角色（确定性，由 Tool 执行/Descriptor 声明，不由模型决定）。
///
/// - `none`: 不进入任何展示状态（纯内部查询 / 副作用 / 失败）。
/// - `candidate`: 中间候选，只进入内部候选池，绝不上屏。
/// - `finalResult`: 最终结果，直接成为最终展示（例如 `result_present_tracks`）。
/// - `disambiguation`: 需要用户选择的歧义候选（“找到多个匹配，请选择：”）。
public enum ToolPresentationRole: String, Codable, Sendable, Hashable {
    case none
    case candidate
    case finalResult
    case disambiguation
}

/// 任务级展示状态：把「内部候选池」与「最终向用户展示的内容」彻底分离。
///
/// 候选池是给模型用的（回灌上下文、筛选、建队列），永远不直接上屏；
/// 最终展示只能来自三类确定性来源：
/// 1. `result_present_tracks`（纯推荐任务的明确 Final Selection）；
/// 2. 真实副作用（queue_replace / playlist_add_songs 等成功后的实际入队/入歌单 ID）；
/// 3. 搜索/专辑类任务的收尾合并（intent == librarySearch，或只有专辑候选时）。
public struct AgentPresentationState: Sendable {
    /// 内部候选池：GlobalID → TrackCard（保序字典，用数组维护顺序）。
    public private(set) var candidateTracks: [GlobalID: TrackCard] = [:]
    /// 候选首次出现顺序。
    public private(set) var candidateOrder: [GlobalID] = []
    /// 内部专辑候选（保序）。
    public private(set) var candidateAlbums: [AlbumCard] = []
    /// 最终向用户展示的歌曲（有序，保持模型/副作用给定顺序）。
    public private(set) var finalTrackIDs: [GlobalID] = []
    /// 最终专辑（有序）。
    public private(set) var finalAlbums: [AlbumCard] = []
    /// 最终歌单内容查看（library_get_playlist 等：只有没有其它最终内容时才展示）。
    public private(set) var finalPlaylistProposal: (name: String, tracks: [TrackCard])?
    /// 需要用户选择的歧义候选（有序）。
    public private(set) var disambiguationTracks: [TrackCard] = []
    /// 是否已通过 result_present_tracks 或真实副作用确定最终集合。
    public private(set) var hasExplicitFinal = false

    public init() {}

    // MARK: - 候选池（内部）

    public mutating func addCandidateTracks(_ cards: [TrackCard]) {
        for card in cards {
            if candidateTracks[card.globalID] == nil {
                candidateOrder.append(card.globalID)
            }
            candidateTracks[card.globalID] = card
        }
    }

    public mutating func addCandidateAlbums(_ albums: [AlbumCard]) {
        for album in albums where !candidateAlbums.contains(where: { $0.globalID == album.globalID }) {
            candidateAlbums.append(album)
        }
    }

    // MARK: - 最终结果

    /// 明确设置最终歌曲（有序、去重）。同时登记 `selectedIDs` 语义。
    public mutating func setFinalTracks(_ cards: [TrackCard]) {
        var ids: [GlobalID] = []
        var seen = Set<GlobalID>()
        for card in cards where seen.insert(card.globalID).inserted {
            ids.append(card.globalID)
            candidateTracks[card.globalID] = card
        }
        finalTrackIDs = ids
        hasExplicitFinal = true
    }

    public mutating func setFinalAlbums(_ albums: [AlbumCard]) {
        finalAlbums = albums
        hasExplicitFinal = true
    }

    public mutating func setDisambiguation(_ cards: [TrackCard]) {
        disambiguationTracks = cards
    }

    public mutating func setFinalPlaylistProposal(_ name: String, _ tracks: [TrackCard]) {
        finalPlaylistProposal = (name, tracks)
    }

    /// 由实际入队/入歌单的 ID 建立最终歌曲（保序）。
    /// `append` 为 true 时合并进已有最终集合；否则替换。
    public mutating func applySideEffectTracks(_ ids: [GlobalID], append: Bool) {
        let resolved: [TrackCard] = ids.compactMap { candidateTracks[$0] }
        if append {
            setFinalTracks(finalTrackIDs.compactMap { candidateTracks[$0] } + resolved)
        } else {
            setFinalTracks(resolved)
        }
    }

    /// 搜索任务收尾合并：把内部候选按首次出现顺序作为最终结果（一组）。
    public mutating func applySearchFallback() {
        guard !hasExplicitFinal, !candidateOrder.isEmpty else { return }
        finalTrackIDs = candidateOrder
    }

    /// 专辑候选收尾合并：只有专辑候选、没有最终歌曲时，把候选专辑作为最终结果（一组）。
    public mutating func applyAlbumFallbackIfNeeded() {
        guard !hasExplicitFinal, finalTrackIDs.isEmpty, !candidateAlbums.isEmpty else { return }
        finalAlbums = candidateAlbums
    }

    /// 由最终 ID 解析出的有序卡片（供 emit）。
    public var resolvedFinalCards: [TrackCard] {
        finalTrackIDs.compactMap { candidateTracks[$0] }
    }

    /// 最终展示消息（最多一个）：歌曲 → 专辑 → 歧义 → 歌单内容。
    public func finalMessage() -> AgentMessage? {
        if !resolvedFinalCards.isEmpty {
            return .trackCards(resolvedFinalCards)
        }
        if !finalAlbums.isEmpty {
            return .albumCards(finalAlbums)
        }
        if !disambiguationTracks.isEmpty {
            return .trackCards(disambiguationTracks)
        }
        if let proposal = finalPlaylistProposal {
            return .playlistProposal(name: proposal.name, tracks: proposal.tracks)
        }
        return nil
    }
}
