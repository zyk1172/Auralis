#if os(macOS)
import AgentKit
import DesignSystem
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// macOS 右侧上下文检查器（真正 SwiftUI Inspector）。
/// 上下文顺序：多选摘要 > 单曲选中 > 正在播放 > 空状态。
struct MacInspector: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject private var playbackStore: PlaybackStore
    let theme: BuiltInTheme
    let selectedTracks: Set<GlobalID>
    @State private var section: InspectorTab
    let onTabChange: (InspectorTab) -> Void
    @State private var externalResult: AgentExternalMusicResult?

    init(
        model: AuralisAppModel,
        theme: BuiltInTheme,
        initialTab: InspectorTab = .queue,
        onTabChange: @escaping (InspectorTab) -> Void = { _ in },
        selectedTracks: Set<GlobalID> = []
    ) {
        self.model = model
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
        self.theme = theme
        self._section = State(initialValue: initialTab)
        self.onTabChange = onTabChange
        self.selectedTracks = selectedTracks
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case queue, lyrics, details
        var id: String { rawValue }
        var title: String {
            switch self {
            case .queue: "队列"
            case .lyrics: "歌词"
            case .details: "详情"
            }
        }
    }

    /// 单曲上下文：多选时 nil（走多选摘要），否则选中 > 正在播放。
    private var singleTrack: Track? {
        if selectedTracks.count == 1, let gid = selectedTracks.first {
            return model.catalog.tracks.first {
                $0.serverID == gid.serverID && $0.id.rawValue == gid.remoteID
            }
        }
        return model.currentTrack.id.rawValue == "placeholder" ? nil : model.currentTrack
    }

    private var isMultiSelect: Bool { selectedTracks.count > 1 }

    private var selectedTracksResolved: [Track] {
        selectedTracks.compactMap { gid in
            model.catalog.tracks.first {
                $0.serverID == gid.serverID && $0.id.rawValue == gid.remoteID
            }
        }
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

            if isMultiSelect {
                multiSelectSummary
            } else if let track = singleTrack {
                switch section {
                case .queue: queueContent
                case .lyrics: lyricsContent(track)
                case .details: detailsContent(track)
                }
            } else {
                ContentUnavailableView("无播放内容", systemImage: "music.note",
                                       description: Text("选择一首歌曲或开始播放后，这里显示详细信息。"))
            }
        }
        .background(theme.colorTokens.background.color)
        .task(id: singleTrack?.id.rawValue) {
            await loadPublicEvidence()
        }
    }

    // MARK: - 多选摘要

    private var multiSelectSummary: some View {
        let tracks = selectedTracksResolved
        return VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
            Text("已选择 \(tracks.count) 首")
                .font(.headline)
                .foregroundStyle(theme.colorTokens.primaryText.color)
            VStack(alignment: .leading, spacing: 4) {
                Button("播放") { model.playQueue(tracks) }
                Button("加入队列") {
                    for track in tracks {
                        model.addToQueue(globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
                    }
                }
                Button("下载") { for track in tracks { model.download(track) } }
                Button("收藏") { for track in tracks { model.toggleFavorite(track) } }
                Button("不喜欢") {
                    for track in tracks {
                        model.setDisliked(track, value: true, source: "user")
                    }
                }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(AuralisSpacing.large)
    }

    // MARK: - 队列

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

    // MARK: - 歌词

    private func lyricsContent(_ track: Track) -> some View {
        // 只有当前播放歌曲才有已加载歌词；选中其他歌曲时提示切到当前歌曲。
        guard track.serverID == model.currentTrack.serverID, track.id == model.currentTrack.id else {
            return AnyView(
                ContentUnavailableView("歌词仅用于当前播放歌曲", systemImage: "text.quote",
                                       description: Text("选中正在播放的歌曲后显示同步歌词。"))
            )
        }
        let lines = model.currentLyrics?.lines ?? []
        if lines.isEmpty {
            return AnyView(
                ContentUnavailableView("无歌词", systemImage: "text.quote",
                                       description: Text("这首歌还没有歌词。"))
            )
        }
        let currentIndex = lines.lastIndex { line in
            guard let start = line.startTime else { return false }
            return start <= playbackStore.position
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
                .onChange(of: playbackStore.position) { _, _ in
                    if let currentIndex, currentIndex < lines.count {
                        withAnimation { proxy.scrollTo(currentIndex, anchor: .center) }
                    }
                }
            }
        )
    }

    // MARK: - 详情

    private func detailsContent(_ track: Track) -> some View {
        Form {
            Section("快速操作") {
                Button("播放") { model.playQueue([track]) }
                Button("下一首播放") { model.playNext(globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)) }
                Button("加入队列") { model.addToQueue(globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)) }
            }
            Section("基本信息") {
                LabeledContent("标题", value: track.title)
                LabeledContent("艺术家", value: track.artistName)
                LabeledContent("专辑", value: track.albumTitle)
                if let year = track.year { LabeledContent("年份", value: "\(year)") }
                if !track.genres.isEmpty { LabeledContent("流派", value: track.genres.joined(separator: "、")) }
            }
            Section("音质") {
                let info = track.sourceInfo
                LabeledContent("格式", value: track.effectiveCodec?.uppercased() ?? "未知")
                LabeledContent("码率", value: info.bitRate.map { "\($0) kbps" } ?? "未知")
                LabeledContent("采样率", value: info.sampleRate.map { "\($0) Hz" } ?? "未知")
                LabeledContent("位深", value: info.bitDepth.map { "\($0) bit" } ?? "未知")
                LabeledContent("声道", value: info.channelCount.map { "\($0)" } ?? "未知")
                LabeledContent("时长", value: Self.timeText(track.duration))
            }
            Section("私人状态") {
                Toggle("收藏", isOn: Binding(
                    get: { model.catalog.tracks.first(where: { $0.serverID == track.serverID && $0.id == track.id })?.isFavorite ?? track.isFavorite },
                    set: { _ in model.toggleFavorite(track) }
                ))
                Toggle("不喜欢", isOn: Binding(
                    get: { model.isDisliked(track) },
                    set: { newValue in model.setDisliked(track, value: newValue, source: "user") }
                ))
                LabeledContent("播放次数", value: "\(model.playCounts[track.id] ?? 0)")
                if let rating = track.rating { LabeledContent("评分", value: "\(rating)/5") }
                LabeledContent("本地下载", value: model.isDownloaded(track) ? "已下载" : "未下载")
            }
            Section("公开音乐资料") {
                if let result = externalResult {
                    communityRow(.musicBrainz, result: result)
                    communityRow(.critiqueBrainz, result: result)
                    communityRow(.listenBrainz, result: result)
                } else {
                    Text("正在按需查询公开音乐资料…")
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func communityRow(_ source: CommunityMusicSource, result: AgentExternalMusicResult) -> some View {
        if let metric = result.metrics.value(for: source), metric.status == .available {
            NavigationLink {
                CommunityMusicDetailView(source: source, result: result, theme: theme)
            } label: {
                HStack {
                    Text(sourceTitle(source))
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Spacer()
                    Text(sourceSummary(metric))
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            }
        } else if let metric = result.metrics.value(for: source), metric.status == .noData {
            HStack {
                Text(sourceTitle(source))
                Spacer()
                Text("暂无数据").font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        }
    }

    private func sourceTitle(_ source: CommunityMusicSource) -> String {
        switch source {
        case .musicBrainz: "MusicBrainz"
        case .critiqueBrainz: "CritiqueBrainz"
        case .listenBrainz: "ListenBrainz"
        }
    }

    private func sourceSummary(_ metric: CommunityMusicMetric) -> String {
        switch metric.source {
        case .musicBrainz:
            if let rating = metric.rating, let count = metric.ratingCount {
                return String(format: "%.1f / 5 · %d 次评分", rating, count)
            }
            return "有评分数据"
        case .critiqueBrainz:
            var parts: [String] = []
            if let rating = metric.rating, let count = metric.ratingCount {
                parts.append(String(format: "%.1f / 5 · %d 次评分", rating, count))
            }
            if let reviews = metric.reviewCount { parts.append("\(reviews) 篇评论") }
            return parts.isEmpty ? "有评论数据" : parts.joined(separator: " · ")
        case .listenBrainz:
            var parts: [String] = []
            if let listens = metric.listenCount { parts.append("\(listens) 次收听") }
            if let listeners = metric.listenerCount { parts.append("\(listeners) 位听众") }
            return parts.isEmpty ? "有收听数据" : parts.joined(separator: " · ")
        }
    }

    private func loadPublicEvidence() async {
        guard let track = singleTrack else { return }
        let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        externalResult = await model.musicEnrichment.enrich(track: track, globalID: gid)
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
