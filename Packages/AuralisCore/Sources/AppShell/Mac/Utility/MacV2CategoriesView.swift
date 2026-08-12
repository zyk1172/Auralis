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
        categories = (try? await model.catalogCoordinator.store.recommendationIndexV2Categories(serverID: serverID)) ?? []
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

    var body: some View {
        HSplitView {
            List(categories, selection: $selectedCategory) { category in
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
