#if os(macOS)
import Domain
import Foundation
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
    /// 搜索派生结果：无搜索时直接等于 catalog.tracks；有搜索时 120ms debounce +
    /// 后台过滤，避免输入期间每个字符都在 body 里全库 filter。
    @State private var visibleTracks: [Track] = []
    @State private var searchGeneration: UInt64 = 0
    /// 真正提交搜索结果的修订号：只在结果落地后递增，用于驱动 Table 重建。
    /// 不能用 localSearch.hashValue——搜索词一变 revision 就先跳，
    /// 后台结果 120ms 后才落地，会导致 Table 显示上一轮旧结果。
    @State private var visibleTracksRevision: UInt64 = 0
    @AppStorage("auralis.mac.songs.showYear") private var showYear = false
    @AppStorage("auralis.mac.songs.showGenre") private var showGenre = false
    @AppStorage("auralis.mac.songs.showPlayCount") private var showPlayCount = false
    @AppStorage("auralis.mac.songs.showAddedDate") private var showAddedDate = false

    private var filteredTracks: [Track] { visibleTracks }

    /// 提交搜索结果：只有仍是最新一代时才落地，并递增内容修订号驱动 Table 重建。
    private func commitVisibleTracks(_ tracks: [Track], generation: UInt64) {
        guard generation == searchGeneration else { return }
        visibleTracks = tracks
        visibleTracksRevision &+= 1
    }

    private func updateVisibleTracks() {
        searchGeneration &+= 1
        let generation = searchGeneration
        let tracks = model.catalog.tracks
        let query = localSearch.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            commitVisibleTracks(tracks, generation: generation)
            return
        }

        Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard generation == searchGeneration else { return }
            let result = await Task.detached(priority: .userInitiated) {
                tracks.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.artistName.localizedCaseInsensitiveContains(query)
                        || $0.albumTitle.localizedCaseInsensitiveContains(query)
                }
            }.value
            commitVisibleTracks(result, generation: generation)
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
                contentRevision: visibleTracksRevision,
                numberText: { _ in nil },
                showYearColumn: showYear,
                showGenreColumn: showGenre,
                showPlayCountColumn: showPlayCount,
                showAddedDateColumn: showAddedDate
            )
        }
        .navigationTitle("歌曲")
        .onAppear { updateVisibleTracks() }
        .onChange(of: localSearch) { _, _ in updateVisibleTracks() }
        .onChange(of: model.catalogRevision) { _, _ in updateVisibleTracks() }
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
