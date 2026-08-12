#if os(macOS)
import SwiftUI
import ThemeEngine
import Domain

/// Apple Music 式右侧面板：只承担高频音乐上下文（歌词 / 队列），
/// 详情信息走「歌曲信息」独立视图。
struct MacRightPanel: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var mode: MacRightPanelMode

    @ObservedObject private var playbackStore: PlaybackStore

    init(model: AuralisAppModel, theme: BuiltInTheme, mode: Binding<MacRightPanelMode>) {
        self.model = model
        self.theme = theme
        self._mode = mode
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
        .background(.background)
        .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
    }

    private var header: some View {
        HStack {
            Picker("", selection: $mode) {
                Text("歌词").tag(MacRightPanelMode.lyrics)
                Text("队列").tag(MacRightPanelMode.queue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Lyrics

    private var lyricsContent: some View {
        Group {
            if let lyrics = model.currentLyrics, !lyrics.lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                                let isCurrent = isCurrentLyric(line)
                                Text(line.text)
                                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? theme.colorTokens.accent.color : Color.secondary)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let start = line.startTime {
                                            model.seek(toProgress: min(1, max(0, start / max(model.currentTrack.duration, 1))))
                                        }
                                    }
                                    .id(index)
                            }
                        }
                        .padding(18)
                    }
                    .onChange(of: currentLyricIndex) { _, index in
                        if let index {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
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

    private func isCurrentLyric(_ line: TimedLyricLine) -> Bool {
        guard let idx = currentLyricIndex, let lyrics = model.currentLyrics else { return false }
        return idx < lyrics.lines.count && lyrics.lines[idx].id == line.id
    }

    // MARK: - Queue

    private var queueContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("播放下一首")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if !model.queue.isEmpty {
                    Button("清空") {
                        model.removeFromQueue(atOffsets: IndexSet(integersIn: 0..<model.queue.count))
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            List {
                ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, track in
                    queueRow(track, index: index)
                        .tag(track.id)
                }
                .onMove { source, destination in
                    model.moveQueue(from: source, to: destination)
                }
                .onDelete { offsets in
                    model.removeFromQueue(atOffsets: offsets)
                }
            }
            .listStyle(.inset)
        }
    }

    private func queueRow(_ track: Track, index: Int) -> some View {
        let isCurrent = model.currentTrack.serverID == track.serverID && model.currentTrack.id == track.id
        return HStack(spacing: 10) {
            ArtworkView(
                title: track.albumTitle,
                artworkKey: track.artworkKey,
                colors: theme.colorTokens,
                size: 36,
                cornerRadius: 4
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? theme.colorTokens.accent.color : Color.primary)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.accent.color)
                    .accessibilityLabel("正在播放")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.selectAndPlay(track)
        }
        .contextMenu {
            Button("立即播放") { model.selectAndPlay(track) }
            Button("从队列移除") { model.removeFromQueue(track) }
        }
    }
}
#endif
