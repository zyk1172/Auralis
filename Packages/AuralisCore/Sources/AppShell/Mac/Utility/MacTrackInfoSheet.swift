#if os(macOS)
import AgentKit
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 歌曲信息（Get Info）：Mac 风格 TabView 面板，而非通用 List sheet。
/// 详细信息 / 插图 / 歌词 / 文件 / Auralis（私人状态 + 公开音乐资料 + 鉴赏）。
struct MacTrackInfoSheet: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let track: Track
    @Environment(\.dismiss) private var dismiss

    @State private var externalResult: AgentExternalMusicResult?
    @State private var isLoadingExternal = false
    @State private var lyrics: LyricsDocument?
    @State private var isLoadingLyrics = false

    private var gid: GlobalID {
        GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                detailsPane.tabItem { Label(String(localized: "详细信息", bundle: .module), systemImage: "info.circle") }
                artworkPane.tabItem { Label(String(localized: "插图", bundle: .module), systemImage: "photo") }
                lyricsPane.tabItem { Label(String(localized: "歌词", bundle: .module), systemImage: "quote.bubble") }
                filePane.tabItem { Label(String(localized: "文件", bundle: .module), systemImage: "doc") }
                auralisPane.tabItem { Label("Auralis", systemImage: "sparkles") }
            }
            .padding(.top, 8)
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "完成", bundle: .module)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 480)
        .task(id: gid) {
            await loadEvidence()
        }
        .task(id: gid) { await loadTrackLyrics() }
    }

    // MARK: - 详细信息

    private var detailsPane: some View {
        Form {
            infoRow(String(localized: "标题", bundle: .module), track.title)
            infoRow(String(localized: "艺术家", bundle: .module), track.artistName)
            infoRow(String(localized: "专辑", bundle: .module), track.albumTitle)
            infoRow(String(localized: "年份", bundle: .module), track.year.map(String.init) ?? "—")
            infoRow(String(localized: "流派", bundle: .module), track.genres.first ?? "—")
            if let trackNumber = track.trackNumber { infoRow(String(localized: "曲目", bundle: .module), String(trackNumber)) }
            if let disc = track.discNumber { infoRow(String(localized: "碟", bundle: .module), String(disc)) }
            if let rating = track.rating { infoRow(String(localized: "评分", bundle: .module), "\(rating) / 5") }
            infoRow(String(localized: "时长", bundle: .module), MacFormat.time(track.duration))
        }
        .formStyle(.grouped)
    }

    // MARK: - 插图

    private var artworkPane: some View {
        VStack(spacing: 14) {
            ArtworkView(
                title: track.albumTitle,
                artworkKey: track.artworkKey,
                colors: theme.colorTokens,
                size: 220,
                cornerRadius: 12
            )
            Text(String(localized: "封面来自服务器元数据；详细来源见服务器歌曲信息。", bundle: .module))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }

    // MARK: - 歌词

    private var lyricsPane: some View {
        Group {
            if isLoadingLyrics {
                ProgressView { Text(String(localized: "正在加载歌词…", bundle: .module)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics, !lyrics.lines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(lyrics.lines) { line in
                            Text(line.text)
                                .font(.system(size: 14))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(18)
                }
            } else {
                ContentUnavailableView(String(localized: "暂无歌词", bundle: .module), systemImage: "quote.bubble")
            }
        }
    }

    // MARK: - 文件

    private var filePane: some View {
        Form {
            if let codec = track.effectiveCodec { infoRow(String(localized: "格式", bundle: .module), codec.uppercased()) }
            if let bitrate = track.sourceInfo.bitRate { infoRow(String(localized: "码率", bundle: .module), "\(bitrate) kbps") }
            if let sampleRate = track.sourceInfo.sampleRate { infoRow(String(localized: "采样率", bundle: .module), "\(sampleRate) Hz") }
            if let bitDepth = track.sourceInfo.bitDepth { infoRow(String(localized: "位深", bundle: .module), "\(bitDepth)-bit") }
            if let channels = track.sourceInfo.channelCount { infoRow(String(localized: "声道", bundle: .module), "\(channels)") }
            infoRow(String(localized: "时长", bundle: .module), MacFormat.time(track.duration))
            Text(String(localized: "不显示服务器凭据、令牌或私有 URL 参数。", bundle: .module))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: - Auralis（私人状态 + 公开资料 + 鉴赏）

    private var auralisPane: some View {
        Form {
            Section(String(localized: "私人状态", bundle: .module)) {
                Button(track.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module)) { model.toggleFavorite(track) }
                Button(model.isDisliked(track) ? String(localized: "取消不喜欢", bundle: .module) : String(localized: "不喜欢", bundle: .module)) {
                    model.setDisliked(track, value: !model.isDisliked(track), source: "user")
                }
                if model.isDownloaded(track) {
                    Button(String(localized: "删除下载", bundle: .module)) { model.removeDownload(track) }
                } else {
                    Button(String(localized: "下载", bundle: .module)) { model.download(track) }
                }
            }
            Section(String(localized: "公开音乐资料", bundle: .module)) {
                if isLoadingExternal {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "正在按需查询…", bundle: .module)).foregroundStyle(.secondary)
                    }
                } else if let result = externalResult {
                    communityRow(.musicBrainz, result: result)
                    communityRow(.critiqueBrainz, result: result)
                    communityRow(.listenBrainz, result: result)
                    Text(String(localized: "数据来自 MusicBrainz / CritiqueBrainz / ListenBrainz 公开只读接口，按需查询并本地缓存。", bundle: .module))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "暂无可核验的大众评价数据。", bundle: .module))
                        .foregroundStyle(.secondary)
                }
            }
            Section(String(localized: "操作", bundle: .module)) {
                Button(String(localized: "歌曲鉴赏", bundle: .module)) {
                    dismiss()
                    NotificationCenter.default.post(name: MacCommand.songAppreciation, object: track)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func communityRow(_ source: CommunityMusicSource, result: AgentExternalMusicResult) -> some View {
        if let metric = result.metrics.value(for: source), metric.status == .available {
            NavigationLink {
                CommunityMusicDetailView(source: source, result: result, theme: theme)
            } label: {
                HStack {
                    Text(sourceTitle(source))
                    Spacer()
                    Text(sourceSummary(metric))
                        .foregroundStyle(.secondary)
                }
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
                return String(format: String(localized: "%.1f / 5 · %d 次评分", bundle: .module), rating, count)
            }
            return String(localized: "有评分数据", bundle: .module)
        case .critiqueBrainz:
            var parts: [String] = []
            if let rating = metric.rating, let count = metric.ratingCount {
                parts.append(String(format: String(localized: "%.1f / 5 · %d 次评分", bundle: .module), rating, count))
            }
        if let reviews = metric.reviewCount { parts.append(String(localized: "\(reviews) 篇评论", bundle: .module)) }
            return parts.isEmpty ? String(localized: "有评论数据", bundle: .module) : parts.joined(separator: " · ")
        case .listenBrainz:
            var parts: [String] = []
        if let listens = metric.listenCount { parts.append(String(localized: "\(listens) 次收听", bundle: .module)) }
        if let listeners = metric.listenerCount { parts.append(String(localized: "\(listeners) 位听众", bundle: .module)) }
            return parts.isEmpty ? String(localized: "有收听数据", bundle: .module) : parts.joined(separator: " · ")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }

    private func loadEvidence() async {
        isLoadingExternal = true
        defer { isLoadingExternal = false }
        externalResult = await model.musicEnrichment.enrich(track: track, globalID: gid)
    }

    private func loadTrackLyrics() async {
        isLoadingLyrics = true
        let loaded = await model.loadLyrics(for: track)
        guard !Task.isCancelled else { return }
        lyrics = loaded
        isLoadingLyrics = false
    }
}
#endif
