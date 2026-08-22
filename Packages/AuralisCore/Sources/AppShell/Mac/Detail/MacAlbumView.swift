#if os(macOS)
import DesignSystem
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// Album Detail：单一 ScrollView（Hero + 按碟曲目行 + 轻量 footer）。
/// 不使用嵌套 Table；Hero ambience 覆盖整个横向区域且非常克制，无封面后方方形 Glow。
struct MacAlbumView: View {
    let album: Album
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var ambienceImage: PlatformImage?

    private var tracks: [Track] { MacLibraryQuery.albumTracks(album, model: model) }

    private var discGroups: [(disc: Int, tracks: [Track])] {
        let discs = Set(tracks.map { $0.discNumber ?? 1 }).sorted()
        return discs.map { disc in
            (disc, tracks.filter { ($0.discNumber ?? 1) == disc })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                Divider()
                trackList
                footer
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .task(id: album.artworkKey) {
            ambienceImage = model.artworkImage(key: album.artworkKey, targetPixelSize: 512)
        }
        .navigationTitle(album.title)
    }

    // MARK: - Hero（ambience 覆盖 Hero 横向整区）

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            if let ambienceImage {
                Image(platformImage: ambienceImage)
                    .resizable()
                    .scaledToFill()
                    // `ScrollView` gives its content an unbounded vertical proposal.
                    // Limiting only width lets a loaded artwork image choose its full
                    // intrinsic height, which grows the Hero to nearly a full window
                    // and pushes its actual content below the fold.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 42)
                    .saturation(1.05)
                    .opacity(0.16)
                    .allowsHitTesting(false)
            }
            LinearGradient(
                colors: [.clear, Color(nsColor: .underPageBackgroundColor)],
                startPoint: .top, endPoint: .bottom
            )
            .opacity(0.5)

            HStack(alignment: .center, spacing: 28) {
                ArtworkView(
                    title: album.title,
                    artworkKey: album.artworkKey,
                    colors: theme.colorTokens,
                    size: 250,
                    cornerRadius: 12
                )
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)

                VStack(alignment: .leading, spacing: 10) {
                    Text(album.title)
                        .font(.system(size: 32, weight: .bold, design: .default))
                        .lineLimit(3)
                    if let artist = model.catalog.artists.first(where: { $0.id == album.artistID && $0.serverID == album.serverID }) {
                        Button {
                            onNavigate(.artist(artist))
                        } label: {
                            Text(artist.name)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(theme.colorTokens.accent.color)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(album.artistName)
                            .font(.system(size: 18, weight: .semibold))
                    }
                    if let metadata = metadataLine {
                        Text(metadata)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    actions
                }
                Spacer()
            }
            .padding(20)
        }
        // The foreground has a fixed 250pt artwork plus 20pt vertical padding.
        // Keep the ambience background in that same bounded region instead of
        // allowing it to dictate the scroll content height.
        .frame(maxWidth: .infinity)
        .frame(height: 290)
        .clipped()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var metadataLine: String? {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        if let genre = album.genre, !genre.isEmpty { parts.append(genre) }
        if !tracks.isEmpty {
            parts.append(String(localized: "\(tracks.count) 首", bundle: .module))
            parts.append(MacFormat.durationSum(tracks))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                model.playQueue(tracks)
            } label: {
                Label(String(localized: "播放", bundle: .module), systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            Button {
                model.playShuffledQueue(tracks)
            } label: {
                Label(String(localized: "随机播放", bundle: .module), systemImage: "shuffle")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            Button {
                model.toggleAlbumFavorite(album)
            } label: {
                Image(systemName: model.isAlbumFavorite(album) ? "heart.fill" : "heart")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
                    .help(model.isAlbumFavorite(album) ? String(localized: "取消收藏专辑", bundle: .module) : String(localized: "收藏专辑", bundle: .module))
            .accessibilityLabel(model.isAlbumFavorite(album) ? String(localized: "取消收藏专辑", bundle: .module) : String(localized: "收藏专辑", bundle: .module))
            Menu {
                Button(String(localized: "随机播放专辑", bundle: .module)) { model.playShuffledQueue(tracks) }
                Button(String(localized: "下载专辑", bundle: .module)) { model.downloadAll(tracks) }
                Button(model.isAlbumFavorite(album) ? String(localized: "取消收藏专辑", bundle: .module) : String(localized: "收藏专辑", bundle: .module)) {
                    model.toggleAlbumFavorite(album)
                }
                if let artist = model.catalog.artists.first(where: { $0.id == album.artistID && $0.serverID == album.serverID }) {
                    Button(String(localized: "前往艺术家", bundle: .module)) { onNavigate(.artist(artist)) }
                }
                Button(String(localized: "加入队列", bundle: .module)) {
                    for track in tracks {
                        model.addToQueue(globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "更多操作", bundle: .module))
        }
    }

    // MARK: - 曲目行

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(discGroups, id: \.disc) { group in
                if discGroups.count > 1 {
                    Text(String(localized: "Disc \(group.disc)", bundle: .module))
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 8)
                }
                MacDetailTrackList(
                    tracks: group.tracks,
                    model: model,
                    theme: theme,
                    numberText: { $0.trackNumber },
                    onNavigate: onNavigate
                )
            }
        }
    }

    // MARK: - Footer（轻量）

    private var footer: some View {
        HStack(spacing: 18) {
            if !tracks.isEmpty {
                Text(String(localized: "\(album.year.map(String.init) ?? "—") · \(tracks.count) 首 · \(MacFormat.durationSum(tracks))", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let codecs = codecSummary {
                Text(codecs)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 10)
    }

    private var codecSummary: String? {
        let set = Set(tracks.compactMap { MacFormat.codec($0) })
        guard !set.isEmpty else { return nil }
        return String(localized: "格式：", bundle: .module) + set.sorted().joined(separator: " / ")
    }
}
#endif
