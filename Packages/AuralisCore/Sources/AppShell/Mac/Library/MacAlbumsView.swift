#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 「专辑」（REFERENCE_A）：Toolbar inline 标题 + 排序 + 「在专辑中查找」本地搜索；
/// 响应式大封面 Grid（1536 窗口下 4 列、Artwork ≈267pt），无内容大标题。
struct MacAlbumsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var localSearch = ""
    @State private var sortOrder: AlbumSort = .title

    enum AlbumSort: String, CaseIterable, Identifiable {
        case title, artist, year, recentlyAdded
        var id: String { rawValue }
        var title: String {
            switch self {
            case .title: "标题"
            case .artist: "艺术家"
            case .year: "年份"
            case .recentlyAdded: "最近添加"
            }
        }
    }

    private var filteredAlbums: [Album] {
        var result = model.catalog.albums
        let q = localSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(q) || $0.artistName.localizedCaseInsensitiveContains(q)
            }
        }
        switch sortOrder {
        case .title:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            result.sort { $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending }
        case .year:
            result.sort {
                let ly = $0.year ?? Int.min
                let ry = $1.year ?? Int.min
                return ly != ry ? ly > ry : $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .recentlyAdded:
            // 以本地曲目库中的专辑出现顺序近似；保持 Catalog 顺序稳定即可。
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return result
    }

    var body: some View {
        ScrollView {
            GeometryReader { geo in
                let metrics = MacArtworkGridMetrics.albums(availableWidth: geo.size.width)
                let columns = Array(repeating: GridItem(.fixed(metrics.itemWidth), spacing: metrics.spacing), count: metrics.columnCount)
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(filteredAlbums) { album in
                        MacAlbumTile(
                            album: album,
                            model: model,
                            theme: theme,
                            size: metrics.itemWidth,
                            onOpen: { onNavigate(.album(album)) },
                            onPlay: { model.playQueue(MacLibraryQuery.albumTracks(album, model: model)) },
                            moreActions: albumMoreActions(album)
                        )
                    }
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.vertical, 20)
            }
            .frame(minHeight: 600)
        }
        .navigationTitle("专辑")
        .searchable(text: $localSearch, placement: .toolbar, prompt: "在专辑中查找")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("排序方式", selection: $sortOrder) {
                        ForEach(AlbumSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .help("排序")
                .accessibilityLabel("排序")
            }
        }
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
