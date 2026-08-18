import DesignSystem
import Domain
import SwiftUI
import ThemeEngine

/// 首页统一横向卡片度量（需求：左边距/卡片宽/间距/封面比例统一，
/// 标题与艺术家各一行 / 尾部截断 / 下一张露出宽度一致）。
private enum HomeCardMetrics {
    static let width: CGFloat = 140
    static let spacing: CGFloat = AuralisSpacing.medium
    static let textSpacing: CGFloat = 3
    static let titleHeight: CGFloat = 20
}

/// 首页：由模块注册表驱动，不再写死 `if showX` 分支。
/// - 渲染列表来自用户布局偏好（HomeLayoutStore，UserDefaults 持久化）；
/// - 关闭的模块完全不渲染、不留空白、不查询数据、不加载封面（从模块列表移除）；
/// - 开启但当前无数据的模块本次暂不渲染，但用户配置保持开启，数据满足后自动出现。
struct HomeView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    private var colors: ThemeColors { theme.colorTokens }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AuralisSpacing.xLarge) {
                quickEntriesSection
                ForEach(visibleContentModules) { module in
                    moduleSection(module)
                }
                librarySummary
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.top, AuralisSpacing.medium)
            .padding(.bottom, AuralisSpacing.large)
            // iPad 宽屏：主内容限宽并居中（可读宽度），卡片仍是固定 140pt，
            // 宽屏只是自然多显示几张，不拉伸成超宽卡片。
            .frame(maxWidth: IOSLayoutMetrics.readableContentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .reportsBottomDockScroll()
        .background(ambientBackground)
    }

    // MARK: - 模块可见性（用户开启 + 有数据）

    /// 当前要渲染的快捷入口：按用户配置顺序，关闭的不渲染，开启但无数据也暂不渲染
    /// （配置保持开启，数据满足后自动出现）。
    private var visibleQuickModules: [HomeModule] {
        model.homeLayout.quickEntries
            .filter { $0.isVisible && Self.moduleHasData(HomeModuleID(rawValue: $0.moduleID), model: model) }
            .compactMap { HomeModuleRegistry.module(forID: $0.moduleID) }
    }

    /// 当前要渲染的内容模块：语义同上。
    private var visibleContentModules: [HomeModule] {
        model.homeLayout.contentModules
            .filter { $0.isVisible && Self.moduleHasData(HomeModuleID(rawValue: $0.moduleID), model: model) }
            .compactMap { HomeModuleRegistry.module(forID: $0.moduleID) }
    }

    /// 模块当前是否有数据（读取的是已在 refreshHomeSnapshots 算好的快照计数，
    /// 不在这里做任何全表遍历 / 网络请求 / 封面加载）。
    private static func moduleHasData(_ moduleID: HomeModuleID?, model: AuralisAppModel) -> Bool {
        guard let moduleID else { return false }
        switch moduleID {
        case .playlists: return model.catalog.playlists.count > 0
        case .favorites: return model.homeFavoriteTracks.count > 0
        case .mostPlayed: return model.homeMostPlayedTracks.count > 0
        case .playHistory: return model.homeRecentlyPlayedTracks.count > 0
        case .downloads: return model.downloadedTracks.count > 0
        case .random: return model.randomTracks.count > 0
        case .recentlyPlayed: return model.homeRecentlyPlayedTracks.count > 0
        case .recentlyAdded: return model.homeRecentlyAdded30DaysTracks.count > 0
        case .longUnplayed: return model.homeLongUnplayedTracks.count > 0
        case .favoriteRandom: return model.homeFavoriteRandomTracks.count > 0
        case .neverPlayed: return model.homeNeverPlayedTracks.count > 0
        case .topArtists: return model.homeTopArtists.count > 0
        case .topAlbums: return model.homeTopAlbums.count > 0
        }
    }

    // MARK: - 快捷入口

    @ViewBuilder
    private var quickEntriesSection: some View {
        let modules = visibleQuickModules
        if !modules.isEmpty {
            // 一行最多 3 个、超过自动换行（不做横向滚动）。当前注册表仅 歌单/收藏/最常听 三个。
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: AuralisSpacing.medium), count: 3),
                spacing: AuralisSpacing.medium
            ) {
                ForEach(modules) { module in
                    quickEntryCard(module)
                }
            }
        }
    }

    /// 快捷入口卡片：纯图标 + 数量（不显示文字标题，避免文字过长被截断）。
    private func quickEntryCard(_ module: HomeModule) -> some View {
        Button {
            openQuickEntry(module)
        } label: {
            VStack(spacing: AuralisSpacing.small) {
                Image(systemName: module.icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(colors.accent.color)
                    .frame(height: 28)
                Text(quickEntryCount(module))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colors.primaryText.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.vertical, AuralisSpacing.medium)
            .background(colors.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(HapticPlainButtonStyle())
        .accessibilityLabel("\(module.title)，\(quickEntryCount(module)) 项")
    }

    private func quickEntryCount(_ module: HomeModule) -> String {
        switch module.id {
        case .playlists: "\(model.catalog.playlists.count)"
        case .favorites: "\(model.homeFavoriteTracks.count)"
        case .mostPlayed: "\(model.homeMostPlayedTracks.count)"
        case .playHistory: "\(model.homeRecentlyPlayedTracks.count)"
        case .downloads: "\(model.downloadedTracks.count)"
        default: ""
        }
    }

    private func openQuickEntry(_ module: HomeModule) {
        switch module.id {
        case .playlists: model.browseDestination = .playlists
        case .favorites: model.browseDestination = .favorites
        case .mostPlayed: model.browseDestination = .mostPlayed
        case .playHistory: model.browseDestination = .recentlyPlayed
        case .downloads: model.browseDestination = .downloads
        default: break
        }
    }

    // MARK: - 内容模块

    @ViewBuilder
    private func moduleSection(_ module: HomeModule) -> some View {
        switch module.id {
        case .random, .recentlyPlayed, .recentlyAdded, .longUnplayed, .favoriteRandom, .neverPlayed:
            trackShelf(module)
        case .topArtists:
            artistShelf(module)
        case .topAlbums:
            albumShelf(module)
        default:
            EmptyView()
        }
    }

    /// 横向歌曲货架：标题行 + 统一横向卡片布局。
    private func trackShelf(_ module: HomeModule) -> some View {
        let tracks = trackList(for: module)
        return VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
            moduleHeader(module, count: tracks.count)
            if !tracks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: HomeCardMetrics.spacing) {
                        ForEach(tracks) { track in
                            Button {
                                model.queue = tracks
                                model.selectAndPlay(track)
                            } label: {
                                HomeTrackCard(track: track, colors: colors)
                                    .frame(width: HomeCardMetrics.width, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(HapticPlainButtonStyle())
                        }
                    }
                    .padding(.trailing, AuralisSpacing.large)
                }
            }
        }
    }

    /// 常听艺术家：艺术家横向卡片，点卡片进入艺术家详情。
    private func artistShelf(_ module: HomeModule) -> some View {
        let artists = model.homeTopArtists
        return VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
            moduleHeader(module, count: artists.count)
            if !artists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: HomeCardMetrics.spacing) {
                        ForEach(artists) { artist in
                            Button {
                                model.browseDestination = .artist(artist)
                            } label: {
                                HomeArtistCard(
                                    artist: artist,
                                    playCount: model.homeTopArtistPlayCounts[artist.id] ?? 0,
                                    colors: colors
                                )
                                .frame(width: HomeCardMetrics.width, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HapticPlainButtonStyle())
                        }
                    }
                    .padding(.trailing, AuralisSpacing.large)
                }
            }
        }
    }

    /// 常听专辑：专辑横向卡片，点卡片进入专辑详情。
    private func albumShelf(_ module: HomeModule) -> some View {
        let albums = model.homeTopAlbums
        return VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
            moduleHeader(module, count: albums.count)
            if !albums.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: HomeCardMetrics.spacing) {
                        ForEach(albums) { album in
                            Button {
                                model.browseDestination = .album(album)
                            } label: {
                                HomeAlbumCard(
                                    album: album,
                                    playCount: model.homeTopAlbumPlayCounts[album.id] ?? 0,
                                    colors: colors
                                )
                                .frame(width: HomeCardMetrics.width, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HapticPlainButtonStyle())
                        }
                    }
                    .padding(.trailing, AuralisSpacing.large)
                }
            }
        }
    }

    private func trackList(for module: HomeModule) -> [Track] {
        switch module.id {
        case .random: model.randomTracks
        case .recentlyPlayed: model.homeRecentlyPlayedTracks
        case .recentlyAdded: model.homeRecentlyAdded30DaysTracks
        case .longUnplayed: model.homeLongUnplayedTracks
        case .favoriteRandom: model.homeFavoriteRandomTracks
        case .neverPlayed: model.homeNeverPlayedTracks
        default: []
        }
    }

    /// 模块标题行：左侧标题，右侧「数量 / 换一批 / 查看更多」，视觉层级统一。
    private func moduleHeader(_ module: HomeModule, count: Int) -> some View {
        HStack {
            Text(module.title)
                .font(.title2.bold())
                .foregroundStyle(colors.primaryText.color)
            Spacer()
            trailingControl(module, count: count)
        }
    }

    @ViewBuilder
    private func trailingControl(_ module: HomeModule, count: Int) -> some View {
        switch module.id {
        case .random:
            HStack(spacing: AuralisSpacing.small) {
                refreshButton {
                    model.regenerateRandomMusic()
                }
                detailButton("\(count) 首") {
                    model.browseDestination = .random
                }
            }
        case .favoriteRandom:
            HStack(spacing: AuralisSpacing.small) {
                refreshButton {
                    model.regenerateFavoriteRandomMusic()
                }
                detailButton("\(count) 首") {
                    model.browseDestination = .favoriteRandom
                }
            }
        case .recentlyAdded:
            detailButton("近30天新增 \(count) 首") {
                model.browseDestination = .recentlyAdded
            }
        case .topArtists:
            detailButton("\(count) 位") {
                model.browseDestination = .topArtists
            }
        case .topAlbums:
            detailButton("\(count) 张") {
                model.browseDestination = .topAlbums
            }
        default:
            detailButton("\(count) 首") {
                openContentModule(module)
            }
        }
    }

    /// 「换一批」：轻量文本按钮，本地重采样，不发网络请求。
    private func refreshButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "arrow.clockwise")
                Text("换一批")
            }
            .font(.caption)
            .foregroundStyle(colors.secondaryText.color)
        }
        .buttonStyle(HapticPlainButtonStyle())
    }

    /// 「数量 ›」：进入完整列表。
    private func detailButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(colors.secondaryText.color)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(colors.secondaryText.color)
            }
        }
        .buttonStyle(HapticPlainButtonStyle())
    }

    private func openContentModule(_ module: HomeModule) {
        switch module.id {
        case .random: model.browseDestination = .random
        case .recentlyPlayed: model.browseDestination = .recentlyPlayed
        case .recentlyAdded: model.browseDestination = .recentlyAdded
        case .longUnplayed: model.browseDestination = .longUnplayed
        case .favoriteRandom: model.browseDestination = .favoriteRandom
        case .neverPlayed: model.browseDestination = .neverPlayed
        case .topArtists: model.browseDestination = .topArtists
        case .topAlbums: model.browseDestination = .topAlbums
        default: break
        }
    }

    // MARK: - 资料库统计

    private var librarySummary: some View {
        HStack(spacing: AuralisSpacing.small) {
            stat("\(model.catalog.artists.count)", "艺术家")
            stat("\(model.catalog.albums.count)", "专辑")
            stat("\(model.catalog.tracks.count)", "歌曲")
            stat("\(model.catalog.playlists.count)", "歌单")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .center) {
            Text(value)
                .font(.headline.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(colors.primaryText.color)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(label)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(colors.secondaryText.color)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, AuralisSpacing.small)
        .padding(.vertical, AuralisSpacing.medium)
        .background(colors.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
    }

    private var ambientBackground: some View {
        LinearGradient(
            colors: [colors.background.color, colors.accent.color.opacity(0.12), colors.background.color],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

/// 统一横向歌曲卡片：封面方形、标题与艺术家各一行并尾部截断。
/// 固定同一文本度量，避免某张长标题把作者名挤远、相邻卡片高低不齐。
private struct HomeTrackCard: View {
    let track: Track
    let colors: ThemeColors

    var body: some View {
        VStack(alignment: .leading, spacing: HomeCardMetrics.textSpacing) {
            ArtworkView(title: track.albumTitle, artworkKey: track.artworkKey, colors: colors, size: HomeCardMetrics.width)
            Text(track.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.primaryText.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: HomeCardMetrics.titleHeight, alignment: .top)
            Text(track.artistName)
                .font(.caption)
                .foregroundStyle(colors.secondaryText.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// 常听艺术家卡片（点卡片进入艺术家详情）。
private struct HomeArtistCard: View {
    let artist: Artist
    let playCount: Int
    let colors: ThemeColors

    var body: some View {
        VStack(alignment: .leading, spacing: HomeCardMetrics.textSpacing) {
            ArtworkView(title: artist.name, artworkKey: artist.artworkKey, colors: colors, size: HomeCardMetrics.width)
            Text(artist.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.primaryText.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: HomeCardMetrics.titleHeight, alignment: .top)
            Text("\(playCount) 次播放")
                .font(.caption)
                .foregroundStyle(colors.secondaryText.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// 常听专辑卡片（点卡片进入专辑详情）。
private struct HomeAlbumCard: View {
    let album: Album
    let playCount: Int
    let colors: ThemeColors

    var body: some View {
        VStack(alignment: .leading, spacing: HomeCardMetrics.textSpacing) {
            ArtworkView(title: album.title, artworkKey: album.artworkKey, colors: colors, size: HomeCardMetrics.width)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.primaryText.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: HomeCardMetrics.titleHeight, alignment: .top)
            Text("\(playCount) 次播放")
                .font(.caption)
                .foregroundStyle(colors.secondaryText.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
