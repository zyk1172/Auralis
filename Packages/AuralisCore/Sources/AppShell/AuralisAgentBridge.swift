import AgentKit
import Application
import Domain
import Foundation
import LocalCatalog

/// 把 AgentKit 的工具调用落到真实播放器与服务器上。
///
/// 安全边界：
/// - 服务器凭据永不经过这里（addServer / updateServer 的 token 参数一律忽略，
///   凭据只能由原生表单写入 Keychain）。
/// - 删除服务器只清理本地目录与缓存，不会对 NAS / 远端做任何删除。
@MainActor
public final class AuralisAgentBridge: AgentBridge {
    private unowned let model: AuralisAppModel
    private let catalog: LocalCatalogStore
    private let coordinator: CatalogCoordinator

    public init(model: AuralisAppModel, coordinator: CatalogCoordinator) {
        self.model = model
        self.coordinator = coordinator
        self.catalog = coordinator.store
    }

    // MARK: - Context

    public var activeServerID: ServerID? {
        get async { model.catalog.activeServerID }
    }

    public func currentTrack() async -> Track? {
        model.currentTrack.id.rawValue == "placeholder" ? nil : model.currentTrack
    }

    public func currentQueue() async -> [Track] { model.queue }

    public func lyricsState(for globalID: GlobalID) async -> AgentLyricsState {
        model.lyricsAvailability(for: globalID)
    }

    // MARK: - Playback

    public func playTrack(globalID: GlobalID) async -> Bool {
        guard let track = resolveTrack(globalID) else { return false }
        model.selectAndPlay(track)
        return true
    }

    /// 服务器曲目在线流播回退：本地目录还没有这首歌时，按服务器 ID 拉取（getSong + 补流地址）
    /// 后直接流式播放，不要求先下载/同步。播放是服务器在线流媒体，本地目录只是离线缓存。
    public func playServerTrack(globalID: GlobalID) async -> Bool {
        guard let active = model.catalog.activeServerID, active == globalID.serverID else { return false }
        guard let track = await coordinator.serverTrack(serverID: globalID.serverID, id: TrackID(rawValue: globalID.remoteID)) else { return false }
        model.selectAndPlay(track)
        return true
    }

    public func playAlbum(globalID: GlobalID) async -> Bool {
        let tracks = model.catalog.tracks.filter { $0.albumID.rawValue == globalID.remoteID }
        guard !tracks.isEmpty else { return false }
        model.queue = tracks
        model.selectAndPlay(tracks[0])
        return true
    }

    public func playPlaylist(globalID: GlobalID) async -> Bool {
        guard let playlist = model.catalog.playlists.first(where: { $0.id.rawValue == globalID.remoteID }) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: model.catalog.tracks.map { ($0.id, $0) })
        let tracks = playlist.trackIDs.compactMap { byID[$0] }
        guard !tracks.isEmpty else { return false }
        model.queue = tracks
        model.selectAndPlay(tracks[0])
        return true
    }

    public func playRandom() async {
        let tracks = Array(model.catalog.tracks.shuffled().prefix(30))
        guard !tracks.isEmpty else { return }
        model.queue = tracks
        model.selectAndPlay(tracks[0])
    }

    public func pause() async { model.pausePlayback() }
    public func resume() async { model.resumePlayback() }
    public func setShuffle(_ enabled: Bool) async { model.setShuffle(enabled) }
    public func setRepeatMode(_ mode: RepeatMode) async { model.setRepeatMode(mode) }
    public func setPlaybackRate(_ rate: Float) async { model.setPlaybackRate(rate) }

    public func setSleepTimer(mode: String, minutes: TimeInterval) async {
        let normalized = mode.lowercased()
        let resolved: AuralisAppModel.SleepTimerMode
        switch normalized {
        case "off", "关闭": resolved = .off
        case "aftercurrenttrack", "当前歌曲", "单曲": resolved = .afterCurrentTrack
        case "aftercurrentalbum", "当前专辑", "专辑": resolved = .afterCurrentAlbum
        case "aftercurrentqueue", "当前队列", "队列": resolved = .afterCurrentQueue
        default: resolved = .afterMinutes
        }
        model.setSleepTimer(mode: resolved, minutes: minutes)
    }

    public func cancelSleepTimer() async { model.cancelSleepTimer() }

    public func getSleepTimer() async -> (mode: String, remaining: TimeInterval) {
        let status = model.sleepTimerStatus()
        return (status.mode.rawValue, status.remaining)
    }

    public func seek(seconds: TimeInterval) async {
        guard model.effectivePlaybackDuration > 0 else { return }
        model.seek(toProgress: seconds / model.effectivePlaybackDuration)
    }

    public func next() async { model.next() }
    public func previous() async { model.previous() }

    public func addToQueue(globalID: GlobalID) async -> AgentMutationResult {
        // R05：允许重复歌曲（每次独立队列项）；走 queueStore.append 直调，
        // 不触发 queue [Track] setter 重建 entry UUID——重复队列中当前项
        // （如 [A,B,A,C] 的第二个 A）不会因追加 D 而漂回第一个 A。
        guard let track = resolveTrack(globalID) else { return .failed("歌曲不存在，未加入队列") }
        model.appendToQueue(track)
        return .confirmed("已加入队列")
    }

    public func playNext(globalID: GlobalID) async -> AgentMutationResult {
        guard resolveTrack(globalID) != nil else { return .failed("歌曲不存在，未插入队列") }
        model.playNext(globalID: globalID)
        return .confirmed("已插入到当前歌曲之后")
    }

    public func replaceQueue(globalIDs: [GlobalID]) async -> AgentMutationResult {
        let tracks = globalIDs.compactMap { resolveTrack($0) }
        guard !tracks.isEmpty, tracks.count == globalIDs.count else { return .failed("部分歌曲不存在，未替换队列") }
        model.queue = tracks
        model.selectAndPlay(tracks[0])
        return .confirmed("已替换队列（\(tracks.count) 首）")
    }

    public func removeFromQueue(at index: Int) async -> AgentMutationResult {
        guard model.queueEntries.indices.contains(index) else { return .failed("队列下标无效，未移除") }
        let entryID = model.queueEntries[index].id
        model.queueEntries.removeAll { $0.id == entryID }
        return .confirmed("已移除队列第 \(index) 项")
    }

    public func reorderQueue(from: Int, to: Int) async -> AgentMutationResult {
        guard model.queueEntries.indices.contains(from), model.queueEntries.indices.contains(to) else { return .failed("队列下标无效，未调整顺序") }
        let entry = model.queueEntries.remove(at: from)
        model.queueEntries.insert(entry, at: min(to, model.queueEntries.count))
        return .confirmed("已调整队列顺序")
    }

    public func clearQueue() async -> AgentMutationResult {
        model.queue = []
        return .confirmed("已清空队列")
    }

    public func shuffleRemaining() async -> AgentMutationResult {
        guard model.queueEntries.count > 1 else { return .failed("队列歌曲不足，无需随机") }
        model.shuffleRemainingInQueue()
        return .confirmed("已随机剩余队列")
    }

    public func saveQueueAsPlaylist(name: String) async -> Bool {
        await model.saveQueueAsPlaylist(named: name)
    }

    // MARK: - Playlist

    public func createPlaylist(name: String) async -> GlobalID? {
        guard let serverID = model.catalog.activeServerID else { return nil }
        guard let playlist = await model.createPlaylist(named: name) else { return nil }
        return GlobalID(serverID: serverID, remoteID: playlist.id.rawValue)
    }

    public func renamePlaylist(globalID: GlobalID, name: String) async -> AgentMutationResult {
        await model.renamePlaylist(id: PlaylistID(rawValue: globalID.remoteID), to: name)
            ? .confirmed("已重命名")
            : .failed("歌单不存在或服务器未确认重命名")
    }

    public func addTracksToPlaylist(playlistGID: GlobalID, trackGIDs: [GlobalID]) async -> Bool {
        guard let playlist = await playlistValue(playlistGID) else { return false }
        var added = 0
        for gid in trackGIDs {
            guard let track = await resolveTrackAnywhere(gid) else { continue }
            if await model.addToPlaylist(playlist, track: track) { added += 1 }
        }
        return added > 0
    }

    public func removeTracksFromPlaylist(playlistGID: GlobalID, atIndices: [Int]) async -> AgentMutationResult {
        await model.removeFromPlaylist(id: PlaylistID(rawValue: playlistGID.remoteID), atIndices: atIndices)
            ? .confirmed("已移除 \(atIndices.count) 首")
            : .failed("歌单不存在、只读或服务器未确认移除")
    }

    public func reorderPlaylist(playlistGID: GlobalID, from: Int, to: Int) async -> AgentMutationResult {
        await model.reorderPlaylist(id: PlaylistID(rawValue: playlistGID.remoteID), from: from, to: to)
            ? .confirmed("已调整顺序")
            : .failed("歌单下标无效、只读或服务器未确认调整")
    }

    public func duplicatePlaylist(playlistGID: GlobalID) async -> AgentMutationResult {
        guard let source = model.catalog.playlists.first(where: { $0.id.rawValue == playlistGID.remoteID }) else { return .failed("歌单不存在，未复制") }
        guard let copy = await model.createPlaylist(named: String(localized: "\(source.name) 副本", bundle: .module)) else { return .failed("服务器未确认创建歌单副本") }
        let byID = Dictionary(uniqueKeysWithValues: model.catalog.tracks.map { ($0.id, $0) })
        var added = 0
        for trackID in source.trackIDs {
            guard let track = byID[trackID] else { continue }
            if await model.addToPlaylist(copy, track: track) { added += 1 }
        }
        guard added == source.trackIDs.count else { return .failed("副本已创建但未完整复制歌曲") }
        return .confirmed("已复制歌单")
    }

    public func mergePlaylists(sourceGIDs: [GlobalID], into name: String) async -> AgentMutationResult {
        guard let target = await model.createPlaylist(named: name) else { return .failed("服务器未确认创建合并歌单") }
        var seen: Set<TrackID> = []
        var expected = 0
        var added = 0
        for gid in sourceGIDs {
            guard let source = model.catalog.playlists.first(where: { $0.id.rawValue == gid.remoteID }) else { return .failed("源歌单不存在，未完成合并") }
            for trackID in source.trackIDs where !seen.contains(trackID) {
                seen.insert(trackID)
                expected += 1
                guard let track = model.catalog.tracks.first(where: { $0.id == trackID }) else { continue }
                if await model.addToPlaylist(target, track: track) { added += 1 }
            }
        }
        guard expected == added else { return .failed("合并歌单未完整写入") }
        return .confirmed("已合并歌单")
    }

    public func deletePlaylist(globalID: GlobalID) async -> AgentMutationResult {
        await model.deletePlaylist(id: PlaylistID(rawValue: globalID.remoteID))
            ? .confirmed("已删除歌单")
            : .failed("歌单不存在、只读或服务器未确认删除")
    }

    // MARK: - Annotation

    public func likeTrack(globalID: GlobalID) async {
        guard let track = resolveTrack(globalID), !track.isFavorite else { return }
        model.toggleFavorite(track)
        try? await catalog.setFavorite(globalID, value: true)
    }

    public func unlikeTrack(globalID: GlobalID) async {
        guard let track = resolveTrack(globalID), track.isFavorite else { return }
        model.toggleFavorite(track)
        try? await catalog.setFavorite(globalID, value: false)
    }

    public func favoriteAlbum(globalID: GlobalID) async {
        await model.setAlbumFavorite(id: AlbumID(rawValue: globalID.remoteID), isFavorite: true)
    }

    public func unfavoriteAlbum(globalID: GlobalID) async {
        await model.setAlbumFavorite(id: AlbumID(rawValue: globalID.remoteID), isFavorite: false)
    }

    public func favoriteArtist(globalID: GlobalID) async {
        await model.setArtistFavorite(id: ArtistID(rawValue: globalID.remoteID), isFavorite: true)
    }

    public func unfavoriteArtist(globalID: GlobalID) async {
        await model.setArtistFavorite(id: ArtistID(rawValue: globalID.remoteID), isFavorite: false)
    }

    public func setRating(globalID: GlobalID, rating: Int) async {
        try? await catalog.setRating(globalID, rating: rating)
        await model.setRating(globalID: globalID, rating: rating)
    }

    public func clearRating(globalID: GlobalID) async {
        try? await catalog.clearRating(globalID)
        await model.setRating(globalID: globalID, rating: 0)
    }

    // MARK: - Server

    public func listServers() async -> [ServerAccount] {
        (try? await catalog.listServers()) ?? []
    }

    public func getActiveServer() async -> ServerAccount? { model.catalog.activeAccount }

    public func testServerConnection(serverID: ServerID) async -> Bool {
        await model.testServerConnection(serverID: serverID)
    }

    /// 出于安全考虑，Agent 不能凭模型输出添加服务器：凭据必须走原生表单。
    public func addServer(displayName: String, baseURL: String, username: String, token: String) async -> Bool {
        model.shouldPresentServerSetup = true
        return false
    }

    /// 同上：更新服务器凭据只能通过原生表单。
    public func updateServer(serverID: ServerID, displayName: String?, baseURL: String?, username: String?, token: String?) async -> Bool {
        model.shouldPresentServerSetup = true
        return false
    }

    public func switchServer(serverID: ServerID) async {
        await model.switchServer(serverID: serverID)
    }

    public func refreshLibrary() async {
        guard let serverID = model.catalog.activeServerID else { return }
        coordinator.manualRefresh(serverID: serverID)
    }

    public func getSyncStatus() async -> [CatalogSyncStatus] {
        await coordinator.refreshStatuses()
        return coordinator.statuses
    }

    /// 删除服务器：仅清理本地（目录 / 缓存 / 凭据），远端数据不受影响。
    public func removeServer(serverID: ServerID) async {
        await coordinator.purgeLocalData(serverID: serverID)
        await model.removeServerLocally(serverID: serverID)
    }

    /// 在服务器上在线搜索歌曲（HTTP）：本地没有时由 Agent 调用来获取服务器实时信息。
    public func serverSearch(query: String, limit: Int) async -> [Track] {
        await model.searchOnServerAwaiting(query: query, limit: limit)
    }

    // MARK: - Playlist / Track resolution

    /// 歌单解析：优先内存 catalog，未加载时从本地目录库（SQLite）按 GlobalID 还原。
    /// 修复「Agent 在歌单未进内存 catalog 时添加歌曲静默失败」的问题。
    private func playlistValue(_ gid: GlobalID) async -> Playlist? {
        if let existing = model.catalog.playlists.first(where: { $0.id.rawValue == gid.remoteID }) {
            return existing
        }
        guard let summary = (try? await catalog.listPlaylists())?.first(where: { $0.globalID == gid }) else {
            return nil
        }
        return Playlist(
            id: PlaylistID(rawValue: gid.remoteID),
            serverID: gid.serverID,
            name: summary.name,
            trackIDs: summary.trackIDs.map { TrackID(rawValue: $0.remoteID) }
        )
    }

    /// 曲目解析：先内存 catalog，未命中再从本地目录库按 GlobalID 取（Agent 查询到的曲目）。
    /// 必须同时匹配 serverID 与 remoteID，禁止退化成 TrackID 查找。
    private func resolveTrackAnywhere(_ globalID: GlobalID) async -> Track? {
        if let track = model.catalog.tracks.first(where: {
            $0.serverID == globalID.serverID && $0.id.rawValue == globalID.remoteID
        }) {
            return track
        }
        return try? await catalog.getTrack(globalID)
    }

    // MARK: - Resolution

    /// GlobalID → 内存 catalog 中的 Track。多服务器隔离：serverID 必须精确匹配。
    private func resolveTrack(_ globalID: GlobalID) -> Track? {
        model.catalog.tracks.first {
            $0.serverID == globalID.serverID && $0.id.rawValue == globalID.remoteID
        }
    }
}
