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
    @State private var visibleAlbums: [Album] = []

    enum AlbumSort: String, CaseIterable, Identifiable {
        case title, artist, year
        var id: String { rawValue }
        var title: String {
            switch self {
            case .title: "标题"
            case .artist: "艺术家"
            case .year: "年份"
            }
        }
    }

    /// 只在目录、查询或排序真正改变时派生网格数据；播放进度的高频发布不会再
    /// 让数千张专辑在每次 body 求值时重新 filter + sort。
    private var derivationKey: String {
        "\(model.catalogRevision)|\(sortOrder.rawValue)|\(localSearch)"
    }

    private func rebuildVisibleAlbums() {
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
        }
        visibleAlbums = result
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPageSearchHeader(text: $localSearch, prompt: "在专辑中查找", accessory: {
                Menu {
                    Picker("排序方式", selection: $sortOrder) {
                        ForEach(AlbumSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            })
            Divider()
            GeometryReader { geo in
                let metrics = MacArtworkGridMetrics.albums(availableWidth: geo.size.width)
                let columns = Array(repeating: GridItem(.fixed(metrics.itemWidth), spacing: metrics.spacing), count: metrics.columnCount)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 28) {
                        ForEach(visibleAlbums) { album in
                            MacAlbumTile(
                                album: album,
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
            }
        }
        .navigationTitle(String(localized: "专辑", bundle: .module))
        .task(id: derivationKey) {
            rebuildVisibleAlbums()
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