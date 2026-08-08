import DesignSystem
import Domain
import SwiftUI
import ThemeEngine

struct HomeView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    private var colors: ThemeColors { theme.colorTokens }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AuralisSpacing.xLarge) {
                quickEntries
                trackShelf("随机音乐", detail: "为你随机挑选 \(model.randomTracks.count) 首", tracks: model.randomTracks, onOpen: { model.browseDestination = .random })
                trackShelf("最近播放", detail: "\(model.recentlyPlayedTracks.count) 首", tracks: model.recentlyPlayedTracks, onOpen: { model.browseDestination = .recentlyPlayed })
                trackShelf("最近添加", detail: "\(model.catalog.tracks.count) 首", tracks: Array(model.recentlyAddedTracks.prefix(24)), onOpen: { model.browseDestination = .recentlyAdded })
                librarySummary
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.top, AuralisSpacing.medium)
            .padding(.bottom, AuralisSpacing.large)
        }
        .background(ambientBackground)
    }

    /// 歌单 / 收藏 / 最常听 三个等宽入口，严格对称。
    private var quickEntries: some View {
        HStack(spacing: AuralisSpacing.medium) {
            quickEntry(title: "歌单", icon: "music.note.list", count: model.catalog.playlists.count, unit: "个") {
                model.browseDestination = .playlists
            }
            quickEntry(title: "收藏", icon: "heart.fill", count: model.favoriteTracks.count, unit: "首") {
                model.browseDestination = .favorites
            }
            quickEntry(title: "最常听", icon: "play.circle.fill", count: model.mostPlayedTracks.count, unit: "首") {
                model.browseDestination = .mostPlayed
            }
        }
    }

    private func quickEntry(title: String, icon: String, count: Int, unit: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AuralisSpacing.small) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(colors.accent.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.primaryText.color)
                    Text("\(count) \(unit)")
                        .font(.caption)
                        .foregroundStyle(colors.secondaryText.color)
                }
                Spacer(minLength: 0)
            }
            .padding(AuralisSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
        }
        .buttonStyle(HapticPlainButtonStyle())
    }

    /// 横向歌曲货架：随机 / 最近播放 / 最近添加 共用。
    /// onOpen 非空时，标题行右侧显示「详情 ›」按钮，点按进入完整列表。
    private func trackShelf(_ title: String, detail: String, tracks: [Track], onOpen: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
            sectionHeader(title, detail: detail, onOpen: onOpen)
            if tracks.isEmpty {
                Text("还没有内容，先去音乐库里播放几首吧。")
                    .font(.subheadline)
                    .foregroundStyle(colors.secondaryText.color)
                    .padding(.vertical, AuralisSpacing.small)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: AuralisSpacing.medium) {
                        ForEach(tracks) { track in
                            TrackCardView(track: track, colors: colors)
                                .frame(width: 132, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Haptics.impact(.light)
                                    model.queue = tracks
                                    model.selectAndPlay(track)
                                }
                        }
                    }
                }
            }
        }
    }

    private var librarySummary: some View {
        HStack(spacing: AuralisSpacing.medium) {
            stat("\(model.catalog.artists.count)", "艺术家")
            stat("\(model.catalog.albums.count)", "专辑")
            stat("\(model.catalog.tracks.count)", "歌曲")
            stat("\(model.catalog.playlists.count)", "歌单")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title2.bold()).foregroundStyle(colors.primaryText.color)
            Text(label).font(.caption).foregroundStyle(colors.secondaryText.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AuralisSpacing.medium)
        .background(colors.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
    }

    private func sectionHeader(_ title: String, detail: String, onOpen: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title).font(.title2.bold()).foregroundStyle(colors.primaryText.color)
            Spacer()
            if let onOpen {
                Button(action: onOpen) {
                    HStack(spacing: 2) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(colors.secondaryText.color)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(colors.secondaryText.color)
                    }
                }
                .buttonStyle(HapticPlainButtonStyle())
            } else {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(colors.secondaryText.color)
            }
        }
    }

    private var ambientBackground: some View {
        LinearGradient(
            colors: [colors.background.color, colors.accent.color.opacity(0.12), colors.background.color],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct TrackCardView: View {
    let track: Track
    let colors: ThemeColors

    var body: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.small) {
            ArtworkView(title: track.albumTitle, artworkKey: track.artworkKey, colors: colors, size: 132)
            Text(track.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.primaryText.color)
                .lineLimit(2)
                .frame(height: 38, alignment: .top)
            Text(track.artistName)
                .font(.caption)
                .foregroundStyle(colors.secondaryText.color)
                .lineLimit(1)
        }
    }
}
