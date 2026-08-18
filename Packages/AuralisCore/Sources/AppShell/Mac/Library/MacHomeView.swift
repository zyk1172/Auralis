#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

private struct MacHomeTrackItem: Identifiable {
    let track: Track
    var id: GlobalID { GlobalID(serverID: track.serverID, remoteID: track.id.rawValue) }
}

/// 首页：只展示真实有数据的货架（全部为网格卡片）。
/// 最近播放/最近添加按 Album 投影去重；收藏歌曲/播放列表等资料库入口由侧边栏负责。
struct MacHomeView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }
    @State private var isEditingLayout = false

    var body: some View {
        // GeometryReader 必须在 ScrollView 外层：放在可滚动内容中会收到不确定的高度提议，
        // 从而把每个横向 shelf 压成一条窄带，封面不能按正方形展开。
        GeometryReader { geo in
            let homeMetrics = MacArtworkGridMetrics.home(availableWidth: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(visibleContentModules) { module in
                        homeModule(module, metrics: homeMetrics)
                    }
                }
                .padding(.horizontal, homeMetrics.horizontalPadding)
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑首页", systemImage: "slider.horizontal.3") {
                    isEditingLayout = true
                }
            }
        }
        .sheet(isPresented: $isEditingLayout) {
            // Mac 专用首页编辑器：只编辑内容模块（quickEntries 在 Mac 首页不显示），
            // 固定 560×600，不再复用 iOS HomeLayoutEditView。
            MacHomeLayoutEditor(model: model, theme: theme)
        }
    }

    /// 首页货架标题（有序）。资料库入口（歌曲/专辑/艺术家/流派/下载/不喜欢/播放列表/收藏）
    /// 由侧边栏负责，首页只保留“适合首页”的音乐内容卡片货架。供测试校验栏目切割。
    static let shelfTitles: [String] = HomeModuleRegistry.modules(in: .content).map(\.title)

    /// 首页不得包含这些（已由侧边栏资料库/播放列表区承担）。
    static let sidebarOnlyTitles: Set<String> = [
        "歌曲", "专辑", "艺术家", "流派", "下载", "不喜欢", "播放列表", "收藏",
    ]

    /// 按用户持久化的顺序和显示开关驱动 Mac 首页；无数据的模块不占空白。
    private var visibleContentModules: [HomeModule] {
        let available = Set(HomeModuleID.allCases.filter { moduleHasData($0) })
        return Self.renderedContentModuleIDs(
            preferences: model.homeLayout.contentModules,
            available: available
        )
        .compactMap(HomeModuleRegistry.module(forID:))
    }

    /// 将持久化偏好与本次可用数据分离，方便验证「隐藏」与「暂时无数据」不会混淆。
    nonisolated static func renderedContentModuleIDs(
        preferences: [HomeModulePreference],
        available: Set<HomeModuleID>
    ) -> [String] {
        preferences.compactMap { preference in
            guard preference.isVisible,
                  let id = HomeModuleID(rawValue: preference.moduleID),
                  available.contains(id)
            else { return nil }
            return preference.moduleID
        }
    }

    private func moduleHasData(_ id: HomeModuleID) -> Bool {
        switch id {
        case .random: !model.randomTracks.isEmpty
        case .recentlyPlayed: !recentAlbums.isEmpty
        case .recentlyAdded: !recentAddedAlbums.isEmpty
        case .longUnplayed: !model.homeLongUnplayedTracks.isEmpty
        case .favoriteRandom: !model.homeFavoriteRandomTracks.isEmpty
        case .neverPlayed: !model.homeNeverPlayedTracks.isEmpty
        case .topArtists: !model.homeTopArtists.isEmpty
        case .topAlbums: !model.homeTopAlbums.isEmpty
        default: false
        }
    }

    // MARK: - Album 投影（去重封面）

    private var recentAlbums: [Album] {
        albumProjection(from: model.homeRecentlyPlayedTracks)
    }

    private var recentAddedAlbums: [Album] {
        albumProjection(from: model.homeRecentlyAdded30DaysTracks)
    }

    /// 曲目 → 按 (serverID, albumID) 去重 → 最新出现顺序的专辑。
    private func albumProjection(from tracks: [Track]) -> [Album] {
        var seen = Set<AlbumRouteIdentity>()
        var result: [Album] = []
        for track in tracks {
            let id = AlbumRouteIdentity(serverID: track.serverID, remoteID: track.albumID.rawValue)
            if seen.insert(id).inserted,
               let album = model.catalog.albums.first(where: { $0.serverID == track.serverID && $0.id == track.albumID }) {
                result.append(album)
                if result.count >= 14 { break }
            }
        }
        return result
    }

    /// 曲目货架去重（每专辑只保留第一首，避免同一封面反复出现）。
    private func deduped(_ tracks: [Track]) -> [Track] {
        var seen = Set<AlbumRouteIdentity>()
        var result: [Track] = []
        for track in tracks {
            let id = AlbumRouteIdentity(serverID: track.serverID, remoteID: track.albumID.rawValue)
            if seen.insert(id).inserted {
                result.append(track)
                if result.count >= 14 { break }
            }
        }
        return result
    }

    // MARK: - Shelves

    @ViewBuilder
    private func homeModule(_ module: HomeModule, metrics: MacArtworkGridMetrics) -> some View {
        switch module.id {
        case .random:
            randomShelf(metrics: metrics)
        case .recentlyPlayed:
            albumShelf(module.title, albums: recentAlbums, seeAll: .recentlyPlayed, metrics: metrics)
        case .recentlyAdded:
            albumShelf(module.title, albums: recentAddedAlbums, seeAll: .recentlyAdded, metrics: metrics)
        case .longUnplayed:
            trackShelf(module.title, tracks: deduped(model.homeLongUnplayedTracks), metrics: metrics)
        case .favoriteRandom:
            trackShelf(module.title, tracks: deduped(model.homeFavoriteRandomTracks), metrics: metrics, actionTitle: "换一批") {
                model.regenerateFavoriteRandomMusic()
            }
        case .neverPlayed:
            trackShelf(module.title, tracks: deduped(model.homeNeverPlayedTracks), metrics: metrics)
        case .topArtists:
            artistShelf(module.title, artists: model.homeTopArtists, seeAll: .artists, metrics: metrics)
        case .topAlbums:
            albumShelf(module.title, albums: model.homeTopAlbums, seeAll: .albums, metrics: metrics)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func randomShelf(metrics: MacArtworkGridMetrics) -> some View {
        let items = Array(deduped(model.randomTracks).prefix(14)).map(MacHomeTrackItem.init)
        // 货架整体即播放上下文：点任意一首都把整列写入队列（与 iOS Home 同一机制），
        // 随机播放按钮与单曲点击共享同一份去重后的货架队列。
        let shelfTracks = model.uniquedTracks(items.map(\.track))
        if !items.isEmpty {
            // 首页的随机歌曲与专辑货架使用同一张卡片尺度；此前歌曲卡被单独
            // 限制为 150pt，导致“随机音乐”比最近播放/最近添加明显小一档。
            let size = min(210, metrics.itemWidth)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("随机音乐")
                        .font(.system(size: MacUIVisualTokens.Typography.sectionTitle, weight: .bold))
                    Spacer()
                    Button("随机播放") {
                        model.playShuffledQueue(shelfTracks)
                    }
                    .buttonStyle(.link)
                    Button("换一批") {
                        model.regenerateRandomMusic()
                    }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 2)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { item in
                            let track = item.track
                            MacTrackTile(
                                track: track,
                                theme: theme,
                                size: size,
                                onOpen: { model.playTrack(track, in: shelfTracks) },
                                onPlay: { model.playTrack(track, in: shelfTracks) },
                                moreActions: trackMenuActions(track)
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func trackShelf(
        _ title: String,
        tracks: [Track],
        metrics: MacArtworkGridMetrics,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) -> some View {
        let items = Array(tracks.prefix(14)).map(MacHomeTrackItem.init)
        if !items.isEmpty {
            let size = min(210, metrics.itemWidth)
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: actionTitle, onAction: onAction)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { item in
                            let track = item.track
                            MacTrackTile(
                                track: track,
                                theme: theme,
                                size: size,
                                onOpen: { model.playTrack(track, in: tracks) },
                                onPlay: { model.playTrack(track, in: tracks) },
                                moreActions: trackMenuActions(track)
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func albumShelf(_ title: String, albums: [Album], seeAll: MacSidebarDestination?, metrics: MacArtworkGridMetrics) -> some View {
        let items = Array(albums.prefix(14))
        if !items.isEmpty {
            let size = min(210, metrics.itemWidth)
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: seeAll == nil ? nil : "查看全部") {
                    if let seeAll { onNavigate(.sidebar(seeAll)) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 24) {
                        ForEach(items) { album in
                            MacAlbumTile(
                                album: album,
                                theme: theme,
                                size: size,
                                onOpen: { onNavigate(.album(album)) },
                                onPlay: { model.playQueue(MacLibraryQuery.albumTracks(album, model: model)) },
                                moreActions: albumMoreActions(album)
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func artistShelf(_ title: String, artists: [Artist], seeAll: MacSidebarDestination?, metrics: MacArtworkGridMetrics) -> some View {
        let items = Array(artists.prefix(14))
        if !items.isEmpty {
            let size = min(170, metrics.itemWidth)
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: seeAll == nil ? nil : "查看全部") {
                    if let seeAll { onNavigate(.sidebar(seeAll)) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { artist in
                            let representativeAlbums = MacLibraryQuery.artistAlbums(artist, model: model)
                            MacArtistTile(
                                artist: artist,
                                representativeAlbums: representativeAlbums,
                                theme: theme,
                                size: size,
                                onOpen: { onNavigate(.artist(artist)) },
                                onPlay: {
                                    let tracks = MacLibraryQuery.artistTracks(artist, model: model)
                                    if !tracks.isEmpty { model.playShuffledQueue(tracks) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private func trackMenuActions(_ track: Track) -> [MacMenuAction] {
        let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        let isFavorite = track.isFavorite
        let isDisliked = model.isDisliked(track)
        let isDownloaded = model.isDownloaded(track)
        return [
            MacMenuAction(title: "下一首播放", systemImage: "text.badge.plus") { model.playNext(globalID: gid) },
            MacMenuAction(title: "加入队列", systemImage: "text.badge.plus") { model.addToQueue(globalID: gid) },
            MacMenuAction(title: isFavorite ? "取消收藏" : "收藏", systemImage: "heart") { model.toggleFavorite(track) },
            MacMenuAction(title: isDisliked ? "取消不喜欢" : "不喜欢", systemImage: "heart.slash") { model.setDisliked(track, value: !isDisliked, source: "user") },
            MacMenuAction(title: isDownloaded ? "删除下载" : "下载", systemImage: "arrow.down.circle") {
                if isDownloaded { model.removeDownload(track) } else { model.download(track) }
            },
            MacMenuAction(title: "歌曲信息", systemImage: "info.circle") {
                NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: track)
            }
        ]
    }

    private func albumMoreActions(_ album: Album) -> [MacMenuAction] {
        let isFavorite = model.isAlbumFavorite(album)
        return [
            MacMenuAction(title: isFavorite ? "取消收藏专辑" : "收藏专辑", systemImage: "heart") { model.toggleAlbumFavorite(album) },
            MacMenuAction(title: "随机播放专辑", systemImage: "shuffle") { model.playShuffledQueue(MacLibraryQuery.albumTracks(album, model: model)) }
        ]
    }
}
#endif
