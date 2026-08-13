#if os(macOS)
import Domain
import SwiftUI
import ThemeEngine

/// 右侧面板：歌词 / 队列。`mode` 是值（由 Player/Toolbar 决定），面板内不做 segmented 切换。
struct MacRightPanel: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let mode: MacRightPanelMode

    @ObservedObject private var playbackStore: PlaybackStore

    init(model: AuralisAppModel, theme: BuiltInTheme, mode: MacRightPanelMode) {
        self.model = model
        self.theme = theme
        self.mode = mode
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch mode {
            case .lyrics: lyricsContent
            case .queue: queueContent
            }
        }
        .inspectorColumnWidth(min: MacUIVisualTokens.RightPanel.minWidth, ideal: MacUIVisualTokens.RightPanel.idealWidth, max: MacUIVisualTokens.RightPanel.maxWidth)
        .task(id: lyricLoadID) {
            if mode == .lyrics {
                model.ensureLyricsLoadedForCurrentTrack()
            }
        }
    }

    private var lyricLoadID: String {
        "\(mode.rawValue):\(model.currentTrack.serverID):\(model.currentTrack.id.rawValue)"
    }

    private var header: some View {
        HStack {
            Text(mode == .lyrics ? "歌词" : "待播队列")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 歌词

    private var lyricsContent: some View {
        Group {
            if let lyrics = model.currentLyrics, !lyrics.lines.isEmpty {
                let activeIndex = currentLyricIndex
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                                let isCurrent = index == activeIndex
                                Text(line.text)
                                    .font(.system(size: isCurrent ? 23 : 18, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? theme.colorTokens.accent.color : Color.primary.opacity(0.72))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let start = line.startTime {
                                            model.seek(toProgress: min(1, max(0, start / max(model.currentTrack.duration, 1))))
                                        }
                                    }
                                    .id(index)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(line.text)
                                    .accessibilityValue(isCurrent ? "当前歌词" : "")
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                    }
                    // 只在当前歌词真正变化时滚动，避免随播放位置高频动画。
                    .onChange(of: currentLyricIndex) { _, index in
                        guard let index else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            } else {
                ContentUnavailableView("暂无歌词", systemImage: "quote.bubble", description: Text("当前歌曲没有可显示的歌词。"))
            }
        }
    }

    private var currentLyricIndex: Int? {
        guard let lyrics = model.currentLyrics else { return nil }
        let position = playbackStore.position
        var index: Int?
        for (i, line) in lyrics.lines.enumerated() {
            if let start = line.startTime, start <= position + 0.15 {
                index = i
            }
        }
        return index
    }

    // MARK: - 队列

    private var currentIndex: Int? { model.currentQueueIndex }
    private var upcoming: [Track] { model.upcomingTracks }

    private var queueContent: some View {
        List {
            if model.hasCurrentTrack {
                Section("正在播放") {
                    queueRow(model.currentTrack, isCurrent: true)
                }
            }
            Section {
                if upcoming.isEmpty {
                    Text("没有待播放的歌曲。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(upcoming.enumerated()), id: \.element.macGlobalID) { offset, track in
                        queueRow(track, isCurrent: false)
                            .contextMenu {
                                Button("立即播放") { model.selectAndPlay(track) }
                                Button("从队列移除") { removeUpcoming(at: [offset]) }
                            }
                    }
                    .onMove { source, destination in
                        moveUpcoming(from: source, to: destination)
                    }
                    .onDelete { offsets in
                        removeUpcoming(at: offsets)
                    }
                }
            } header: {
                HStack {
                    Text("播放下一首")
                    Spacer()
                    if !upcoming.isEmpty {
                        Button("清空") { model.clearUpcoming() }
                            .buttonStyle(.link)
                    }
                }
            }
            if !historyTracks.isEmpty {
                Section("历史记录") {
                    ForEach(historyTracks) { track in
                        queueRow(track, isCurrent: false)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// 近似历史：最近播放记录（最近在前）。非完整历史，仅用于上下文参考。
    private var historyTracks: [Track] {
        Array(model.recentlyPlayedTracks.prefix(8))
    }

    private func queueRow(_ track: Track, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            ArtworkView(title: track.albumTitle, artworkKey: track.artworkKey, colors: theme.colorTokens, size: 32, cornerRadius: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.accent.color)
                    .accessibilityLabel("正在播放")
            } else {
                Text(MacFormat.time(track.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.selectAndPlay(track)
        }
    }

    /// 待播队列显示下标 → 真实队列下标（current 之后）。
    private func realQueueIndex(_ displayOffset: Int) -> Int {
        (currentIndex ?? -1) + 1 + displayOffset
    }

    private func removeUpcoming(at offsets: IndexSet) {
        let real = IndexSet(offsets.map { realQueueIndex($0) })
        model.removeFromQueue(atOffsets: real)
    }

    private func moveUpcoming(from source: IndexSet, to destination: Int) {
        guard let current = currentIndex else { return }
        let realSource = IndexSet(source.map { current + 1 + $0 })
        let realDestination = current + 1 + destination
        model.moveQueue(from: realSource, to: realDestination)
    }
}
#endif
