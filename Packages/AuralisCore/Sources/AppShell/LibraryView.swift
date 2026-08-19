import DesignSystem
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

struct LibraryView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var scope = LibraryScope.albums
    @State private var playlistTarget: Track?
    @State private var recommendationCategories: [RecommendationIndexV2Category] = []
    @State private var isLoadingRecommendationCategories = false
    /// AI 标签独立区：offset 游标分页（读取优化，不代表标签数量限制）。
    @State private var aiTags: [RecommendationIndexV2Category] = []
    @State private var aiTagSearch = ""
    @State private var recommendationCategoryError: String?
    @State private var aiTagNextOffset: Int? = 0
    @State private var isLoadingMoreTags = false
    private static let aiTagPageSize = 30

    init(model: AuralisAppModel, theme: BuiltInTheme, initialScope: LibraryScope = .albums) {
        self.model = model
        self.theme = theme
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("资料类型", selection: $scope) {
                ForEach(LibraryScope.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.small)
            .onChange(of: scope) { _, _ in Haptics.selection() }
            Divider()
            scopeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.colorTokens.background.color)
#if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.selectTopLevelSection(.settings)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.colorTokens.accent.color)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(HapticPlainButtonStyle())
                .accessibilityLabel(String(localized: "设置", bundle: .module))
            }
        }
#endif
        .sheet(item: $playlistTarget) { track in
            AddToPlaylistSheet(model: model, theme: theme, track: track)
        }
    }

    @ViewBuilder
    private var scopeContent: some View {
        switch scope {
        case .tracks: trackList
        case .albums: albumGrid
        case .artists: artistList
        case .playlists: playlistGrid
        case .favorites: favoriteList
        case .genres: genreList
        case .categories: recommendationCategoryList
        }
    }

    private var trackList: some View {
        Group {
            if model.catalog.tracks.isEmpty {
                AuralisEmptyState(
                    icon: "music.note",
                    title: "资料库还没有歌曲",
                    message: "连接服务器并同步后，这里会列出全部歌曲；也可以从「首页」先随机播放几首。",
                    colors: theme.colorTokens
                )
            } else {
                List(model.catalog.tracks) { track in
                    Button {
                        model.selectAndPlay(track)
                    } label: {
                        TrackRow(track: track, isCurrent: track.isSame(as: model.currentTrack), isDownloaded: model.isDownloaded(track), theme: theme)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(HapticPlainButtonStyle())
                        .accessibilityLabel(String(localized: "播放《\(track.title)》，艺术家 \(track.artistName)", bundle: .module))
                        .contextMenu {
                            Button(String(localized: "立即播放", bundle: .module)) { model.selectAndPlay(track) }
                            Button(String(localized: "下一首播放", bundle: .module)) { insertNext(track) }
                            Button(String(localized: "加入队列", bundle: .module)) {
                                // R05：queueStore.append 直调，不重建 entry UUID——
                                // 重复队列中当前项不会因追加而漂回第一个匹配。
                                model.appendToQueue(track)
                            }
                            Button(String(localized: "添加到歌单", bundle: .module)) { playlistTarget = track }
                            Divider()
                            if model.isDownloaded(track) {
                                Button(String(localized: "删除本地缓存", bundle: .module), role: .destructive) { model.removeDownload(track) }
                            } else if model.isDownloading(track) {
                                Button(String(localized: "取消下载", bundle: .module)) { model.cancelDownload(track) }
                            } else {
                                Button(String(localized: "下载到本地", bundle: .module)) { model.download(track) }
                            }
                            Divider()
                            Button(track.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module)) { model.toggleFavorite(track) }
                        }
                }
                .listStyle(.plain)
                .reportsBottomDockScroll()
            }
        }
    }

    private var albumGrid: some View {
        Group {
            if model.catalog.albums.isEmpty {
                AuralisEmptyState(
                    icon: "square.stack",
                    title: "还没有专辑",
                    message: "当前资料库暂无专辑，可能需要同步或扫描音乐库。",
                    colors: theme.colorTokens
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: AuralisSpacing.medium)], spacing: AuralisSpacing.large) {
                        ForEach(model.catalog.albums) { album in
                            Button {
                                model.browseDestination = .album(album)
                            } label: {
                                VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
                                    GeometryReader { geo in
                                        ArtworkView(title: album.title, artworkKey: album.artworkKey, colors: theme.colorTokens, size: max(geo.size.width, 1))
                                    }
                                    .aspectRatio(1, contentMode: .fit)
                                    .frame(minHeight: 1)
                                    Text(album.title).font(.headline).lineLimit(1)
                                    Text(album.artistName).font(.caption).foregroundStyle(theme.colorTokens.secondaryText.color).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(theme.colorTokens.primaryText.color)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HapticPlainButtonStyle())
                            .accessibilityLabel(String(localized: "专辑《\(album.title)》，艺术家 \(album.artistName)", bundle: .module))
                            .contextMenu {
                                Button(String(localized: "播放全部", bundle: .module)) {
                                    let tracks = model.catalog.tracks.filter { $0.albumID == album.id }
                                    model.playTracks(tracks)
                                }
                                Button(model.isAlbumFavorite(album) ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏专辑", bundle: .module)) { model.toggleAlbumFavorite(album) }
                                Button(String(localized: "下载专辑", bundle: .module)) {
                                    model.downloadAll(model.catalog.tracks.filter { $0.albumID == album.id })
                                }
                            }
                        }
                    }
                    .padding()
                }
                .reportsBottomDockScroll()
            }
        }
    }

    private var artistList: some View {
        Group {
            if model.catalog.artists.isEmpty {
                AuralisEmptyState(
                    icon: "person.2",
                    title: "还没有艺术家",
                    message: "当前资料库暂无艺术家，可能需要同步或扫描音乐库。",
                    colors: theme.colorTokens
                )
            } else {
                List(model.catalog.artists) { artist in
                    Button {
                        model.browseDestination = .artist(artist)
                    } label: {
                        HStack {
                            ArtworkView(title: artist.name, artworkKey: artist.artworkKey, colors: theme.colorTokens, size: 48, cornerRadius: 24)
                            VStack(alignment: .leading) {
                                Text(artist.name).font(.headline)
                                Text("\(artist.albumCount) 张专辑").font(.caption).foregroundStyle(theme.colorTokens.secondaryText.color)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HapticPlainButtonStyle())
                    .accessibilityLabel(String(localized: "艺术家 \(artist.name)，\(artist.albumCount) 张专辑", bundle: .module))
                    .contextMenu {
                        Button(String(localized: "播放全部", bundle: .module)) {
                            model.playTracks(model.catalog.tracks.filter { $0.artistID == artist.id })
                        }
                        Button(model.isArtistFavorite(artist) ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏艺术家", bundle: .module)) { model.toggleArtistFavorite(artist) }
                        Button(String(localized: "下载全部", bundle: .module)) {
                            model.downloadAll(model.catalog.tracks.filter { $0.artistID == artist.id })
                        }
                    }
                }
                .listStyle(.plain)
                .reportsBottomDockScroll()
            }
        }
    }

    /// 流派浏览：按服务器 getGenres 与曲目标签合并后的流派展示，卡片式、按实际歌曲数降序。
    /// 显示名使用中文翻译（GenreLocalization）；点击进入该流派歌曲列表。
    private var genreList: some View {
        Group {
            let genres = Self.sortedGenres(model)
            if genres.isEmpty {
                AuralisEmptyState(
                    icon: "music.quarternote.3",
                    title: "还没有流派",
                    message: "服务器返回的流派（来自音乐文件内嵌标签）会显示在这里；连接并同步后即可按流派浏览。",
                    colors: theme.colorTokens
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: AuralisSpacing.medium)],
                        spacing: AuralisSpacing.medium
                    ) {
                        ForEach(genres, id: \.genre.id) { item in
                            Button {
                                model.browseDestination = .genre(item.genre)
                            } label: {
                                VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                                    HStack {
                                        Image(systemName: "music.quarternote.3")
                                            .font(.title3)
                                            .foregroundStyle(theme.colorTokens.accent.color)
                                        Spacer()
                                        Text("\(item.count)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                                    }
                                    Text(GenreLocalization.displayName(for: item.genre.name))
                                        .font(.headline)
                                        .lineLimit(1)
                                        .foregroundStyle(theme.colorTokens.primaryText.color)
                                    Text("\(item.count) 首")
                                        .font(.caption)
                                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                                }
                                .padding(AuralisSpacing.medium)
                                .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                                .background(theme.colorTokens.surface.color)
                                .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
                            }
                            .buttonStyle(HapticPlainButtonStyle())
                        }
                    }
                    .padding(AuralisSpacing.medium)
                }
                .reportsBottomDockScroll()
            }
        }
        .task { model.refreshGenres() }
    }

    /// 聚合流派并按实际歌曲数降序（数量相同按名称排序）。
    private static func sortedGenres(_ model: AuralisAppModel) -> [(genre: Genre, count: Int)] {
        let items: [(genre: Genre, count: Int)] = model.catalog.genres.map { genre in
            (genre, model.tracks(for: genre).count)
        }
        return items.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return left.genre.name.localizedStandardCompare(right.genre.name) == .orderedAscending
        }
    }

    /// AI 推荐索引 V2 的标签浏览。卡片尺寸、栅格和流派完全一致，区别仅在数据源是本地 SQLite 索引。
    private var recommendationCategoryList: some View {
        Group {
            if isLoadingRecommendationCategories && recommendationCategories.isEmpty {
                ProgressView("正在读取本地分类…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let recommendationCategoryError {
                AuralisEmptyState(
                    icon: "exclamationmark.triangle",
                    title: "读取分类失败",
                    message: recommendationCategoryError,
                    colors: theme.colorTokens
                )
            } else if recommendationCategories.isEmpty {
                AuralisEmptyState(
                    icon: "square.grid.2x2",
                    title: "还没有分类",
                    message: "AI 推荐索引完成分类后，情绪、场景、人声、质感、风格和听感维度会显示在这里。",
                    colors: theme.colorTokens
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: AuralisSpacing.medium)],
                        spacing: AuralisSpacing.medium
                    ) {
                        ForEach(recommendationCategories) { category in
                            Button {
                                openRecommendationCategory(category)
                            } label: {
                                VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                                    HStack {
                                        Image(systemName: Self.categorySymbol(for: category.dimension))
                                            .font(.title3)
                                            .foregroundStyle(theme.colorTokens.accent.color)
                                        Spacer()
                                        Text("\(category.trackCount)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                                    }
                                    Text(Self.categoryTitle(category))
                                        .font(.headline)
                                        .lineLimit(1)
                                        .foregroundStyle(theme.colorTokens.primaryText.color)
                                    Text("\(category.trackCount) 首")
                                        .font(.caption)
                                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                                }
                                .padding(AuralisSpacing.medium)
                                .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                                .background(theme.colorTokens.surface.color)
                                .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
                            }
                            .buttonStyle(HapticPlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, AuralisSpacing.medium)
                    .padding(.top, AuralisSpacing.medium)

                    // AI 标签独立区：搜索 + 分页（读取优化，不代表标签数量限制）。
                    if !aiTags.isEmpty || !aiTagSearch.isEmpty {
                        HStack {
                            Text(String(localized: "AI 标签", bundle: .module))
                                .font(.headline)
                                .foregroundStyle(theme.colorTokens.primaryText.color)
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass")
                                    .font(.caption)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                                TextField("搜索标签", text: $aiTagSearch)
                                    .textFieldStyle(.plain)
                                    .font(.caption)
                                    .onSubmit { Task { await loadAITags(reset: true) } }
                            }
                            .padding(.horizontal, AuralisSpacing.small)
                            .padding(.vertical, 4)
                            .background(theme.colorTokens.surface.color)
                            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.small))
                            .frame(maxWidth: 180)
                        }
                        .padding(.horizontal, AuralisSpacing.medium)
                        .padding(.top, AuralisSpacing.large)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: AuralisSpacing.medium)],
                            spacing: AuralisSpacing.medium
                        ) {
                            ForEach(aiTags) { category in
                                Button {
                                    openRecommendationCategory(category)
                                } label: {
                                    VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                                        HStack {
                                            Image(systemName: "tag")
                                                .font(.title3)
                                                .foregroundStyle(theme.colorTokens.accent.color)
                                            Spacer()
                                            Text("\(category.trackCount)")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                                        }
                                        Text(category.value)
                                            .font(.headline)
                                            .lineLimit(1)
                                            .foregroundStyle(theme.colorTokens.primaryText.color)
                                        Text("\(category.trackCount) 首")
                                            .font(.caption)
                                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                                    }
                                    .padding(AuralisSpacing.medium)
                                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                                    .background(theme.colorTokens.surface.color)
                                    .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
                                }
                                .buttonStyle(HapticPlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, AuralisSpacing.medium)
                        .padding(.top, AuralisSpacing.small)

                        if aiTagNextOffset != nil {
                            Button {
                                Task { await loadMoreAITags() }
                            } label: {
                                HStack {
                                    if isLoadingMoreTags { ProgressView().controlSize(.small) }
                                    Text(String(localized: "加载更多标签", bundle: .module))
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .padding(.horizontal, AuralisSpacing.medium)
                            .padding(.bottom, AuralisSpacing.medium)
                        } else {
                            Spacer().frame(height: AuralisSpacing.medium)
                        }
                    } else {
                        Spacer().frame(height: AuralisSpacing.medium)
                    }
                }
                .reportsBottomDockScroll()
            }
        }
        .task { await loadRecommendationCategories() }
    }

    private func loadRecommendationCategories() async {
        guard let serverID = model.catalog.activeAccount?.id else {
            recommendationCategories = []
            aiTags = []
            return
        }
        isLoadingRecommendationCategories = true
        recommendationCategoryError = nil
        // 固定维度一次读取（数量有界）；开放语义标签单独分页（tag_catalog），
        // 避免 5000 个 AI 标签一次读进内存。
        do {
            recommendationCategories = try await model.catalogCoordinator.store.recommendationIndexV2Categories(
                serverID: serverID,
                dimensions: RecommendationIndexV2.fixedDimensions
            )
        } catch {
            recommendationCategories = []
            recommendationCategoryError = "读取分类失败：\(error.localizedDescription)"
        }
        isLoadingRecommendationCategories = false
        await loadAITags(reset: true)
    }

    private func loadAITags(reset: Bool) async {
        guard let serverID = model.catalog.activeAccount?.id else { return }
        if reset {
            aiTags = []
            aiTagNextOffset = 0
        }
        guard let offset = aiTagNextOffset else {
            isLoadingMoreTags = false
            return
        }
        let query = aiTagSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = (try? await model.catalogCoordinator.store.recommendationIndexV2TagCatalog(
            serverID: serverID, query: query.isEmpty ? nil : query, limit: Self.aiTagPageSize, offset: offset
        )) ?? RecommendationIndexV2TagPage(items: [], nextOffset: nil, hasMore: false)
        var merged = reset ? page.items : aiTags + page.items
        // 防御性去重。
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.id).inserted }
        aiTags = merged
        aiTagNextOffset = page.nextOffset
        isLoadingMoreTags = false
    }

    private func loadMoreAITags() async {
        guard !isLoadingMoreTags, aiTagNextOffset != nil else { return }
        isLoadingMoreTags = true
        await loadAITags(reset: false)
    }

    private func openRecommendationCategory(_ category: RecommendationIndexV2Category) {
        // 路由只携带分类身份，详情页自行按需读取并处理失败，避免把一次性快照
        // 存进导航值（索引刷新后详情页会重新解析，读库失败也能展示错误与重试）。
        model.browseDestination = .recommendationCategory(category)
    }

    private static func categoryTitle(_ category: RecommendationIndexV2Category) -> String {
        let dimension: String
        switch category.dimension {
        case "mood": dimension = "情绪"
        case "scene": dimension = "场景"
        case "vocal": dimension = "人声"
        case "texture": dimension = "质感"
        case "style": dimension = "风格"
        case "energy": dimension = "能量"
        case "tempo": dimension = "速度"
        case "acousticness": dimension = "原声感"
        case "danceability": dimension = "舞动性"
        case "tag": dimension = "AI 标签"
        default: dimension = category.dimension
        }
        let suffix: String
        switch category.dimension {
        case "energy": suffix = "\(category.value)/10"
        case "tempo", "acousticness", "danceability": suffix = "\(category.value)/5"
        default: suffix = category.value
        }
        return "\(dimension) · \(suffix)"
    }

    private static func categorySymbol(for dimension: String) -> String {
        switch dimension {
        case "mood": "face.smiling"
        case "scene": "location"
        case "vocal": "mic"
        case "texture": "waveform"
        case "style": "music.note.list"
        case "energy": "bolt"
        case "tempo": "metronome"
        case "acousticness": "guitars"
        case "danceability": "figure.dance"
        case "tag": "tag"
        default: "tag"
        }
    }

    /// 歌单封面：取歌单内第一首歌曲的封面（同一专辑多首歌曲共享封面）。
    private static func firstTrackArtworkKey(_ model: AuralisAppModel, _ playlist: Playlist) -> String? {
        guard let firstID = playlist.trackIDs.first else { return nil }
        return model.catalog.tracks.first { $0.id == firstID }?.artworkKey
    }



    private var playlistGrid: some View {
        Group {
            if model.catalog.playlists.isEmpty {
                AuralisEmptyState(
                    icon: "music.note.list",
                    title: "还没有歌单",
                    message: "在服务器上创建歌单后，这里会列出所有歌单。",
                    colors: theme.colorTokens
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: AuralisSpacing.medium)], spacing: AuralisSpacing.large) {
                        ForEach(model.catalog.playlists) { playlist in
                            Button {
                                model.browseDestination = .playlist(playlist)
                            } label: {
                                VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous)
                                            .fill(theme.colorTokens.surface.color)
                                            .aspectRatio(1, contentMode: .fit)
                                        if let coverKey = Self.firstTrackArtworkKey(model, playlist) {
                                            GeometryReader { geo in
                                                ArtworkView(title: playlist.name, artworkKey: coverKey, colors: theme.colorTokens, size: max(geo.size.width, 1))
                                            }
                                            .aspectRatio(1, contentMode: .fit)
                                            .frame(minHeight: 1)
                                            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
                                        } else {
                                            Image(systemName: "music.note.list")
                                                .font(.system(size: 40))
                                                .foregroundStyle(theme.colorTokens.accent.color)
                                        }
                                    }
                                    Text(playlist.name).font(.headline).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(theme.colorTokens.primaryText.color)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HapticPlainButtonStyle())
                            .accessibilityLabel(String(localized: "歌单《\(playlist.name)》", bundle: .module))
                        }
                    }
                    .padding()
                }
                .reportsBottomDockScroll()
            }
        }
    }

    private var favoriteList: some View {
        Group {
            if model.favoriteTracks.isEmpty {
                AuralisEmptyState(
                    icon: "heart",
                    title: "还没有收藏",
                    message: "在播放页或歌曲菜单中点心形收藏后，会出现在这里。",
                    colors: theme.colorTokens
                )
            } else {
                List(model.favoriteTracks) { track in
                    Button {
                        model.selectAndPlay(track)
                    } label: {
                        TrackRow(track: track, isCurrent: track.isSame(as: model.currentTrack), theme: theme)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(HapticPlainButtonStyle())
                        .accessibilityLabel(String(localized: "播放《\(track.title)》，艺术家 \(track.artistName)", bundle: .module))
                        .contextMenu {
                            Button(String(localized: "立即播放", bundle: .module)) { model.selectAndPlay(track) }
                            Button(String(localized: "下一首播放", bundle: .module)) { insertNext(track) }
                            Button(track.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module)) { model.toggleFavorite(track) }
                        }
                }
                .listStyle(.plain)
                .reportsBottomDockScroll()
            }
        }
    }

    private func insertNext(_ track: Track) {
        // R05：playNext 语义 = 插到当前队列项之后（currentIndex nil 时插队首）。
        // 走 queueStore.playNext 直调，不触发 [Track] setter 重建 entry UUID，
        // 也不用 firstIndex(TrackID) 找当前项（重复歌曲会找错位置）。
        model.playNext(globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
    }
}

enum LibraryScope: String, CaseIterable, Identifiable {
    case albums, tracks, artists, playlists, favorites, genres, categories
    var id: String { rawValue }
    var title: String {
        switch self {
        case .albums: String(localized: "专辑", bundle: .module)
        case .tracks: String(localized: "歌曲", bundle: .module)
        case .artists: String(localized: "艺术家", bundle: .module)
        case .playlists: String(localized: "歌单", bundle: .module)
        case .favorites: String(localized: "收藏", bundle: .module)
        case .genres: String(localized: "流派", bundle: .module)
        case .categories: String(localized: "分类", bundle: .module)
        }
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    var isDownloaded: Bool = false
    let theme: BuiltInTheme

    var body: some View {
        HStack(spacing: AuralisSpacing.medium) {
            ArtworkView(title: track.albumTitle, artworkKey: track.artworkKey, colors: theme.colorTokens, size: 48, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? theme.colorTokens.accent.color : theme.colorTokens.primaryText.color)
                Text("\(track.artistName) · \(track.albumTitle)")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                    .lineLimit(1)
            }
            Spacer()
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.success.color)
                    .accessibilityLabel(String(localized: "已下载", bundle: .module))
            }
            if track.isFavorite {
                Image(systemName: "heart.fill")
                    .foregroundStyle(theme.colorTokens.accent.color)
                    .accessibilityLabel(String(localized: "已收藏", bundle: .module))
            }
            Text(formatDuration(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.colorTokens.secondaryText.color)
        }
        .padding(.vertical, 3)
    }
}

func formatDuration(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}