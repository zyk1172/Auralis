#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 「歌曲」：原生 Table（默认列 标题/艺术家/专辑/时长/收藏）+ 本地搜索「在歌曲中查找」
/// + 显示选项（年份/流派/格式，持久化）。Toolbar inline 标题。
struct MacSongsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var localSearch = ""
    @AppStorage("auralis.mac.songs.showYear") private var showYear = false
    @AppStorage("auralis.mac.songs.showGenre") private var showGenre = false
    @AppStorage("auralis.mac.songs.showPlayCount") private var showPlayCount = false
    @AppStorage("auralis.mac.songs.showAddedDate") private var showAddedDate = false

    private var filteredTracks: [Track] {
        let q = localSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.catalog.tracks }
        return model.catalog.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.artistName.localizedCaseInsensitiveContains(q)
                || $0.albumTitle.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPageSearchHeader(text: $localSearch, prompt: "在歌曲中查找")
            Divider()
            MacSongTable(
                tracks: filteredTracks,
                selection: $selection,
                model: model,
                theme: theme,
                onNavigate: onNavigate,
                numberText: { _ in nil },
                showYearColumn: showYear,
                showGenreColumn: showGenre,
                showPlayCountColumn: showPlayCount,
                showAddedDateColumn: showAddedDate
            )
        }
        .navigationTitle("歌曲")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle("年份", isOn: $showYear)
                    Toggle("流派", isOn: $showGenre)
                    Toggle("播放次数", isOn: $showPlayCount)
                    Toggle("添加日期", isOn: $showAddedDate)
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("显示选项")
                .accessibilityLabel("显示选项")
                Button {
                    model.playShuffledQueue(filteredTracks.filter { !model.isDisliked($0) })
                } label: {
                    Image(systemName: "shuffle")
                }
                .help("随机播放")
                .accessibilityLabel("随机播放")
            }
        }
    }
}
#endif
