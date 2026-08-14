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
        guard let track = await coordinator.serverTrack(id: TrackID(rawValue: globalID.remoteID)) else { return false }
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
        let ids = Set(playlist.trackIDs)
        let tracks = model.catalog.tracks.filter { ids.contains($0.id) }
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
        guard model.currentTrack.duration > 0 else { return }
        model.seek(toProgress: seconds / model.currentTrack.duration)
    }

    public func next() async { model.next() }
    public func previous() async { model.previous() }

    public func addToQueue(globalID: GlobalID) async {
        guard let track = resolveTrack(globalID),
              !model.queue.contains(where: { $0.id == track.id }) else { return }
        model.queue.append(track)
    }

    public func playNext(globalID: GlobalID) async {
        guard let track = resolveTrack(globalID) else { return }
        model.queue.removeAll { $0.id == track.id }
        if let index = model.queue.firstIndex(where: { $0.id == model.currentTrack.id }) {
            model.queue.insert(track, at: index + 1)
        } else {
            model.queue.insert(track, at: 0)
        }
    }

    public func replaceQueue(globalIDs: [GlobalID]) async {
        let tracks = globalIDs.compactMap { resolveTrack($0) }
        guard !tracks.isEmpty else { return }
        model.queue = tracks
        model.selectAndPlay(tracks[0])
    }

    public func removeFromQueue(at index: Int) async {
        guard model.queue.indices.contains(index) else { return }
        model.removeFromQueue(model.queue[index])
    }

    public func reorderQueue(from: Int, to: Int) async {
        guard model.queue.indices.contains(from), model.queue.indices.contains(to) else { return }
        let track = model.queue.remove(at: from)
        model.queue.insert(track, at: min(to, model.queue.count))
    }

    public func clearQueue() async {
        for track in model.queue { model.removeFromQueue(track) }
    }

    public func shuffleRemaining() async {
        model.shuffleRemainingInQueue()
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

    public func renamePlaylist(globalID: GlobalID, name: String) async {
        await model.renamePlaylist(id: PlaylistID(rawValue: globalID.remoteID), to: name)
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

    public func removeTracksFromPlaylist(playlistGID: GlobalID, atIndices: [Int]) async {
        await model.removeFromPlaylist(id: PlaylistID(rawValue: playlistGID.remoteID), atIndices: atIndices)
    }

    public func reorderPlaylist(playlistGID: GlobalID, from: Int, to: Int) async {
        await model.reorderPlaylist(id: PlaylistID(rawValue: playlistGID.remoteID), from: from, to: to)
    }

    public func duplicatePlaylist(playlistGID: GlobalID) async {
        guard let source = model.catalog.playlists.first(where: { $0.id.rawValue == playlistGID.remoteID }) else { return }
        guard let copy = await model.createPlaylist(named: "\(source.name) 副本") else { return }
        let ids = Set(source.trackIDs)
        for track in model.catalog.tracks where ids.contains(track.id) {
            await model.addToPlaylist(copy, track: track)
        }
    }

    public func mergePlaylists(sourceGIDs: [GlobalID], into name: String) async {
        guard let target = await model.createPlaylist(named: name) else { return }
        var seen: Set<TrackID> = []
        for gid in sourceGIDs {
            guard let source = model.catalog.playlists.first(where: { $0.id.rawValue == gid.remoteID }) else { continue }
            for trackID in source.trackIDs where !seen.contains(trackID) {
                seen.insert(trackID)
                guard let track = model.catalog.tracks.first(where: { $0.id == trackID }) else { continue }
                await model.addToPlaylist(target, track: track)
            }
        }
    }

    public func deletePlaylist(globalID: GlobalID) async {
        _ = await model.deletePlaylist(id: PlaylistID(rawValue: globalID.remoteID))
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
        await model.setRating(trackID: TrackID(rawValue: globalID.remoteID), rating: rating)
    }

    public func clearRating(globalID: GlobalID) async {
        try? await catalog.clearRating(globalID)
        await model.setRating(trackID: TrackID(rawValue: globalID.remoteID), rating: 0)
    }

    // MARK: - Server

    public func listServers() async -> [ServerAccount] {
        (try? await catalog.listServers()) ?? []
    }

    public func getActiveServer() async -> ServerAccount? { model.catalog.activeAccount }

    public func testServerConnection(serverID: ServerID) async -> Bool {
        await model.testActiveServerConnection()
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
