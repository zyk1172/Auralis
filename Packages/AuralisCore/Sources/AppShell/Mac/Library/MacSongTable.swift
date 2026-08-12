#if os(macOS)
import DesignSystem
import LocalCatalog
import SwiftUI
import ThemeEngine
import Domain

/// Apple Music 式歌曲 Table 行：id 为 GlobalID（跨服务器稳定选择身份）。
struct MacSongRow: Identifiable {
    let id: GlobalID
    let track: Track

    var title: String { track.title }
    var artistName: String { track.artistName }
    var albumTitle: String { track.albumTitle }
    var duration: TimeInterval { track.duration }
    var year: Int { track.year ?? 0 }
    var genre: String { (track.genres.first ?? "") }
    var format: String { track.effectiveCodec ?? "" }
    var favorite: Bool { track.isFavorite }
}

/// 统一 Mac 歌曲 Table：sortable / resizable / 多选 / 双击播放 / 右键菜单。
struct MacSongTable: View {
    let tracks: [Track]
    @Binding var selection: Set<GlobalID>
    let model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacRoute) -> Void = { _ in }
    var numberText: (Track) -> String? = { _ in nil }
    var showAlbumColumn = true
    var showYearColumn = true
    var showGenreColumn = true
    var showFormatColumn = true
    var showArtwork = true
    var rowHeight: CGFloat = 40

    @State private var sortOrder: [KeyPathComparator<MacSongRow>] = [
        KeyPathComparator(\.title, order: .forward)
    ]

    private var rows: [MacSongRow] {
        tracks.map { MacSongRow(id: GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue), track: $0) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("#") { row in
                if let text = numberText(row.track) {
                    Text(text)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 32, ideal: 40, max: 48)
            TableColumn("标题", value: \.title) { row in
                titleCell(row)
            }
            .width(min: 180, ideal: 260)
            TableColumn("艺术家", value: \.artistName) { row in
                Text(row.track.artistName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 200)
            if showAlbumColumn {
                TableColumn("专辑", value: \.albumTitle) { row in
                    Text(row.track.albumTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 140, ideal: 200)
            }
            TableColumn("时长", value: \.duration) { row in
                Text(MacFormat.time(row.track.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 64, max: 80)
            if showYearColumn {
                TableColumn("年份", value: \.year) { row in
                    Text(row.track.year.map(String.init) ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 48, ideal: 60, max: 76)
            }
            if showGenreColumn {
                TableColumn("流派", value: \.genre) { row in
                    Text(row.track.genres.first ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 140)
            }
            if showFormatColumn {
                TableColumn("格式", value: \.format) { row in
                    if let codec = MacFormat.codec(row.track) {
                        Text(codec).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .width(min: 56, ideal: 64, max: 84)
            }
            TableColumn("收藏") { row in
                Image(systemName: row.track.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(row.track.isFavorite ? theme.colorTokens.accent.color : Color.secondary.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 44, max: 48)
        }
        .environment(\.defaultMinListRowHeight, rowHeight)
        .contextMenu(forSelectionType: GlobalID.self) { ids in
            if let gid = ids.first, let track = model.track(for: gid) {
                macTrackMenuContent(track: track, model: model, onNavigate: onNavigate)
            } else if !ids.isEmpty {
                Button("播放所选 \(ids.count) 首") {
                    let chosen = ids.compactMap { model.track(for: $0) }
                    model.playQueue(chosen)
                }
                Button("加入队列") {
                    for gid in ids {
                        model.addToQueue(globalID: gid)
                    }
                }
                Button("下载") {
                    for gid in ids.compactMap({ model.track(for: $0) }) {
                        model.download(gid)
                    }
                }
            }
        } primaryAction: { ids in
            if let gid = ids.first, let track = model.track(for: gid) {
                model.selectAndPlay(track)
            }
        }
        .onTapGesture(count: 2) {
            if let gid = selection.first, let track = model.track(for: gid) {
                model.selectAndPlay(track)
            }
        }
        .onDeleteCommand {
            // 队列等场景由宿主处理；此处保持空实现避免系统默认删除行为。
        }
    }

    @ViewBuilder
    private func titleCell(_ row: MacSongRow) -> some View {
        HStack(spacing: 10) {
            if showArtwork {
                ArtworkView(
                    title: row.track.title,
                    artworkKey: row.track.artworkKey,
                    colors: theme.colorTokens,
                    size: 34,
                    cornerRadius: 4
                )
                .accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                if isCurrent(row.track) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.accent.color)
                        .accessibilityLabel("正在播放")
                }
                Text(row.track.title)
                    .font(.system(size: 13, weight: isCurrent(row.track) ? .semibold : .regular))
                    .foregroundStyle(isCurrent(row.track) ? theme.colorTokens.accent.color : Color.primary)
                    .lineLimit(1)
                if model.isDownloaded(row.track) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("已下载")
                }
            }
        }
    }

    private func isCurrent(_ track: Track) -> Bool {
        model.currentTrack.serverID == track.serverID && model.currentTrack.id == track.id
    }
}
#endif
