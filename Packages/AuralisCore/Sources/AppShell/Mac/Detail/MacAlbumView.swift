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
                    .frame(maxWidth: .infinity)
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
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var metadataLine: String? {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        if let genre = album.genre, !genre.isEmpty { parts.append(genre) }
        if !tracks.isEmpty {
            parts.append("\(tracks.count) 首")
            parts.append(MacFormat.durationSum(tracks))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                model.playQueue(tracks)
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            Button {
                model.playShuffledQueue(tracks)
            } label: {
                Label("随机播放", systemImage: "shuffle")
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
            .help(model.isAlbumFavorite(album) ? "取消收藏专辑" : "收藏专辑")
            .accessibilityLabel(model.isAlbumFavorite(album) ? "取消收藏专辑" : "收藏专辑")
            Menu {
                Button("随机播放专辑") { model.playShuffledQueue(tracks) }
                Button(model.isAlbumFavorite(album) ? "取消收藏专辑" : "收藏专辑") {
                    model.toggleAlbumFavorite(album)
                }
                if let artist = model.catalog.artists.first(where: { $0.id == album.artistID && $0.serverID == album.serverID }) {
                    Button("前往艺术家") { onNavigate(.artist(artist)) }
                }
                Button("加入队列") {
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
            .help("更多操作")
        }
    }

    // MARK: - 曲目行

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(discGroups, id: \.disc) { group in
                if discGroups.count > 1 {
                    Text("Disc \(group.disc)")
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
                Text("\(album.year.map(String.init) ?? "—") · \(tracks.count) 首 · \(MacFormat.durationSum(tracks))")
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
        return "格式：" + set.sorted().joined(separator: " / ")
    }
}
#endif
