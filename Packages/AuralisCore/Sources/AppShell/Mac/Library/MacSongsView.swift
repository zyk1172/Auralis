#if os(macOS)
import SwiftUI
import ThemeEngine
import Domain
import LocalCatalog

/// 「歌曲」：Apple Music 式原生 Table，全曲库高信息密度浏览。
struct MacSongsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(title: "歌曲", subtitle: "\(model.catalog.tracks.count) 首") {
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
                showYearColumn: false,
                showGenreColumn: false,
                showFormatColumn: false
            )
        }
    }
}
#endif
