#if os(macOS)
import AgentKit
import LocalCatalog
import SwiftUI
import ThemeEngine
import Domain

/// Apple Music 式正在播放（Full Player 形态）：
/// 超大封面 + 低频低饱和 Artwork ambience + 私人状态 + 公开评价摘要 + 技术信息。
/// 持久 transport 由底部播放条负责，本页不再复制一整套大控制。
struct MacNowPlayingView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    @State private var ambienceImage: PlatformImage?
    @State private var externalResult: AgentExternalMusicResult?
    @State private var isLoadingExternal = false

    private var track: Track { model.currentTrack }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 36) {
                ZStack {
                    if let ambienceImage {
                        Image(platformImage: ambienceImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 360, height: 360)
                            .blur(radius: 70)
                            .saturation(1.1)
                            .opacity(0.24)
                            .allowsHitTesting(false)
                    }
                    ArtworkView(
                        title: track.albumTitle,
                        artworkKey: track.artworkKey,
                        colors: theme.colorTokens,
                        size: 320,
                        cornerRadius: 18
                    )
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
                }
                .frame(width: 360, height: 360)

                VStack(alignment: .leading, spacing: 12) {
                    Text(track.title)
                        .font(.system(size: 30, weight: .bold, design: .default))
                        .lineLimit(2)
                    Text(track.artistName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.colorTokens.accent.color)
                    Text(track.albumTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            model.toggleFavorite(track)
                        } label: {
                            Label(track.isFavorite ? "取消收藏" : "收藏",
                                  systemImage: track.isFavorite ? "heart.fill" : "heart")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            model.toggleDisliked(track)
                        } label: {
                            Label(model.isDisliked(track) ? "取消不喜欢" : "不喜欢",
                                  systemImage: model.isDisliked(track) ? "heart.slash.fill" : "heart.slash")
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()

                    communitySummary

                    Divider()

                    techInfo
                }
                Spacer(minLength: 0)
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("正在播放")
        .task(id: track.id.rawValue) {
            await loadAmbience()
            await loadPublicEvidence()
        }
    }

    // MARK: - 公开评价摘要

    @ViewBuilder
    private var communitySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingExternal {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在按需查询公开音乐资料…")
                        .foregroundStyle(.secondary)
                }
            } else if let result = externalResult {
                communityRow(.musicBrainz, result: result)
                communityRow(.critiqueBrainz, result: result)
                communityRow(.listenBrainz, result: result)
            } else {
                Text("公开音乐资料暂未加载。")
                    .foregroundStyle(.secondary)
            }
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    // MARK: - 技术信息

    private var techInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let codec = track.sourceInfo.normalizedCodec { infoLine("格式", codec.uppercased()) }
            if let sampleRate = track.sourceInfo.sampleRate { infoLine("采样率", "\(sampleRate) Hz") }
            if let bitRate = track.sourceInfo.bitRate { infoLine("码率", "\(bitRate) kbps") }
            if let channels = track.sourceInfo.channelCount { infoLine("声道", "\(channels)") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
        }
    }

    // MARK: - 加载

    private func loadAmbience() async {
        ambienceImage = model.artworkImage(key: track.artworkKey, targetPixelSize: 480)
    }

    private func loadPublicEvidence() async {
        guard model.hasCurrentTrack else { return }
        let current = track
        let gid = GlobalID(serverID: current.serverID, remoteID: current.id.rawValue)
        isLoadingExternal = true
        defer { isLoadingExternal = false }
        externalResult = await model.musicEnrichment.enrich(track: current, globalID: gid)
    }
}
#endif
