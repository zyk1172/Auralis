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
        let available = Set(categories.map(\.dimension))
        return Self.dimensionOrder.filter { available.contains($0) }
    }

    private static let dimensionOrder = [
        "mood", "scene", "style", "vocal", "texture", "energy", "tempo", "acousticness", "danceability", "tag",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if dimensions.isEmpty {
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
                        .id(dimension)
                    } else {
                        ContentUnavailableView("选择一个维度", systemImage: "tag",
                                               description: Text("从左侧选择维度查看分类。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("分类")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
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
            selectedDimension = nil
            return
        }
        // 固定维度保持有界加载；只用一条 limit=1 的分页查询判断 AI 标签入口是否可达。
        var loaded = (try? await model.catalogCoordinator.store.recommendationIndexV2Categories(
            serverID: serverID,
            dimensions: RecommendationIndexV2.fixedDimensions
        )) ?? []
        let hasTags = (try? await model.catalogCoordinator.store.recommendationIndexV2TagCatalog(
            serverID: serverID, limit: 1, offset: 0
        ).items.isEmpty == false) ?? false
        guard model.catalog.activeServerID == serverID, !Task.isCancelled else { return }
        if hasTags {
            // AI 标签由子页分页载入；这里只放一个维度哨兵，使正常入口可以到达。
            loaded.append(.init(dimension: "tag", value: "", trackCount: 0))
        }
        let loadedDimensions = Set(loaded.map(\.dimension))
        // List 的 selection 必须先于数据源失效，避免 SwiftUI 用旧对象重建右侧表格。
        self.selectedDimension = MacV2BrowserState.selectionAfterReplacing(
            selectedID: selectedDimension,
            availableIDs: loadedDimensions
        )
        categories = loaded
    }
}

/// 单个 V2 维度下的 Value → 歌曲表格。
private struct MacV2DimensionPane: View {
    let dimension: String
    let categories: [RecommendationIndexV2Category]
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }
    @State private var selectedCategoryID: String?
    @State private var selection: Set<GlobalID> = []
    @State private var tracks: [Track] = []
    @State private var isLoadingTracks = false
    @State private var trackLoadError: String?
    /// AI 标签独立浏览：offset 游标分页（读取优化，不代表标签数量限制）。
    @State private var tagQuery = ""
    @State private var tagNextOffset: Int? = 0
    @State private var isLoadingMoreTags = false
    private static let tagPageSize = 30

    /// 展示给列表的分类：tag 维度按需搜索/分页加载，其余维度用传入的全部 categories。
    @State private var displayedCategories: [RecommendationIndexV2Category] = []

    private var isTagDimension: Bool { dimension == "tag" }
    private var categoryDataID: String {
        "\(dimension)|\(categories.map(\.id).joined(separator: "|"))"
    }
    private var selectedCategory: RecommendationIndexV2Category? {
        guard let selectedCategoryID else { return nil }
        return displayedCategories.first { $0.id == selectedCategoryID }
    }

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
                List(displayedCategories, selection: $selectedCategoryID) { category in
                    HStack {
                        Text(category.value)
                        Spacer()
                        Text("\(category.trackCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(category.id)
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
            if isLoadingTracks, selectedCategory != nil {
                ProgressView("正在载入歌曲…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let trackLoadError, selectedCategory != nil {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "无法载入该分类",
                        systemImage: "exclamationmark.triangle",
                        description: Text(trackLoadError)
                    )
                    Button("重试") {
                        if let category = selectedCategory { Task { await loadTracks(category) } }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedCategory != nil, tracks.isEmpty {
                ContentUnavailableView("这个分类目前没有歌曲", systemImage: "music.note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedCategory != nil {
                MacSongTable(tracks: tracks, selection: $selection, model: model, theme: theme, onNavigate: onNavigate)
            } else {
                ContentUnavailableView("选择一个分类", systemImage: "tag",
                                       description: Text("从左侧选择分类查看歌曲。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: categoryDataID) { await initialLoad() }
        .task(id: selectedCategoryID) {
            guard let selectedCategory else {
                tracks = []
                selection.removeAll()
                trackLoadError = nil
                isLoadingTracks = false
                return
            }
            await loadTracks(selectedCategory)
        }
    }

    private func loadTagPage(reset: Bool) async {
        guard isTagDimension, let serverID = model.catalog.activeServerID else { return }
        if reset {
            resetSelection()
            displayedCategories = []
            tagNextOffset = 0
        }
        guard let offset = tagNextOffset else {
            isLoadingMoreTags = false
            return
        }
        isLoadingMoreTags = true
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = (try? await model.catalogCoordinator.store.recommendationIndexV2TagCatalog(
            serverID: serverID, query: query.isEmpty ? nil : query, limit: Self.tagPageSize, offset: offset
        )) ?? RecommendationIndexV2TagPage(items: [], nextOffset: nil, hasMore: false)
        guard !Task.isCancelled, model.catalog.activeServerID == serverID else { return }
        var merged = reset ? page.items : displayedCategories + page.items
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.id).inserted }
        let selectedAfterReplacement = MacV2BrowserState.selectionAfterReplacing(
            selectedID: selectedCategoryID,
            availableIDs: Set(merged.map(\.id))
        )
        if selectedAfterReplacement == nil, selectedCategoryID != nil {
            resetSelection()
        }
        displayedCategories = merged
        tagNextOffset = page.nextOffset
        isLoadingMoreTags = false
    }

    private func loadTracks(_ category: RecommendationIndexV2Category) async {
        let expectedCategoryID = category.id
        guard let expectedServerID = model.catalog.activeServerID else {
            resetSelection()
            return
        }
        isLoadingTracks = true
        trackLoadError = nil
        do {
            let loaded = try await model.catalogCoordinator.store.recommendationIndexV2Tracks(
                serverID: expectedServerID, dimension: category.dimension, value: category.value
            )
            guard MacV2BrowserState.acceptsTrackResult(
                expectedCategoryID: expectedCategoryID,
                selectedCategoryID: selectedCategoryID,
                expectedServerID: expectedServerID,
                activeServerID: model.catalog.activeServerID,
                isCancelled: Task.isCancelled
            ) else { return }
            let clean = serverAwareUniqueTracks(loaded)
            tracks = clean
            selection = MacV2BrowserState.cleanedSelection(
                selection,
                validTrackIDs: Set(clean.map { GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue) })
            )
        } catch is CancellationError {
            return
        } catch {
            guard selectedCategoryID == expectedCategoryID,
                  model.catalog.activeServerID == expectedServerID
            else { return }
            trackLoadError = error.localizedDescription
            tracks = []
            selection.removeAll()
        }
        if selectedCategoryID == expectedCategoryID, model.catalog.activeServerID == expectedServerID {
            isLoadingTracks = false
        }
    }

    @MainActor
    private func resetSelection() {
        selectedCategoryID = nil
        selection.removeAll()
        tracks.removeAll()
        trackLoadError = nil
        isLoadingTracks = false
    }

    private func serverAwareUniqueTracks(_ tracks: [Track]) -> [Track] {
        var seen = Set<GlobalID>()
        return tracks.filter { seen.insert(GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue)).inserted }
    }
}

private extension MacV2DimensionPane {
    /// 初次出现：tag 维度走 tag_catalog 加载，其余维度直接用传入 categories。
    func initialLoad() async {
        resetSelection()
        if isTagDimension {
            displayedCategories = []
            await loadTagPage(reset: true)
        } else {
            if let selectedCategoryID, !categories.contains(where: { $0.id == selectedCategoryID }) {
                resetSelection()
            }
            displayedCategories = categories
        }
    }
}
#endif
