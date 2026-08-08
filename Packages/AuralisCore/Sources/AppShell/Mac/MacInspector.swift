#if os(macOS)
import DesignSystem
import Domain
import SwiftUI
import ThemeEngine

/// macOS 右侧上下文检查器：按需显示，仅在有播放/选中上下文时出现。
/// 顶部分段切换：队列 / 歌词 / 音质 / 元数据。
struct MacInspector: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var section: InspectorTab
    let onTabChange: (InspectorTab) -> Void

    init(model: AuralisAppModel, theme: BuiltInTheme,
         initialTab: InspectorTab = .queue,
         onTabChange: @escaping (InspectorTab) -> Void = { _ in }) {
        self.model = model
        self.theme = theme
        self._section = State(initialValue: initialTab)
        self.onTabChange = onTabChange
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case queue, lyrics, quality, metadata
        var id: String { rawValue }
        var title: String {
            switch self {
            case .queue: "队列"
            case .lyrics: "歌词"
            case .quality: "音质"
            case .metadata: "元数据"
            }
        }
    }

    private var track: Track? {
        model.currentTrack.id.rawValue == "placeholder" ? nil : model.currentTrack
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(AuralisSpacing.medium)
            .onChange(of: section) { _, newValue in onTabChange(newValue) }

            Divider()
            if let track {
                switch section {
                case .queue: queueContent
                case .lyrics: lyricsContent(track)
                case .quality: qualityContent(track)
                case .metadata: metadataContent(track)
                }
            } else {
                ContentUnavailableView("无播放内容", systemImage: "music.note",
                                       description: Text("选择一首歌曲或开始播放后，这里显示详细信息。"))
            }
        }
        .background(theme.colorTokens.background.color)
    }

    private var queueContent: some View {
        List(model.queue) { item in
            HStack(spacing: AuralisSpacing.small) {
                Text(item.title).lineLimit(1)
                    .fontWeight(item.id == model.currentTrack.id ? .semibold : .regular)
                Spacer(minLength: 4)
                if item.id == model.currentTrack.id {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.colorTokens.accent.color)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selectAndPlay(item) }
        }
        .listStyle(.plain)
    }

    private func lyricsContent(_ track: Track) -> some View {
        let lines = model.currentLyrics?.lines ?? []
        if lines.isEmpty {
            return AnyView(
                ContentUnavailableView("无歌词", systemImage: "text.quote",
                                       description: Text("这首歌还没有歌词。"))
            )
        }
        // 当前行：最后一个 startTime <= 播放位置 的行。
        let currentIndex = lines.lastIndex { line in
            guard let start = line.startTime else { return false }
            return start <= model.playbackPosition
        }
        return AnyView(
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .center, spacing: AuralisSpacing.small) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(index == currentIndex ? .body.weight(.semibold) : .body)
                                .foregroundStyle(
                                    index == currentIndex
                                    ? theme.colorTokens.accent.color
                                    : theme.colorTokens.primaryText.color
                                )
                                .multilineTextAlignment(.center)
                                .id(index)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let start = line.startTime {
                                        model.seek(toProgress: start / max(track.duration, 1))
                                    }
                                }
                        }
                    }
                    .padding(AuralisSpacing.large)
                }
                .onChange(of: model.playbackPosition) { _, _ in
                    if let currentIndex, currentIndex < lines.count {
                        withAnimation { proxy.scrollTo(currentIndex, anchor: .center) }
                    }
                }
            }
        )
    }

    private func qualityContent(_ track: Track) -> some View {
        let info = track.sourceInfo
        return Form {
            LabeledContent("格式", value: track.effectiveCodec?.uppercased() ?? "未知")
            LabeledContent("码率", value: info.bitRate.map { "\($0) kbps" } ?? "未知")
            LabeledContent("采样率", value: info.sampleRate.map { "\($0) Hz" } ?? "未知")
            LabeledContent("位深", value: info.bitDepth.map { "\($0) bit" } ?? "未知")
            LabeledContent("声道", value: info.channelCount.map { "\($0)" } ?? "未知")
            LabeledContent("时长", value: Self.timeText(track.duration))
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func metadataContent(_ track: Track) -> some View {
        Form {
            LabeledContent("标题", value: track.title)
            LabeledContent("艺术家", value: track.artistName)
            LabeledContent("专辑", value: track.albumTitle)
            if let year = track.year { LabeledContent("年份", value: "\(year)") }
            if !track.genres.isEmpty { LabeledContent("流派", value: track.genres.joined(separator: "、")) }
            if let num = track.trackNumber { LabeledContent("曲目号", value: "\(num)") }
            LabeledContent("收藏", value: track.isFavorite ? "是" : "否")
            if let rating = track.rating { LabeledContent("评分", value: "\(rating)") }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
