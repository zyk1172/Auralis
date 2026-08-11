#if os(macOS)
import AgentKit
import DesignSystem
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

// MARK: - 艺术家详情

/// macOS 艺术家详情：名称 + 专辑网格 + 歌曲表格，作为主内容导航的一层。
struct MacArtistDetailPage: View {
    let artist: Artist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>

    private var albums: [Album] {
        model.catalog.albums.filter { $0.artistID == artist.id }
    }

    private var tracks: [Track] {
        model.catalog.tracks.filter { $0.artistID == artist.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AuralisSpacing.medium) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.colorTokens.accent.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name).font(.title2.bold())
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text("\(albums.count) 张专辑 · \(tracks.count) 首歌曲")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer()
                Button("播放全部") { model.playQueue(tracks) }
                    .disabled(tracks.isEmpty)
                Button("随机播放") { model.playShuffledQueue(tracks) }
                    .disabled(tracks.isEmpty)
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.medium)
            Divider()
            if tracks.isEmpty {
                ContentUnavailableView("暂无歌曲", systemImage: "music.note",
                                       description: Text("该艺术家还没有可播放的歌曲。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacSongTable(tracks: tracks, selection: $selection, model: model, theme: theme)
            }
        }
        .background(theme.colorTokens.background.color)
        .navigationTitle(artist.name)
    }
}

// MARK: - 流派详情

/// macOS 流派详情：标题 + 歌曲数 + 表格，作为主内容导航的一层。
struct MacGenreDetailPage: View {
    let genre: Genre
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>

    private var tracks: [Track] { model.tracks(for: genre) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(GenreLocalization.displayName(for: genre.name)).font(.title2.bold())
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text("\(tracks.count) 首歌曲")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer()
                Button("播放全部") { model.playQueue(tracks) }
                    .disabled(tracks.isEmpty)
                Button("随机播放") { model.playShuffledQueue(tracks) }
                    .disabled(tracks.isEmpty)
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.medium)
            Divider()
            if tracks.isEmpty {
                ContentUnavailableView("暂无歌曲", systemImage: "music.quarternote.3",
                                       description: Text("该流派还没有歌曲。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacSongTable(tracks: tracks, selection: $selection, model: model, theme: theme)
            }
        }
        .background(theme.colorTokens.background.color)
        .navigationTitle(GenreLocalization.displayName(for: genre.name))
    }
}

// MARK: - 歌单详情

/// macOS 歌单详情：歌单名 + 曲目数 + 表格，作为主内容导航的一层。
struct MacPlaylistDetailPage: View {
    let playlist: Playlist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>

    private var tracks: [Track] {
        let ids = Set(playlist.trackIDs)
        return model.catalog.tracks.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.title2.bold())
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text("\(tracks.count) 首歌曲")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer()
                Button("播放全部") { model.playQueue(tracks) }
                    .disabled(tracks.isEmpty)
                Button("随机播放") { model.playShuffledQueue(tracks) }
                    .disabled(tracks.isEmpty)
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.medium)
            Divider()
            if tracks.isEmpty {
                ContentUnavailableView("暂无歌曲", systemImage: "music.note.list",
                                       description: Text("这个歌单还没有歌曲。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacSongTable(tracks: tracks, selection: $selection, model: model, theme: theme)
            }
        }
        .background(theme.colorTokens.background.color)
        .navigationTitle(playlist.name)
    }
}

// MARK: - 正在播放（主内容页）

/// macOS 正在播放页：大封面 + 元数据 + 私人状态 + 公开音乐资料摘要。
/// 真正的持久 transport 由底部 Desktop Player 承担，本页不再复制一整套控制键。
struct MacNowPlayingPage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var externalResult: AgentExternalMusicResult?
    @State private var isLoadingExternal = false

    var body: some View {
        let track = model.currentTrack
        HStack(spacing: AuralisSpacing.large) {
            ArtworkView(title: track.albumTitle, artworkKey: track.artworkKey,
                        colors: theme.colorTokens, size: 300, cornerRadius: 18)
                .frame(width: 300, height: 300)

            VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
                Text(track.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                    .lineLimit(2)
                Text(track.artistName)
                    .font(.title3)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                if !track.albumTitle.isEmpty {
                    Text(track.albumTitle)
                        .font(.body)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }

                // 私人状态
                HStack(spacing: AuralisSpacing.medium) {
                    Button {
                        model.toggleDisliked(track)
                    } label: {
                        Label(model.isDisliked(track) ? "取消不喜欢" : "不喜欢",
                              systemImage: model.isDisliked(track) ? "heart.slash.fill" : "heart.slash")
                    }
                    Button {
                        model.toggleFavorite(track)
                    } label: {
                        Label(model.currentTrack.isFavorite ? "取消收藏" : "收藏",
                              systemImage: model.currentTrack.isFavorite ? "heart.fill" : "heart")
                    }
                }
                .buttonStyle(.bordered)

                Divider()

                // 公开音乐资料摘要
                Group {
                    if isLoadingExternal {
                        HStack(spacing: AuralisSpacing.small) {
                            ProgressView().controlSize(.small)
                            Text("正在按需查询公开音乐资料…")
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                    } else if let result = externalResult {
                        communityRow(.musicBrainz, result: result)
                        communityRow(.critiqueBrainz, result: result)
                        communityRow(.listenBrainz, result: result)
                    } else {
                        Text("公开音乐资料暂未加载。")
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }

                // 技术信息
                VStack(alignment: .leading, spacing: 4) {
                    if let codec = track.sourceInfo.normalizedCodec { infoLine("格式", codec.uppercased()) }
                    if let sampleRate = track.sourceInfo.sampleRate { infoLine("采样率", "\(sampleRate) Hz") }
                    if let bitRate = track.sourceInfo.bitRate { infoLine("码率", "\(bitRate) kbps") }
                    if let channels = track.sourceInfo.channelCount { infoLine("声道", "\(channels)") }
                }
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Spacer(minLength: 0)
        }
        .padding(AuralisSpacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colorTokens.background.color)
        .navigationTitle("正在播放")
        .task(id: track.id.rawValue) {
            await loadPublicEvidence()
        }
    }

    @ViewBuilder
    private func communityRow(_ source: CommunityMusicSource, result: AgentExternalMusicResult) -> some View {
        if let metric = result.metrics.value(for: source), metric.status == .available {
            NavigationLink {
                CommunityMusicDetailView(source: source, result: result, theme: theme)
            } label: {
                HStack {
                    Text(sourceTitle(source))
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Spacer()
                    Text(sourceSummary(metric))
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            }
        }
    }

    private func sourceTitle(_ source: CommunityMusicSource) -> String {
        switch source {
        case .musicBrainz: "MusicBrainz"
        case .critiqueBrainz: "CritiqueBrainz"
        case .listenBrainz: "ListenBrainz"
        }
    }

    private func sourceSummary(_ metric: CommunityMusicMetric) -> String {
        switch metric.source {
        case .musicBrainz:
            if let rating = metric.rating, let count = metric.ratingCount {
                return String(format: "%.1f / 5 · %d 次评分", rating, count)
            }
            return "有评分数据"
        case .critiqueBrainz:
            var parts: [String] = []
            if let rating = metric.rating, let count = metric.ratingCount {
                parts.append(String(format: "%.1f / 5 · %d 次评分", rating, count))
            }
            if let reviews = metric.reviewCount { parts.append("\(reviews) 篇评论") }
            return parts.isEmpty ? "有评论数据" : parts.joined(separator: " · ")
        case .listenBrainz:
            var parts: [String] = []
            if let listens = metric.listenCount { parts.append("\(listens) 次收听") }
            if let listeners = metric.listenerCount { parts.append("\(listeners) 位听众") }
            return parts.isEmpty ? "有收听数据" : parts.joined(separator: " · ")
        }
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
        }
    }

    private func loadPublicEvidence() async {
        guard model.hasCurrentTrack else { return }
        let track = model.currentTrack
        let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        isLoadingExternal = true
        defer { isLoadingExternal = false }
        externalResult = await model.musicEnrichment.enrich(track: track, globalID: gid)
    }
}

// MARK: - 不喜欢（Smart Collection）

/// macOS “不喜欢”收藏：表格列出所有 disliked 歌曲，允许双击播放、右键取消不喜欢。
struct MacDislikedPage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    @State private var tracks: [Track] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("不喜欢").font(.title2.bold())
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text("不喜欢的歌曲不会再出现在自动推荐中；仍可搜索、浏览与主动播放。")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer()
                if !tracks.isEmpty {
                    Button("播放全部") { model.playQueue(tracks) }
                    Button("随机播放") { model.playShuffledQueue(tracks) }
                }
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.medium)
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView("没有不喜欢的歌曲", systemImage: "heart.slash",
                                       description: Text("在播放页或右键菜单中把歌曲标记为不喜欢后，会显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacSongTable(tracks: tracks, selection: $selection, model: model, theme: theme)
            }
        }
        .background(theme.colorTokens.background.color)
        .task(id: model.catalog.activeServerID) { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let serverID = model.catalog.activeServerID else {
            tracks = []
            return
        }
        tracks = (try? await model.catalogCoordinator.store.dislikedTracks(serverID: serverID)) ?? []
    }
}

// MARK: - Recommendation Index V2 分类

/// macOS V2 分类浏览：Dimension → Value → 歌曲表格（只读，复用现有固定维度）。
struct MacV2CategoriesPage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    @State private var categories: [RecommendationIndexV2Category] = []
    @State private var isLoading = true
    @State private var selectedDimension: String?

    private var dimensions: [String] {
        Array(Set(categories.map(\.dimension))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("分类").font(.title2.bold())
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Spacer()
                Button("刷新") { Task { await load() } }
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.medium)
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if categories.isEmpty {
                ContentUnavailableView("还没有分类", systemImage: "square.grid.2x2",
                                       description: Text("在 AI 助手设置中完成推荐索引 V2 后，这里会按固定维度（情绪/场景/风格等）展示分类。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selectedDimension) {
                        ForEach(dimensions, id: \.self) { dimension in
                            Label(dimensionTitle(dimension), systemImage: "tag")
                                .tag(dimension)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 140)
                    Divider()
                    if let dimension = selectedDimension {
                        V2Categories(dimension: dimension, categories: categories.filter { $0.dimension == dimension },
                                         model: model, theme: theme, selection: $selection)
                    } else {
                        ContentUnavailableView("选择一个维度", systemImage: "tag",
                                               description: Text("从左侧选择维度查看分类。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.colorTokens.background.color)
        .task(id: model.catalog.activeServerID) { await load() }
    }

    private func dimensionTitle(_ dimension: String) -> String {
        switch dimension {
        case "mood": "情绪"
        case "scene": "场景"
        case "vocal": "人声"
        case "texture": "质感"
        case "style": "风格"
        case "energy": "能量"
        case "tempo": "节奏"
        case "acousticness": "原声度"
        case "danceability": "舞动感"
        default: dimension
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let serverID = model.catalog.activeServerID else {
            categories = []
            return
        }
        categories = (try? await model.catalogCoordinator.store.recommendationIndexV2Categories(serverID: serverID)) ?? []
    }
}

/// 单个 V2 维度下的 Value → 歌曲表格。
private struct V2Categories: View {
    let dimension: String
    let categories: [RecommendationIndexV2Category]
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    @State private var selectedCategory: RecommendationIndexV2Category?
    @State private var tracks: [Track] = []

    var body: some View {
        HSplitView {
            List(categories, selection: $selectedCategory) { category in
                HStack {
                    Text(category.value)
                    Spacer()
                    Text("\(category.trackCount)")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                .tag(category)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 140)
            Divider()
            if let category = selectedCategory {
                MacSongTable(tracks: tracks, selection: $selection, model: model, theme: theme)
                    .task(id: category.id) { await loadTracks(category) }
            } else {
                ContentUnavailableView("选择一个分类", systemImage: "tag",
                                       description: Text("从左侧选择分类查看歌曲。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadTracks(_ category: RecommendationIndexV2Category) async {
        guard let serverID = model.catalog.activeServerID else {
            tracks = []
            return
        }
        tracks = (try? await model.catalogCoordinator.store.recommendationIndexV2Tracks(
            serverID: serverID, dimension: category.dimension, value: category.value
        )) ?? []
    }
}
#endif
