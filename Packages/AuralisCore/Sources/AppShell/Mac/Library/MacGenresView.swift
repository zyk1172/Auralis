#if os(macOS)
import SwiftUI
import ThemeEngine

/// 「流派」：保持简单 —— 列表 / 网格，不做彩色卡片墙。
struct MacGenresView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacRoute) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(title: "流派", subtitle: "\(model.catalog.genres.count) 个")
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
        }
    }
}
#endif
