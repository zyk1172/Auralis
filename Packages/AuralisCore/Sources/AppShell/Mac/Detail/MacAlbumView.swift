#if os(macOS)
import DesignSystem
import SwiftUI
import ThemeEngine
import Domain
import LocalCatalog

/// Apple Music 式 Album Detail：Hero（大封面 + 元数据 + 主操作）+ 按碟曲目表 + 底部元数据 + 更多信息。
struct MacAlbumView: View {
    let album: Album
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacRoute) -> Void = { _ in }

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
                Divider().padding(.vertical, 8)
                trackList
                bottomMetadata
                moreInfo
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .task(id: album.artworkKey) {
            ambienceImage = model.artworkImage(key: album.artworkKey, targetPixelSize: 480)
        }
        .navigationTitle(album.title)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 28) {
            ZStack {
                if let ambienceImage {
                    Image(platformImage: ambienceImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 320, height: 320)
                        .blur(radius: 56)
                        .saturation(1.15)
                        .opacity(0.22)
                        .allowsHitTesting(false)
                }
                ArtworkView(
                    title: album.title,
                    artworkKey: album.artworkKey,
                    colors: theme.colorTokens,
                    size: 280,
                    cornerRadius: 14
                )
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
            .frame(width: 320, height: 320)

            VStack(alignment: .leading, spacing: 12) {
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
                Text(metadataLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    MacPrimaryButton(title: "播放", systemImage: "play.fill") {
                        model.playQueue(tracks)
                    }
                    MacPrimaryButton(title: "随机播放", systemImage: "shuffle", prominent: false) {
                        model.playShuffledQueue(tracks)
                    }
                    Button {
                        model.toggleAlbumFavorite(album)
                    } label: {
                        Image(systemName: model.isAlbumFavorite(album) ? "heart.fill" : "heart")
                            .frame(width: 32, height: 32)
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
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 32, height: 32)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("更多操作")
                }
            }
            Spacer()
        }
        .padding(.top, 20)
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        if let genre = album.genre, !genre.isEmpty { parts.append(genre) }
        parts.append("\(tracks.count) 首")
        parts.append(MacFormat.durationSum(tracks))
        return parts.joined(separator: " · ")
    }

    // MARK: - Track list

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(discGroups, id: \.disc) { group in
                if discGroups.count > 1 {
                    Text("Disc \(group.disc)")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 6)
                }
                MacSongTable(
                    tracks: group.tracks,
                    selection: $selection,
                    model: model,
                    theme: theme,
                    onNavigate: onNavigate,
                    numberText: { track in track.trackNumber.map(String.init) },
                    showAlbumColumn: false,
                    showYearColumn: false,
                    showGenreColumn: false,
                    showFormatColumn: true,
                    showArtwork: false,
                    rowHeight: 34
                )
            }
        }
    }

    // MARK: - Bottom metadata / more info

    private var bottomMetadata: some View {
        HStack(spacing: 18) {
            Text("\(album.year.map(String.init) ?? "未知年份") · \(tracks.count) 首 · \(MacFormat.durationSum(tracks))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let codecs = codecSummary {
                Text(codecs)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private var codecSummary: String? {
        let set = Set(tracks.compactMap { MacFormat.codec($0) })
        guard !set.isEmpty else { return nil }
        return "格式：" + set.sorted().joined(separator: " / ")
    }

    private var moreInfo: some View {
        DisclosureGroup("更多信息") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("专辑", album.title)
                infoRow("艺术家", album.artistName)
                infoRow("发行年份", album.year.map(String.init) ?? "未知")
                infoRow("流派", album.genre ?? "未知")
                infoRow("曲目数", "\(tracks.count)")
                infoRow("总时长", MacFormat.durationSum(tracks))
                Text("公开音乐资料（MusicBrainz / CritiqueBrainz / ListenBrainz）可在单曲「歌曲信息」中查看核验。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.top, 6)
        }
        .font(.subheadline)
        .padding(.top, 14)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
#endif
