#if os(macOS)
import LocalCatalog
import SwiftUI
import ThemeEngine
import Domain

/// 分类（Recommendation Index V2）：Dimension → Value → Track Table。
/// 只读取已有索引，不建立第二套。
struct MacV2CategoriesView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }
    @State private var categories: [RecommendationIndexV2Category] = []
    @State private var isLoading = true
    @State private var selectedDimension: String?

    private var dimensions: [String] {
        Array(Set(categories.map(\.dimension))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(title: "分类", subtitle: "\(categories.count) 个分类") {
                Button {
                    Task { await load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if categories.isEmpty {
                ContentUnavailableView("还没有分类", systemImage: "square.grid.2x2",
                                       description: Text("在设置 → AI 与公开数据中完成推荐索引 V2 后，这里按固定维度（情绪/场景/风格等）展示分类。"))
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
                    .frame(minWidth: 150)
                    if let dimension = selectedDimension {
                        MacV2DimensionPane(
                            dimension: dimension,
                            categories: categories.filter { $0.dimension == dimension },
                            model: model, theme: theme, onNavigate: onNavigate
                        )
                    } else {
                        ContentUnavailableView("选择一个维度", systemImage: "tag",
                                               description: Text("从左侧选择维度查看分类。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
        case "tag": "AI 标签"
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
        // 父页面只加载有界固定维度；AI 标签由 tag 维度面板按需分页。
        categories = (try? await model.catalogCoordinator.store.recommendationIndexV2Categories(
            serverID: serverID,
            dimensions: RecommendationIndexV2.fixedDimensions
        )) ?? []
    }
}

/// 单个 V2 维度下的 Value → 歌曲表格。
private struct MacV2DimensionPane: View {
    let dimension: String
    let categories: [RecommendationIndexV2Category]
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }
    @State private var selectedCategory: RecommendationIndexV2Category?
    @State private var selection: Set<GlobalID> = []
    @State private var tracks: [Track] = []
    /// AI 标签独立浏览：offset 游标分页（读取优化，不代表标签数量限制）。
    @State private var tagQuery = ""
    @State private var tagNextOffset: Int? = 0
    @State private var isLoadingMoreTags = false
    private static let tagPageSize = 30

    /// 展示给列表的分类：tag 维度按需搜索/分页加载，其余维度用传入的全部 categories。
    @State private var displayedCategories: [RecommendationIndexV2Category] = []

    private var isTagDimension: Bool { dimension == "tag" }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if isTagDimension {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索标签", text: $tagQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await loadTagPage(reset: true) } }
                        Button {
                            Task { await loadTagPage(reset: true) }
                        } label: {
                            Label("搜索", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                        }
                    }
                    .padding(8)
                }
                List(displayedCategories, selection: $selectedCategory) { category in
                    HStack {
                        Text(category.value)
                        Spacer()
                        Text("\(category.trackCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(category)
                }
                .listStyle(.sidebar)
                if isTagDimension, tagNextOffset != nil {
                    Button {
                        Task { await loadTagPage(reset: false) }
                    } label: {
                        HStack {
                            if isLoadingMoreTags { ProgressView().controlSize(.small) }
                            Text("加载更多标签")
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding(6)
                }
            }
            .frame(minWidth: 150)
            if let category = selectedCategory {
                MacSongTable(tracks: tracks, selection: $selection, model: model, theme: theme, onNavigate: onNavigate)
                    .task(id: category.id) { await loadTracks(category) }
            } else {
                ContentUnavailableView("选择一个分类", systemImage: "tag",
                                       description: Text("从左侧选择分类查看歌曲。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: dimension) { await initialLoad() }
    }

    private func loadTagPage(reset: Bool) async {
        guard isTagDimension, let serverID = model.catalog.activeServerID else { return }
        if reset {
            displayedCategories = []
            tagNextOffset = 0
        }
        guard let offset = tagNextOffset else {
            isLoadingMoreTags = false
            return
        }
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = (try? await model.catalogCoordinator.store.recommendationIndexV2TagCatalog(
            serverID: serverID, query: query.isEmpty ? nil : query, limit: Self.tagPageSize, offset: offset
        )) ?? RecommendationIndexV2TagPage(items: [], nextOffset: nil, hasMore: false)
        var merged = reset ? page.items : displayedCategories + page.items
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.id).inserted }
        displayedCategories = merged
        tagNextOffset = page.nextOffset
        isLoadingMoreTags = false
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

private extension MacV2DimensionPane {
    /// 初次出现：tag 维度走 tag_catalog 加载，其余维度直接用传入 categories。
    func initialLoad() async {
        if isTagDimension {
            displayedCategories = []
            await loadTagPage(reset: true)
        } else {
            displayedCategories = categories
        }
    }
}
#endif
