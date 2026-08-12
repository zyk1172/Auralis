#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 「歌曲」：原生 Table（默认列 标题/艺术家/专辑/时长/收藏），
/// 年份/流派/格式 通过「显示选项」开启，选择持久化。
struct MacSongsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @AppStorage("auralis.mac.songs.showYear") private var showYear = false
    @AppStorage("auralis.mac.songs.showGenre") private var showGenre = false
    @AppStorage("auralis.mac.songs.showFormat") private var showFormat = false

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(title: "歌曲") {
                Menu {
                    Toggle("年份", isOn: $showYear)
                    Toggle("流派", isOn: $showGenre)
                    Toggle("格式", isOn: $showFormat)
                } label: {
                    Label("显示选项", systemImage: "sidebar.right")
                }
                Button {
                    model.playShuffledQueue(model.catalog.tracks.filter { !model.isDisliked($0) })
                } label: {
                    Label("随机播放", systemImage: "shuffle")
                }
            }
            Divider()
            MacSongTable(
                tracks: model.catalog.tracks,
                selection: $selection,
                model: model,
                theme: theme,
                onNavigate: onNavigate,
                numberText: { _ in nil },
                showYearColumn: showYear,
                showGenreColumn: showGenre,
                showFormatColumn: showFormat
            )
        }
    }
}
#endif
