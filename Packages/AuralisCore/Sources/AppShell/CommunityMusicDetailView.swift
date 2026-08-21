import AgentKit
import DesignSystem
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 大众评价详情页：按来源分别展示真实数据。
/// MusicBrainz 详情 / CritiqueBrainz 评论（含 license / source）/ ListenBrainz 收听统计。
/// 没有字段时只显示已确认的状态，不堆“未知”。
struct CommunityMusicDetailView: View {
    let source: CommunityMusicSource
    let result: AgentExternalMusicResult
    let theme: BuiltInTheme

    var body: some View {
        List {
            switch source {
            case .musicBrainz:
                musicBrainzSection
            case .critiqueBrainz:
                critiqueBrainzSection
            case .listenBrainz:
                listenBrainzSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.colorTokens.background.color)
        .navigationTitle(sourceTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var sourceTitle: String {
        switch source {
        case .musicBrainz: "MusicBrainz"
        case .critiqueBrainz: "CritiqueBrainz"
        case .listenBrainz: "ListenBrainz"
        }
    }

    // MARK: - MusicBrainz

    @ViewBuilder
    private var musicBrainzSection: some View {
        if let detail = result.evidence?.musicBrainz {
            Section(String(localized: "评分", bundle: .module)) {
                if let rating = detail.rating {
                    detailRow(String(localized: "平均评分", bundle: .module), String(format: "%.1f / 5", rating))
                }
                if let votes = detail.votesCount {
                    detailRow(String(localized: "评分票数", bundle: .module), "\(votes)")
                }
            }
            Section(String(localized: "身份", bundle: .module)) {
                if let id = detail.recordingMBID { detailRow("Recording MBID", id) }
                if let id = detail.releaseMBID { detailRow("Release MBID", id) }
                if let id = detail.releaseGroupMBID { detailRow("Release Group MBID", id) }
                if let id = detail.artistMBID { detailRow("Artist MBID", id) }
                if let isrc = detail.isrc, !isrc.isEmpty { detailRow("ISRC", isrc) }
            }
            Section(String(localized: "录音信息", bundle: .module)) {
                if let title = detail.title { detailRow(String(localized: "标题", bundle: .module), title) }
                if let credit = detail.artistCredit, !credit.isEmpty { detailRow(String(localized: "艺术家", bundle: .module), credit) }
                if let date = detail.releaseDate, !date.isEmpty { detailRow(String(localized: "发行日期", bundle: .module), date) }
                if let type = detail.releaseType, !type.isEmpty { detailRow(String(localized: "发行类型", bundle: .module), type) }
                if !detail.genres.isEmpty { detailRow(String(localized: "流派", bundle: .module), detail.genres.joined(separator: "、")) }
                if !detail.tags.isEmpty { detailRow(String(localized: "标签", bundle: .module), detail.tags.prefix(20).joined(separator: "、")) }
            }
        } else if let metric = result.metrics.value(for: .musicBrainz) {
            switch metric.status {
            case .noData, .notSupported:
                Section { Text(String(localized: "暂无 MusicBrainz 评分数据。", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color) }
            case .failed, .unavailable, .rateLimited:
                Section { Text(String(localized: "MusicBrainz 数据暂时不可用。", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color) }
            default:
                Section { Text(String(localized: "暂无详情。", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color) }
            }
        } else {
            Section { Text(String(localized: "暂无详情。", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color) }
        }
    }

    // MARK: - CritiqueBrainz

    @ViewBuilder
    private var critiqueBrainzSection: some View {
        let metric = result.metrics.value(for: .critiqueBrainz)
        if let metric, metric.status == .available {
            Section(String(localized: "聚合", bundle: .module)) {
                if let rating = metric.rating, let count = metric.ratingCount {
                    detailRow(
                        String(localized: "平均评分", bundle: .module),
                        String.localizedStringWithFormat(
                            String(localized: "%.1f / 5（%d 次评分）", bundle: .module),
                            rating,
                            count
                        )
                    )
                }
                if let reviews = metric.reviewCount {
                    detailRow(String(localized: "评论数", bundle: .module), "\(reviews)")
                }
            }
        }
        let reviews = result.evidence?.reviews ?? []
        if !reviews.isEmpty {
            Section(String(localized: "评论（真实来源）", bundle: .module)) {
                ForEach(reviews.prefix(10), id: \.reviewID) { review in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(review.authorName ?? String(localized: "匿名", bundle: .module))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.colorTokens.primaryText.color)
                            Spacer()
                            if let rating = review.rating {
                                Text(String(format: "%.1f / 5", rating))
                                    .font(.caption)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                            }
                        }
                        if let publishedAt = review.publishedAt {
                            Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                        Text(review.excerpt)
                            .font(.subheadline)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            if let positive = review.positiveVotes {
                                Label("\(positive)", systemImage: "hand.thumbsup")
                                    .font(.caption2)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                            }
                            if let negative = review.negativeVotes {
                                Label("\(negative)", systemImage: "hand.thumbsdown")
                                    .font(.caption2)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                            }
                        }
                        Text(sourceLine(review))
                            .font(.caption2)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                        if let urlString = review.sourceURL, let url = URL(string: urlString) {
                            Link(String(localized: "查看原始来源", bundle: .module), destination: url)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } else if let metric, metric.status == .available || metric.status == .noData || metric.status == .notSupported {
            Section { Text(String(localized: "暂无评论。", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color) }
        } else if let metric {
            Section { Text(metric.status == .rateLimited ? String(localized: "CritiqueBrainz 请求过于频繁，请稍后再试。", bundle: .module) : String(localized: "CritiqueBrainz 数据暂时不可用。", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color) }
        } else {
            Section { Text(String(localized: "暂无评论。", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color) }
        }
    }

    private func sourceLine(_ review: CommunityMusicReview) -> String {
        var parts: [String] = []
        if let source = review.sourceName, !source.isEmpty { parts.append(String(localized: "来源：\(source)", bundle: .module)) }
        if let license = review.licenseID, !license.isEmpty { parts.append(String(localized: "许可：\(license)", bundle: .module)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - ListenBrainz

    @ViewBuilder
    private var listenBrainzSection: some View {
        if let metric = result.metrics.value(for: .listenBrainz) {
            switch metric.status {
            case .available:
                Section(String(localized: "收听统计", bundle: .module)) {
                    if let listens = metric.listenCount {
                        detailRow(String(localized: "总收听次数", bundle: .module), formattedCount(listens))
                    }
                    if let listeners = metric.listenerCount {
                        detailRow(String(localized: "独立听众数", bundle: .module), formattedCount(listeners))
                    }
                    if let listens = metric.listenCount, let listeners = metric.listenerCount, listeners > 0 {
                        // 本地计算，名称必须明确是“平均每位听众播放次数”，不是热爱指数/忠诚度。
                        detailRow(String(localized: "平均每位听众播放次数", bundle: .module), String(format: "%.1f", Double(listens) / Double(listeners)))
                    }
                }
                Section {
                    Text(String(localized: "收听量与评分描述不同人群与时间，不与其他来源合并为综合分。", bundle: .module))
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            case .noData, .notSupported:
                Section { Text(String(localized: "暂无 ListenBrainz 收听数据。", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color) }
            default:
                Section { Text(String(localized: "ListenBrainz 数据暂时不可用。", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color) }
            }
        } else {
            Section { Text(String(localized: "暂无 ListenBrainz 收听数据。", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color) }
        }
    }

    private func formattedCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(theme.colorTokens.primaryText.color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
