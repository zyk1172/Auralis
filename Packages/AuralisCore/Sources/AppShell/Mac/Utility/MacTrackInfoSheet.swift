#if os(macOS)
import AgentKit
import LocalCatalog
import SwiftUI
import ThemeEngine
import Domain

/// 歌曲信息（Get Info）：真正临时任务用 sheet 呈现，
/// 含 基本信息 / 私人状态 / 公开音乐资料（三来源可点击进入详情）。
struct MacTrackInfoSheet: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let track: Track
    @Environment(\.dismiss) private var dismiss

    @State private var externalResult: AgentExternalMusicResult?
    @State private var isLoadingExternal = false

    private var gid: GlobalID {
        GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("基本信息") {
                    infoRow("标题", track.title)
                    infoRow("艺术家", track.artistName)
                    infoRow("专辑", track.albumTitle)
                    infoRow("时长", MacFormat.time(track.duration))
                    if let year = track.year { infoRow("年份", String(year)) }
                    if let genre = track.genres.first { infoRow("流派", genre) }
                    if let codec = track.effectiveCodec { infoRow("格式", codec.uppercased()) }
                    if let sampleRate = track.sourceInfo.sampleRate { infoRow("采样率", "\(sampleRate) Hz") }
                    if let bitRate = track.sourceInfo.bitRate { infoRow("码率", "\(bitRate) kbps") }
                }
                Section("私人状态") {
                    Button(track.isFavorite ? "取消收藏" : "收藏") { model.toggleFavorite(track) }
                    Button(model.isDisliked(track) ? "取消不喜欢" : "不喜欢") {
                        model.setDisliked(track, value: !model.isDisliked(track), source: "user")
                    }
                    if model.isDownloaded(track) {
                        Button("删除下载") { model.removeDownload(track) }
                    } else {
                        Button("下载") { model.download(track) }
                    }
                    if let rating = track.rating {
                        infoRow("评分", "\(rating) / 5")
                    }
                }
                Section("公开音乐资料") {
                    if isLoadingExternal {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在按需查询…").foregroundStyle(.secondary)
                        }
                    } else if let result = externalResult {
                        communityRow(.musicBrainz, result: result)
                        communityRow(.critiqueBrainz, result: result)
                        communityRow(.listenBrainz, result: result)
                        Text("数据来自 MusicBrainz / CritiqueBrainz / ListenBrainz 公开只读接口，按需查询并本地缓存。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("暂无可核验的大众评价数据。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("操作") {
                    Button("播放") { model.selectAndPlay(track) }
                    Button("下一首播放") { model.playNext(globalID: gid) }
                    Button("加入队列") { model.addToQueue(globalID: gid) }
                    Button("歌曲鉴赏") {
                        dismiss()
                        NotificationCenter.default.post(name: MacCommand.songAppreciation, object: track)
                    }
                }
            }
            .navigationTitle(track.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .task(id: track.id.rawValue) {
            await loadEvidence()
        }
    }

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

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
    }

    private func loadEvidence() async {
        guard model.hasCurrentTrack || model.track(for: gid) != nil else { return }
        isLoadingExternal = true
        defer { isLoadingExternal = false }
        externalResult = await model.musicEnrichment.enrich(track: track, globalID: gid)
    }
}
#endif
