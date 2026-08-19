#if os(macOS)
import Domain
import Foundation
import LocalCatalog
import SwiftUI
import ThemeEngine

/// macOS 的分类浏览与 iOS 一致：所有分类直接平铺为卡片，而不是先选维度、再选分类。
/// 点击卡片后才推入歌曲页，避免在 HSplitView 中重建带选择状态的两层 List。
struct MacV2CategoriesView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var categories: [RecommendationIndexV2Category] = []
    @State private var aiTags: [RecommendationIndexV2Category] = []
    @State private var isLoading = true
    @State private var tagQuery = ""
    @State private var tagNextOffset: Int? = 0
    @State private var isLoadingMoreTags = false

    private static let tagPageSize = 30
    private let gridColumns = [GridItem(.adaptive(minimum: 158), spacing: 14)]

    var body: some View {
        Group {
            if isLoading && categories.isEmpty {
                ProgressView("正在读取本地分类…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if categories.isEmpty && aiTags.isEmpty {
                ContentUnavailableView(
                    "还没有分类",
                    systemImage: "square.grid.2x2",
                    description: Text(String(localized: "在设置 → AI 与公开数据中完成推荐索引 V2 后，这里会按歌曲数量展示分类。", bundle: .module))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 14) {
                        ForEach(categories) { category in
                            categoryCard(category)
                        }
                    }

                    if !aiTags.isEmpty || !tagQuery.isEmpty {
                        aiTagSection
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(String(localized: "分类", bundle: .module))
        // 顶部不留按钮：刷新按钮移除（可切换分类重进刷新）。
        .task(id: model.catalog.activeServerID) { await load() }
    }

    @ViewBuilder
    private func categoryCard(_ category: RecommendationIndexV2Category) -> some View {
        Button {
            onNavigate(.detail(.recommendationCategory(category)))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: category.macCategorySymbol)
                        .font(.title3)
                        .foregroundStyle(theme.colorTokens.accent.color)
                    Spacer(minLength: 0)
                    Text("\(category.trackCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(category.macCategoryTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text("\(category.trackCount) 首歌曲")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
            .background(theme.colorTokens.surface.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(category.macCategoryTitle)，\(category.trackCount) 首歌曲", bundle: .module))
    }

    private var aiTagSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "AI 标签", bundle: .module))
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索标签", text: $tagQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await loadTagPage(reset: true) } }
                    Button {
                        Task { await loadTagPage(reset: true) }
                    } label: {
                        Label(String(localized: "搜索", bundle: .module), systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .help("搜索标签")
                }
                .frame(maxWidth: 260)
            }

            LazyVGrid(columns: gridColumns, spacing: 14) {
                ForEach(aiTags) { category in
                    categoryCard(category)
                }
            }

            if tagNextOffset != nil {
                Button {
                    Task { await loadMoreTags() }
                } label: {
                    HStack(spacing: 8) {
                        if isLoadingMoreTags { ProgressView().controlSize(.small) }
                        Text(String(localized: "加载更多标签", bundle: .module))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingMoreTags)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 26)
    }

    private func load() async {
        guard let serverID = model.catalog.activeServerID else {
            categories = []
            aiTags = []
            isLoading = false
            return
        }
        isLoading = true
        let fixedCategories = (try? await model.catalogCoordinator.store.recommendationIndexV2Categories(
            serverID: serverID,
            dimensions: RecommendationIndexV2.fixedDimensions
        )) ?? []
        guard model.catalog.activeServerID == serverID, !Task.isCancelled else { return }
        categories = MacV2BrowserState.categoriesSortedByTrackCount(fixedCategories)
        isLoading = false
        await loadTagPage(reset: true)
    }

    private func loadTagPage(reset: Bool) async {
        guard let serverID = model.catalog.activeServerID else { return }
        if reset {
            aiTags = []
            tagNextOffset = 0
        }
        guard let offset = tagNextOffset else {
            isLoadingMoreTags = false
            return
        }
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = (try? await model.catalogCoordinator.store.recommendationIndexV2TagCatalog(
            serverID: serverID,
            query: query.isEmpty ? nil : query,
            limit: Self.tagPageSize,
            offset: offset
        )) ?? RecommendationIndexV2TagPage(items: [], nextOffset: nil, hasMore: false)
        guard model.catalog.activeServerID == serverID, !Task.isCancelled else { return }
        var merged = reset ? page.items : aiTags + page.items
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.id).inserted }
        aiTags = MacV2BrowserState.categoriesSortedByTrackCount(merged)
        tagNextOffset = page.nextOffset
        isLoadingMoreTags = false
    }

    private func loadMoreTags() async {
        guard !isLoadingMoreTags, tagNextOffset != nil else { return }
        isLoadingMoreTags = true
        await loadTagPage(reset: false)
    }
}

/// 单个分类的歌曲页。ArtworkStore 在此处重新显式注入，避免导航/布局重建后
/// ArtworkView 从缺失的 SwiftUI 环境读取对象而触发主线程断言。
struct MacV2CategoryTracksView: View {
    let category: RecommendationIndexV2Category
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var tracks: [Track] = []
    @State private var selection: Set<GlobalID> = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// 本地行内容修订号：loadTracks 真正落地新结果后递增，驱动 Table 重建。
    @State private var tracksRevision: UInt64 = 0

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在载入歌曲…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "无法载入该分类",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                    Button(String(localized: "重试", bundle: .module)) { Task { await loadTracks() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView("这个分类目前没有歌曲", systemImage: "music.note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacSongTable(
                    tracks: tracks,
                    selection: $selection,
                    model: model,
                    theme: theme,
                    onNavigate: onNavigate,
                    contentRevision: tracksRevision
                )
                .environment(\.artworkStore, model.artworkStore)
            }
        }
        .navigationTitle(category.macCategoryTitle)
        // 顶部不留按钮：刷新歌曲按钮移除。
        .task(id: "\(category.id)|\(model.catalog.activeServerID?.rawValue ?? "")") { await loadTracks() }
    }

    private func loadTracks() async {
        guard let serverID = model.catalog.activeServerID else {
            tracks = []
            selection.removeAll()
            loadError = nil
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        do {
            let loaded = try await model.catalogCoordinator.store.recommendationIndexV2Tracks(
                serverID: serverID,
                dimension: category.dimension,
                value: category.value
            )
            guard model.catalog.activeServerID == serverID, !Task.isCancelled else { return }
            tracks = loaded
            tracksRevision &+= 1
            selection = MacV2BrowserState.cleanedSelection(
                selection,
                validTrackIDs: Set(loaded.map(\.macGlobalID))
            )
        } catch is CancellationError {
            return
        } catch {
            guard model.catalog.activeServerID == serverID else { return }
            tracks = []
            selection.removeAll()
            loadError = error.localizedDescription
        }
        if model.catalog.activeServerID == serverID {
            isLoading = false
        }
    }
}

extension RecommendationIndexV2Category {
    var macCategoryTitle: String {
        let dimension: String
        switch self.dimension {
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
        default: dimension = self.dimension
        }
        let suffix: String
        switch self.dimension {
        case "energy": suffix = "\(value)/10"
        case "tempo", "acousticness", "danceability": suffix = "\(value)/5"
        default: suffix = value
        }
        return "\(dimension) · \(suffix)"
    }

    var macCategorySymbol: String {
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
        default: "tag"
        }
    }
}
#endif