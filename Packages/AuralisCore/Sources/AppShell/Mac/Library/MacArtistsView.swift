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

    /// Selection 只保存跨服务器稳定 ID。搜索、同步或服务器切换替换 backing
    /// collection 后，不会留下一个已经不在 List 中的旧 Artist value。
    @State private var selectedArtistID: GlobalID?
    @State private var localSearch = ""
    @State private var visibleArtists: [Artist] = []

    private var derivationKey: String {
        "\(model.catalogRevision)|\(localSearch)"
    }

    /// 红色化日志：只记录是否已有选中项，不输出原始 serverID/remoteID。
    private func redactedSelection(_ id: GlobalID?) -> String {
        id == nil ? "none" : "set"
    }

    private func rebuildVisibleArtists() {
        let q = localSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let artists = model.catalog.artists
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        visibleArtists = artists

        if let selectedArtistID {
            let remainsVisible = artists.contains { $0.macGlobalID == selectedArtistID }
            if !remainsVisible {
                self.selectedArtistID = nil
            }
        }

        MacUITrace.action(
            "MacArtistsView.rebuild",
            "visible=\(visibleArtists.count) artists=\(model.catalog.artists.count) "
                + "tracks=\(model.catalog.tracks.count) albums=\(model.catalog.albums.count) "
                + "rev=\(model.catalogRevision) selection=\(redactedSelection(selectedArtistID))"
        )
    }

    private var selectedArtist: Artist? {
        guard let selectedArtistID else { return nil }
        return visibleArtists.first { $0.macGlobalID == selectedArtistID }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPageSearchHeader(text: $localSearch, prompt: "在艺术家中查找")
            Divider()
            HSplitView {
                List(selection: $selectedArtistID) {
                    ForEach(visibleArtists, id: \.macGlobalID) { artist in
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
                        .tag(artist.macGlobalID)
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
        .onAppear {
            MacUITrace.action(
                "MacArtistsView.appear",
                "artists=\(model.catalog.artists.count) tracks=\(model.catalog.tracks.count) "
                    + "albums=\(model.catalog.albums.count) rev=\(model.catalogRevision) "
                    + "selection=\(redactedSelection(selectedArtistID))"
            )
        }
        .onChange(of: selectedArtistID) { _, newValue in
            MacUITrace.action(
                "MacArtistsView.select",
                "visible=\(visibleArtists.count) rev=\(model.catalogRevision) "
                    + "selection=\(redactedSelection(newValue))"
            )
        }
        .task(id: derivationKey) {
            rebuildVisibleArtists()
        }
    }
}
#endif
