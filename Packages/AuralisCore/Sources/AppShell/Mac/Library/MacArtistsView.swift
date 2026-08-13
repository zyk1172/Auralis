#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 「艺术家」：资料库内二级 split（左侧紧凑列表 + 右侧详情）+ 本地搜索。
struct MacArtistsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var selectedArtist: Artist?
    @State private var localSearch = ""

    private var artists: [Artist] {
        let q = localSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.catalog.artists
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPageSearchHeader(text: $localSearch, prompt: "在艺术家中查找")
            Divider()
            HSplitView {
                List(selection: $selectedArtist) {
                    ForEach(artists) { artist in
                        HStack(spacing: 10) {
                            ArtworkView(
                                title: artist.name,
                                artworkKey: artist.artworkKey,
                                colors: theme.colorTokens,
                                size: 28,
                                cornerRadius: 14
                            )
                            .accessibilityHidden(true)
                            Text(artist.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(artist.albumCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(artist)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 220, idealWidth: 260)

                if let artist = selectedArtist {
                    MacArtistView(artist: artist, model: model, theme: theme, selection: $selection, onNavigate: onNavigate)
                } else {
                    ContentUnavailableView("选择一个艺术家", systemImage: "person.2",
                                           description: Text("从左侧选择艺术家查看详情。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("艺术家")
    }
}
#endif
