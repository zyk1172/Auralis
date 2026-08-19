#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 「流派」：简单列表，Toolbar inline 标题。
struct MacGenresView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    var body: some View {
        List(model.catalog.genres.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { genre in
            Button {
                onNavigate(.genre(genre))
            } label: {
                HStack {
                    Image(systemName: "music.quarternote.3")
                        .foregroundStyle(theme.colorTokens.accent.color)
                        .frame(width: 24)
                    Text(genre.name)
                    Spacer()
                    Text("\(genre.songCount) 首")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
        .navigationTitle(String(localized: "流派", bundle: .module))
    }
}
#endif