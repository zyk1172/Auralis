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
    @ObservedObject private var queueStore: PlaybackQueuePresentationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AuralisAppModel, theme: BuiltInTheme, mode: MacRightPanelMode) {
        self.model = model
        self.theme = theme
        self.mode = mode
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
        self._queueStore = ObservedObject(wrappedValue: model.queueStore)
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
            Text(mode == .lyrics ? String(localized: "歌词", bundle: .module) : String(localized: "待播队列", bundle: .module))
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
                                    .font(.system(size: 23, weight: isCurrent ? .semibold : .regular))
                                    .scaleEffect(isCurrent ? 1 : 18 / 23, anchor: .leading)
                                    .foregroundStyle(isCurrent ? theme.colorTokens.accent.color : Color.primary.opacity(0.72))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let start = line.startTime {
                                            model.seek(toProgress: min(1, max(0, start / max(model.effectivePlaybackDuration, 1))))
                                        }
                                    }
                                    .id(index)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(line.text)
                                    .accessibilityValue(isCurrent ? String(localized: "当前歌词", bundle: .module) : "")
                                    .animation(.easeInOut(duration: 0.16), value: isCurrent)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                    }
                    // 只在当前歌词真正变化时滚动，避免随播放位置高频动画。
                    .onChange(of: activeIndex) { _, index in
                        guard let index else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                    .task(id: "\(lyricLoadID)|\(lyrics.id)") {
                        guard let activeIndex else { return }
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            } else {
                ContentUnavailableView(String(localized: "暂无歌词", bundle: .module), systemImage: "quote.bubble", description: Text(String(localized: "当前歌曲没有可显示的歌词。", bundle: .module)))
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

    private var currentIndex: Int? { queueStore.currentIndex }
    /// R05：待播队列项（带独立 UUID 身份），重复歌曲可安全渲染与移除。
    /// 返回 `ArraySlice`，**不复制**——队列上万首时避免 `Array(dropFirst)` 全量拷贝。
    private var upcomingEntries: ArraySlice<QueueEntry> {
        queueStore.entries(after: queueStore.currentIndex)
    }

    private var queueContent: some View {
        List {
            if model.hasCurrentTrack {
                Section(String(localized: "正在播放", bundle: .module)) {
                    queueRow(model.currentTrack, isCurrent: true)
                }
            }
            Section {
                if upcomingEntries.isEmpty {
                    Text(String(localized: "没有待播放的歌曲。", bundle: .module))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(upcomingEntries) { entry in
                        let track = entry.track
                        queueRow(track, isCurrent: false)
                            .contextMenu {
                                Button(String(localized: "立即播放", bundle: .module)) { model.selectAndPlay(track) }
                                Button(String(localized: "从队列移除", bundle: .module)) { model.removeQueueEntry(id: entry.id) }
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
                    Text(String(localized: "播放下一首", bundle: .module))
                    Spacer()
                    if !upcomingEntries.isEmpty {
                        Button(String(localized: "清空", bundle: .module)) { model.clearUpcoming() }
                            .buttonStyle(.link)
                    }
                }
            }
            if !historyTracks.isEmpty {
                Section(String(localized: "历史记录", bundle: .module)) {
                    ForEach(historyTracks, id: \.macGlobalID) { track in
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
                    .accessibilityLabel(String(localized: "正在播放", bundle: .module))
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
