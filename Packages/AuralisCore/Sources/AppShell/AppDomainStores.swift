import Application
import Combine
import Domain
import Foundation
import LocalCatalog
import OfflineManager

/// 首页领域状态与投影任务。大曲库快照在这里计算和取消，AppModel 只负责提供事实快照。
@MainActor
final class HomeStore: ObservableObject {
    @Published private(set) var layout: HomeLayoutPreference
    @Published private(set) var randomTracks: [Track] = []
    @Published private(set) var favorites: [Track] = []
    @Published private(set) var mostPlayed: [Track] = []
    @Published private(set) var recentlyPlayed: [Track] = []
    @Published private(set) var recentlyAdded: [Track] = []
    @Published private(set) var longUnplayed: [Track] = []
    @Published private(set) var neverPlayed: [Track] = []
    @Published private(set) var favoriteRandom: [Track] = []
    @Published private(set) var recentlyAdded30Days: [Track] = []
    @Published private(set) var topArtists: [Artist] = []
    @Published private(set) var topAlbums: [Album] = []
    @Published private(set) var artistPlayCounts: [ArtistID: Int] = [:]
    @Published private(set) var albumPlayCounts: [AlbumID: Int] = [:]

    private let defaults: UserDefaults
    private var snapshotTask: Task<Void, Never>?
    private var snapshotGeneration = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.layout = HomeLayoutStore.load(from: defaults)
    }

    deinit { snapshotTask?.cancel() }

    func setModuleVisible(_ moduleID: String, isVisible: Bool) {
        var updated = layout
        func update(keyPath: WritableKeyPath<HomeLayoutPreference, [HomeModulePreference]>) {
            guard let index = updated[keyPath: keyPath].firstIndex(where: { $0.moduleID == moduleID }) else { return }
            updated[keyPath: keyPath][index].isVisible = isVisible
        }
        if HomeModuleRegistry.modules(in: .quickEntry).contains(where: { $0.id.rawValue == moduleID }) {
            update(keyPath: \.quickEntries)
        } else {
            update(keyPath: \.contentModules)
        }
        replaceLayout(updated)
    }

    func moveModule(in group: HomeModuleGroup, fromOffsets: IndexSet, toOffset: Int) {
        var updated = layout
        switch group {
        case .quickEntry:
            updated.quickEntries = Self.moving(updated.quickEntries, fromOffsets: fromOffsets, toOffset: toOffset)
        case .content:
            updated.contentModules = Self.moving(updated.contentModules, fromOffsets: fromOffsets, toOffset: toOffset)
        }
        replaceLayout(updated)
    }

    func replaceLayout(quickEntries: [HomeModulePreference], contentModules: [HomeModulePreference]) {
        replaceLayout(HomeLayoutPreference(quickEntries: quickEntries, contentModules: contentModules))
    }

    func resetLayout() {
        replaceLayout(HomeModuleRegistry.defaultPreference())
    }

    func regenerateRandom(from tracks: [Track], dislikedTrackIDs: Set<GlobalID> = []) {
        randomTracks = Array(tracks
            .filter { track in
                !dislikedTrackIDs.contains(GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
            }
            .shuffled().prefix(18))
    }

    func regenerateFavoriteRandom(from tracks: [Track], dislikedTrackIDs: Set<GlobalID> = []) {
        favoriteRandom = Array(tracks
            .filter { track in
                track.isFavorite && !dislikedTrackIDs.contains(GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
            }
            .shuffled().prefix(18))
    }

    func refresh(
        catalog: LibraryCatalog,
        playCounts: [TrackID: Int],
        recentIDs: [TrackID],
        addedDates: [GlobalID: Date],
        dislikedTrackIDs: Set<GlobalID> = []
    ) {
        // 从本地缓存恢复资料库时不会经过网络同步的 `regenerateRandom`。
        // 此处只在初始快照为空时补齐，既恢复首页“随机音乐 / 随机播放”入口，
        // 也不会在播放记录、收藏等普通快照刷新时让货架无故换一批。
        if randomTracks.isEmpty, !catalog.tracks.isEmpty {
            regenerateRandom(from: catalog.tracks, dislikedTrackIDs: dislikedTrackIDs)
        }

        guard catalog.tracks.count >= 2_000 else {
            apply(HomeSnapshotBuilder.build(
                catalog: catalog,
                playCounts: playCounts,
                recentIDs: recentIDs,
                addedDates: addedDates,
                dislikedTrackIDs: dislikedTrackIDs
            ))
            return
        }

        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                HomeSnapshotBuilder.build(
                    catalog: catalog,
                    playCounts: playCounts,
                    recentIDs: recentIDs,
                    addedDates: addedDates,
                    dislikedTrackIDs: dislikedTrackIDs
                )
            }.value
            guard !Task.isCancelled, let self, self.snapshotGeneration == generation else { return }
            self.apply(snapshot)
        }
    }

    private func replaceLayout(_ updated: HomeLayoutPreference) {
        layout = updated
        HomeLayoutStore.save(updated, to: defaults)
    }

    private func apply(_ snapshot: HomeSnapshot) {
        favorites = snapshot.favorites
        mostPlayed = snapshot.mostPlayed
        recentlyPlayed = snapshot.recentlyPlayed
        recentlyAdded = snapshot.recentlyAdded
        longUnplayed = snapshot.longUnplayed
        neverPlayed = snapshot.neverPlayed
        recentlyAdded30Days = snapshot.recentlyAdded30Days
        favoriteRandom = snapshot.favoriteRandom
        topArtists = snapshot.topArtists
        topAlbums = snapshot.topAlbums
        artistPlayCounts = snapshot.artistPlayCounts
        albumPlayCounts = snapshot.albumPlayCounts
    }

    private static func moving<T>(_ input: [T], fromOffsets: IndexSet, toOffset: Int) -> [T] {
        var result = input
        let moving = fromOffsets.sorted()
        let removed: [T] = moving.reversed().map { result.remove(at: $0) }
        let removedBeforeTarget = moving.filter { $0 < toOffset }.count
        let target = max(0, min(toOffset - removedBeforeTarget, result.count))
        result.insert(contentsOf: removed.reversed(), at: target)
        return result
    }
}

/// 本地目录与浏览页的可观察状态。同步器仍负责事实写入，Store 只承接 UI 投影。
@MainActor
final class LibraryStore: ObservableObject {
    @Published var catalog: LibraryCatalog {
        didSet { trackByGlobalID = Self.makeTrackIndex(catalog.tracks) }
    }
    /// 浏览页、歌单和上下文菜单均以 GlobalID 解析歌曲，避免 M×N 扫描与跨服务器同 ID 串库。
    private(set) var trackByGlobalID: [GlobalID: Track]
    @Published var playlistTracks: [PlaylistID: [Track]] = [:]
    @Published var loadingPlaylistIDs: Set<PlaylistID> = []
    @Published var playlistDeletionError: String?
    @Published var genreTracks: [Track]?
    @Published var loadingGenre: Genre?

    init(catalog: LibraryCatalog) {
        self.catalog = catalog
        self.trackByGlobalID = Self.makeTrackIndex(catalog.tracks)
    }

    func track(for globalID: GlobalID) -> Track? { trackByGlobalID[globalID] }

    private static func makeTrackIndex(_ tracks: [Track]) -> [GlobalID: Track] {
        var index: [GlobalID: Track] = [:]
        for track in tracks {
            index[GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)] = track
        }
        return index
    }
}

/// 服务器连接生命周期状态。凭据仍只由 connector / Keychain 持有。
@MainActor
final class ServerStore: ObservableObject {
    @Published var connectionState: ServerConnectionViewState = .idle
    @Published var authenticationFailed = false
    @Published var capabilities = ServerCapabilities()
}

/// 下载生命周期与缓存身份。所有状态键使用 GlobalID，避免跨服务器串库。
@MainActor
final class DownloadStore: ObservableObject {
    @Published private(set) var downloadedTrackIDs: Set<GlobalID> = []
    @Published private(set) var downloadingTrackIDs: Set<GlobalID> = []
    @Published private(set) var progress: [GlobalID: Double] = [:]

    private let connector: any ServerConnecting
    private let cacheStore: TrackCacheStore
    private let manager: DownloadManager

    init(connector: any ServerConnecting, cacheStore: TrackCacheStore) {
        self.connector = connector
        self.cacheStore = cacheStore
        self.manager = DownloadManager(store: cacheStore)
        manager.onStateChange = { [weak self] taskID, status, progress in
            Task { @MainActor [weak self] in
                self?.handle(taskID: taskID, status: status, progress: progress)
            }
        }
        restoreActiveDownloads()
    }

    private func restoreActiveDownloads() {
        for snapshot in manager.activeSnapshots() {
            let globalID = GlobalID(
                serverID: snapshot.serverID,
                remoteID: snapshot.info.trackID.rawValue
            )
            downloadingTrackIDs.insert(globalID)
            progress[globalID] = snapshot.info.progress
        }
    }

    func restoreCachedIDs() async {
        downloadedTrackIDs = Set(await cacheStore.cachedTrackIDs().map {
            GlobalID(serverID: $0.serverID, remoteID: $0.trackID.rawValue)
        })
    }

    func isDownloaded(_ track: Track) -> Bool { downloadedTrackIDs.contains(globalID(for: track)) }
    func isDownloading(_ track: Track) -> Bool { downloadingTrackIDs.contains(globalID(for: track)) }

    func allCachedTrackIDs() async -> Set<GlobalID> {
        Set(await cacheStore.cachedTrackIDs().map {
            GlobalID(serverID: $0.serverID, remoteID: $0.trackID.rawValue)
        })
    }

    func download(_ track: Track) {
        let globalID = globalID(for: track)
        guard !downloadedTrackIDs.contains(globalID), !downloadingTrackIDs.contains(globalID) else { return }
        Task { @MainActor [weak self] in
            guard let self, let url = await connector.downloadURL(trackID: track.id) else { return }
            let taskID = DownloadTaskID(serverID: track.serverID, trackID: track.id)
            guard !manager.isDownloading(taskID) else { return }
            downloadingTrackIDs.insert(globalID)
            progress[globalID] = 0
            manager.start(
                trackID: track.id,
                url: url,
                codec: track.sourceInfo.codec,
                serverID: track.serverID
            )
        }
    }

    func cancel(_ track: Track) {
        let globalID = globalID(for: track)
        manager.cancel(DownloadTaskID(serverID: track.serverID, trackID: track.id))
        downloadingTrackIDs.remove(globalID)
        progress[globalID] = nil
    }

    func remove(_ track: Track) async {
        try? await cacheStore.remove(for: cacheID(for: track))
        downloadedTrackIDs.remove(globalID(for: track))
    }

    func removeAll() async {
        for globalID in downloadedTrackIDs {
            try? await cacheStore.remove(for: TrackCacheStore.TrackCacheID(
                serverID: globalID.serverID,
                trackID: TrackID(rawValue: globalID.remoteID)
            ))
        }
        downloadedTrackIDs = []
    }

    func clearVisibleState() {
        downloadedTrackIDs = []
        downloadingTrackIDs = []
        progress = [:]
    }

    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        manager.handleEventsForBackgroundURLSession(identifier: identifier, completion: completion)
    }

    private func handle(taskID: DownloadTaskID, status: DownloadStatus, progress value: Double) {
        let globalID = GlobalID(serverID: taskID.serverID, remoteID: taskID.trackID.rawValue)
        switch status {
        case .downloading:
            downloadingTrackIDs.insert(globalID)
            progress[globalID] = value
        case .downloaded:
            downloadingTrackIDs.remove(globalID)
            progress[globalID] = nil
            downloadedTrackIDs.insert(globalID)
        case .failed, .notDownloaded:
            downloadingTrackIDs.remove(globalID)
            progress[globalID] = nil
        case .queued:
            break
        }
    }

    private func globalID(for track: Track) -> GlobalID {
        GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
    }

    private func cacheID(for track: Track) -> TrackCacheStore.TrackCacheID {
        TrackCacheStore.TrackCacheID(serverID: track.serverID, trackID: track.id)
    }
}
