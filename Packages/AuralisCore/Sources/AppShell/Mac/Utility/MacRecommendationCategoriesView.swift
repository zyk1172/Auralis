#if os(macOS)
import Domain
import Foundation
import LocalCatalog
import SwiftUI
import ThemeEngine

/// macOS 的分类浏览与 iOS 一致：所有分类直接平铺为卡片，而不是先选维度、再选分类。
/// 点击卡片后才推入歌曲页，避免在 HSplitView 中重建带选择状态的两层 List。
struct MacRecommendationCategoriesView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var categories: [RecommendationIndexCategory] = []
    @State private var isLoading = true
    private let gridColumns = [GridItem(.adaptive(minimum: 158), spacing: 14)]

    var body: some View {
        Group {
            if isLoading && categories.isEmpty {
                ProgressView { Text(String(localized: "正在读取本地分类…", bundle: .module)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if categories.isEmpty {
                ContentUnavailableView(
                    String(localized: "还没有分类", bundle: .module),
                    systemImage: "square.grid.2x2",
                    description: Text(String(localized: "在设置 → AI 与公开数据中完成推荐索引后，这里会按歌曲数量展示分类。", bundle: .module))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 14) {
                        ForEach(categories) { category in
                            categoryCard(category)
                        }
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
    private func categoryCard(_ category: RecommendationIndexCategory) -> some View {
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
                Text(String(localized: "\(category.trackCount) 首歌曲", bundle: .module))
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

    private func load() async {
        guard let serverID = model.catalog.activeServerID else {
            categories = []
            isLoading = false
            return
        }
        isLoading = true
        let fixedCategories = (try? await model.catalogCoordinator.store.recommendationIndexCategories(
            serverID: serverID,
            dimensions: RecommendationIndex.fixedDimensions
        )) ?? []
        guard model.catalog.activeServerID == serverID, !Task.isCancelled else { return }
        categories = RecommendationBrowserState.categoriesSortedByTrackCount(fixedCategories)
        isLoading = false
    }
}

/// 单个分类的歌曲页。ArtworkStore 在此处重新显式注入，避免导航/布局重建后
/// ArtworkView 从缺失的 SwiftUI 环境读取对象而触发主线程断言。
struct MacRecommendationCategoryTracksView: View {
    let category: RecommendationIndexCategory
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
                ProgressView { Text(String(localized: "正在载入歌曲…", bundle: .module)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        String(localized: "无法载入该分类", bundle: .module),
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                    Button(String(localized: "重试", bundle: .module)) { Task { await loadTracks() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView(String(localized: "这个分类目前没有歌曲", bundle: .module), systemImage: "music.note")
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
            let loaded = try await model.catalogCoordinator.store.recommendationIndexTracks(
                serverID: serverID,
                dimension: category.dimension,
                value: category.value
            )
            guard model.catalog.activeServerID == serverID, !Task.isCancelled else { return }
            tracks = loaded
            tracksRevision &+= 1
            selection = RecommendationBrowserState.cleanedSelection(
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

extension RecommendationIndexCategory {
    var macCategoryTitle: String {
        let dimension: String
        switch self.dimension {
        case "mood": dimension = String(localized: "情绪", bundle: .module)
        case "scene": dimension = String(localized: "场景", bundle: .module)
        case "theme": dimension = String(localized: "主题", bundle: .module)
        case "genre": dimension = String(localized: "类型", bundle: .module)
        case "style": dimension = String(localized: "风格", bundle: .module)
        case "vocal": dimension = String(localized: "人声", bundle: .module)
        case "instrument": dimension = String(localized: "乐器", bundle: .module)
        case "texture": dimension = String(localized: "质感", bundle: .module)
        case "rhythm": dimension = String(localized: "节奏", bundle: .module)
        case "energy": dimension = String(localized: "能量", bundle: .module)
        case "tempo": dimension = String(localized: "速度", bundle: .module)
        case "acousticness": dimension = String(localized: "原声感", bundle: .module)
        case "danceability": dimension = String(localized: "舞动性", bundle: .module)
        case "instrumentalness": dimension = String(localized: "器乐性", bundle: .module)
        case "liveness": dimension = String(localized: "现场感", bundle: .module)
        case "speechiness": dimension = String(localized: "人声密度", bundle: .module)
        case "valence": dimension = String(localized: "情感正负", bundle: .module)
        case "complexity": dimension = String(localized: "复杂度", bundle: .module)
        default: dimension = self.dimension
        }
        let suffix: String
        switch self.dimension {
        case "energy": suffix = "\(value)/10"
        case "tempo", "acousticness", "danceability", "instrumentalness", "liveness", "speechiness", "valence", "complexity": suffix = "\(value)/5"
        default: suffix = value
        }
        return String(localized: "\(dimension) · \(suffix)", bundle: .module)
    }

    var macCategorySymbol: String {
        switch dimension {
        case "mood": "face.smiling"
        case "scene": "location"
        case "theme": "theatermasks"
        case "genre": "music.quarternote.3"
        case "style": "music.note.list"
        case "vocal": "mic"
        case "instrument": "pianokeys"
        case "texture": "waveform"
        case "rhythm": "metronome"
        case "energy": "bolt"
        case "tempo": "metronome"
        case "acousticness": "guitars"
        case "danceability": "figure.dance"
        case "instrumentalness": "waveform.path"
        case "liveness": "person.wave.2"
        case "speechiness": "text.bubble"
        case "valence": "face.smiling.inverse"
        case "complexity": "circle.grid.cross"
        default: "tag"
        }
    }
}
#endif
