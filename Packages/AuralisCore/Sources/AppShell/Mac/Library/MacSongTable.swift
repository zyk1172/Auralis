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
    var playCount: Int = 0
    var addedDate: Date? = nil

    var title: String { track.title }
    var artistName: String { track.artistName }
    var albumTitle: String { track.albumTitle }
    var duration: TimeInterval { track.duration }
    var year: Int { track.year ?? 0 }
    var genre: String { (track.genres.first ?? "") }
    var format: String { track.effectiveCodec ?? "" }
    var favorite: Bool { track.isFavorite }
    /// 添加日期排序键（TimeInterval，与 duration 列同型，避免 Date 触发 Table 类型检查限制）。
    var addedDateSort: TimeInterval { addedDate?.timeIntervalSince1970 ?? 0 }
    /// 添加日期文本（避免在 cell 内做 Date 格式化推断）。
    var addedDateText: String {
        addedDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
    }
}

/// Table 重建只依赖真正会改变行内容的 O(1) revision。播放进度每秒发布时这几个
/// 值保持不变，因此不会重新 map/sort 数万首歌曲。
struct MacSongRowsRevision: Hashable {
    let catalogRevision: UInt64
    let metadataRevision: UInt64
    /// 调用方提供的「行内容」修订号（如搜索过滤词变化时递增）；
    /// catalog 内容变化由 catalogRevision 覆盖。完全 O(1)，不再对 tracks 做 O(N) 哈希。
    let contentRevision: UInt64
}

/// 统一 Mac 歌曲 Table：sortable / resizable / 多选 / 双击播放 / 右键菜单。
struct MacSongTable: View {
    let tracks: [Track]
    @Binding var selection: Set<GlobalID>
    let model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }
    /// 行内容修订号（默认 0）：搜索过滤等「catalogRevision 不变但行内容变」的场景，
    /// 由调用方传入自己的内容 revision。catalog / metadata 变化由 model 侧的
    /// O(1) revision 自动覆盖。
    var contentRevision: UInt64 = 0
    var numberText: (Track) -> String? = { _ in nil }
    var showAlbumColumn = true
    var showYearColumn = true
    var showGenreColumn = true
    var showPlayCountColumn = false
    var showAddedDateColumn = false
    var showArtwork = true
    /// 集合页没有真实曲序时不保留空白的 # 列。
    var showIndexColumn = false
    var rowHeight: CGFloat = 40

    @State private var sortOrder: [KeyPathComparator<MacSongRow>] = [
        KeyPathComparator(\.title, order: .forward)
    ]
    @State private var baseRows: [MacSongRow] = []
    @State private var orderedRows: [MacSongRow] = []
    /// 排序后可见行的 Track 快照：仅在 rows 重建/排序变化时同步更新一次。
    /// 双击播放直接用它，**不再在每次点击事件里 map 整张表**。
    @State private var orderedTrackContext: [Track] = []
    /// 避免等价排序重复重建 context（基础上下文）的标记。
    @State private var lastContextRevision: UInt64 = 0

    private var rowsRevision: MacSongRowsRevision {
        .init(
            catalogRevision: model.catalogRevision,
            metadataRevision: model.libraryRowMetadataRevision,
            contentRevision: contentRevision
        )
    }

    var body: some View {
        Table(orderedRows, selection: $selection, sortOrder: $sortOrder) {
            if showIndexColumn {
                TableColumn("#") { row in
                    if let text = numberText(row.track) {
                        Text(text)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .width(min: 32, ideal: 40, max: 48)
            }
            TableColumn(String(localized: "标题", bundle: .module), value: \.title) { row in
                titleCell(row)
            }
            .width(min: 180, ideal: 260)
            TableColumn(String(localized: "艺术家", bundle: .module), value: \.artistName) { row in
                Text(row.track.artistName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 200)
            if showAlbumColumn {
                TableColumn(String(localized: "专辑", bundle: .module), value: \.albumTitle) { row in
                    Text(row.track.albumTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 140, ideal: 200)
            }
            TableColumn(String(localized: "时长", bundle: .module), value: \.duration) { row in
                Text(MacFormat.time(row.track.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 64, max: 80)
            if showYearColumn {
                TableColumn(String(localized: "年份", bundle: .module), value: \.year) { row in
                    Text(row.track.year.map(String.init) ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 48, ideal: 60, max: 76)
            }
            if showGenreColumn {
                TableColumn(String(localized: "流派", bundle: .module), value: \.genre) { row in
                    Text(row.track.genres.first ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 140)
            }
            if showPlayCountColumn {
                TableColumn(String(localized: "播放次数", bundle: .module), value: \.playCount) { row in
                    Text(row.playCount > 0 ? "\(row.playCount)" : "—")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 56, ideal: 64, max: 80)
            }
            if showAddedDateColumn {
                TableColumn(String(localized: "添加日期", bundle: .module), value: \.addedDateSort) { row in
                    Text(row.addedDateText)
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110, max: 130)
            }
            TableColumn(String(localized: "收藏", bundle: .module)) { row in
                Button {
                    model.toggleFavorite(row.track)
                } label: {
                    Image(systemName: row.track.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(row.track.isFavorite ? theme.colorTokens.accent.color : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help(row.track.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module))
                .accessibilityLabel(row.track.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 44, max: 48)
        }
        .environment(\.defaultMinListRowHeight, rowHeight)
        .contextMenu(forSelectionType: GlobalID.self) { ids in
            if ids.count == 1, let gid = ids.first, let track = model.track(for: gid) {
                macTrackMenuContent(track: track, model: model, onNavigate: onNavigate)
            } else if !ids.isEmpty {
                Button(L10n.playSelected(ids.count)) {
                    let chosen = ids.compactMap { model.track(for: $0) }
                    model.playQueue(chosen)
                }
                Button(String(localized: "加入队列", bundle: .module)) {
                    for gid in ids {
                        model.addToQueue(globalID: gid)
                    }
                }
                Button(String(localized: "下载", bundle: .module)) {
                    for gid in ids.compactMap({ model.track(for: $0) }) {
                        model.download(gid)
                    }
                }
            }
        } primaryAction: { ids in
            if let gid = ids.first, let track = model.track(for: gid) {
                // 双击/回车播放时把整张表（当前排序后的可见行）写入队列，
                // 与 iOS 列表点击同一机制：播放该首并自动续播表中其余歌曲。
                // 直接使用已缓存的 Track 上下文，避免在点击事件里 map 整张表。
                let context = orderedTrackContext.isEmpty ? tracks : orderedTrackContext
                model.playTrack(track, in: context)
            }
        }
        .onDeleteCommand {
            // 队列等场景由宿主处理；此处保持空实现避免系统默认删除行为。
        }
        .task(id: rowsRevision) { rebuildRows() }
        .onChange(of: sortOrder) { _, _ in
            orderedRows = baseRows.sorted(using: sortOrder)
            orderedTrackContext = orderedRows.map(\.track)
        }
    }

    @ViewBuilder
    private func titleCell(_ row: MacSongRow) -> some View {
        MacSongTitleCell(track: row.track, model: model, theme: theme, showArtwork: showArtwork)
    }

    private func rebuildRows() {
        baseRows = tracks.map { track in
            MacSongRow(
                id: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue),
                track: track,
                playCount: model.playCount(for: track),
                addedDate: model.addedDate(for: track)
            )
        }
        orderedRows = baseRows.sorted(using: sortOrder)
        orderedTrackContext = orderedRows.map(\.track)
    }
}

/// 标题 Cell：仅此子视图观察 PlaybackStore，避免 currentTrack 一变就让整个 10000 行 Table body 重新求值。
private struct MacSongTitleCell: View {
    let track: Track
    let model: AuralisAppModel
    let theme: BuiltInTheme
    let showArtwork: Bool
    @ObservedObject private var playbackStore: PlaybackStore
    init(track: Track, model: AuralisAppModel, theme: BuiltInTheme, showArtwork: Bool) {
        self.track = track
        self.model = model
        self.theme = theme
        self.showArtwork = showArtwork
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
    }
    private var isCurrent: Bool {
        playbackStore.currentTrack.serverID == track.serverID && playbackStore.currentTrack.id == track.id
    }
    var body: some View {
        HStack(spacing: 10) {
            if showArtwork {
                ArtworkView(
                    title: track.title,
                    artworkKey: track.artworkKey,
                    colors: theme.colorTokens,
                    size: 34,
                    cornerRadius: 4
                )
                .accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.accent.color)
                        .accessibilityLabel(String(localized: "正在播放", bundle: .module))
                }
                Text(track.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? theme.colorTokens.accent.color : Color.primary)
                    .lineLimit(1)
                if model.isDownloaded(track) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "已下载", bundle: .module))
                }
            }
        }
    }
}
#endif