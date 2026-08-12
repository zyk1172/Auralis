#if os(macOS)
import DesignSystem
import Domain
import SwiftUI
import ThemeEngine

// MARK: - Playlist Artwork（真实 mosaic，去重封面）

/// 歌单封面：0 首 → 中性占位；1 首 → 单一封面；2 首 → 左右均分；
/// 3+ 首 → 2×2（取前 4 个不同 artworkKey）。整体统一圆角，避免小图胶囊感。
struct MacPlaylistArtwork: View {
    let playlist: Playlist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let size: CGFloat
    var cornerRadius: CGFloat = 10

    var body: some View {
        let keys = distinctArtworkKeys
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary)
            switch keys.count {
            case 0:
                Image(systemName: "music.note.list")
                    .font(.system(size: size * 0.28))
                    .foregroundStyle(.secondary)
            case 1:
                artworkCell(keys[0], cornerRadius: cornerRadius)
            case 2:
                HStack(spacing: 2) {
                    artworkCell(keys[0], cornerRadius: 0)
                    artworkCell(keys[1], cornerRadius: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            default:
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(Array(keys.prefix(4)), id: \.self) { key in
                        artworkCell(key, cornerRadius: 0)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(playlist.name) 封面")
    }

    private var distinctArtworkKeys: [String] {
        Self.artworkKeys(playlist: playlist, model: model)
    }

    /// 前 4 个不同 artworkKey（nil 视为同一占位，只取一次）。供测试直接调用。
    @MainActor
    static func artworkKeys(playlist: Playlist, model: AuralisAppModel) -> [String] {
        let tracks = MacLibraryQuery.playlistTracks(playlist, model: model)
        var seen = Set<String>()
        var keys: [String] = []
        for track in tracks {
            let key = track.artworkKey ?? "__placeholder__"
            if seen.insert(key).inserted {
                keys.append(track.artworkKey ?? "")
                if keys.count >= 4 { break }
            }
        }
        return keys
    }

    private func artworkCell(_ key: String, cornerRadius: CGFloat) -> some View {
        if key.isEmpty {
            return AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: 0).fill(.quaternary)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            )
        }
        return AnyView(
            ArtworkView(
                title: playlist.name,
                artworkKey: key,
                colors: theme.colorTokens,
                size: size,
                cornerRadius: cornerRadius
            )
        )
    }
}

// MARK: - Album Tile

struct MacAlbumTile: View {
    let album: Album
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var size: CGFloat = MacLayout.albumArtworkSize
    var onOpen: (() -> Void)? = nil
    var onPlay: (() -> Void)? = nil
    var moreActions: [MacMenuAction] = []

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    title: album.title,
                    artworkKey: album.artworkKey,
                    colors: theme.colorTokens,
                    size: size,
                    cornerRadius: MacLayout.artworkCornerRadius
                )
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                .accessibilityHidden(true)
                if isHovering {
                    hoverControls
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .frame(width: size, height: size)
            Text(album.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(album.artistName)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.title)，\(album.artistName)")
    }

    private var hoverControls: some View {
        HStack(spacing: 6) {
            if let onPlay {
                Button {
                    onPlay()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("播放")
                .accessibilityLabel("播放")
            }
            if !moreActions.isEmpty {
                Menu {
                    ForEach(moreActions) { action in
                        Button {
                            action.action()
                        } label: {
                            Label(action.title, systemImage: action.systemImage ?? "circle")
                        }
                        .disabled(action.disabled)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(.thinMaterial, in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
                .accessibilityLabel("更多操作")
            }
        }
    }
}

// MARK: - Artist Tile（有真实图用圆形，否则 mosaic / monogram）

struct MacArtistTile: View {
    let artist: Artist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var size: CGFloat = 150
    var onOpen: (() -> Void)? = nil
    var onPlay: (() -> Void)? = nil

    @State private var isHovering = false

    private var albums: [Album] { MacLibraryQuery.artistAlbums(artist, model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                artistArtwork
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
                if isHovering {
                    Button {
                        onPlay?()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help("随机播放")
                    .accessibilityLabel("随机播放")
                    .transition(.opacity)
                }
            }
            Text(artist.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text("\(artist.albumCount) 张专辑")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artist.name)，\(artist.albumCount) 张专辑")
    }

    @ViewBuilder
    private var artistArtwork: some View {
        if let key = artist.artworkKey {
            ArtworkView(title: artist.name, artworkKey: key, colors: theme.colorTokens, size: size, cornerRadius: size / 2)
        } else if albums.count >= 4 {
            let reps = Array(albums.prefix(4))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                ForEach(reps) { album in
                    ArtworkView(title: album.title, artworkKey: album.artworkKey, colors: theme.colorTokens, size: size / 2, cornerRadius: 0)
                }
            }
            .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(.quaternary)
                Text(String(artist.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Playlist Tile

struct MacPlaylistTile: View {
    let playlist: Playlist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var size: CGFloat = MacLayout.albumArtworkSize
    var onOpen: (() -> Void)? = nil
    var onPlay: (() -> Void)? = nil
    var moreActions: [MacMenuAction] = []

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                MacPlaylistArtwork(playlist: playlist, model: model, theme: theme, size: size)
                    .accessibilityHidden(true)
                if isHovering {
                    HStack(spacing: 6) {
                        if let onPlay {
                            Button {
                                onPlay()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 30, height: 30)
                                    .background(.thinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("播放")
                            .accessibilityLabel("播放")
                        }
                        if !moreActions.isEmpty {
                            Menu {
                                ForEach(moreActions) { action in
                                    Button {
                                        action.action()
                                    } label: {
                                        Label(action.title, systemImage: action.systemImage ?? "circle")
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 30, height: 30)
                                    .background(.thinMaterial, in: Circle())
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("更多操作")
                            .accessibilityLabel("更多操作")
                        }
                    }
                    .padding(8)
                    .transition(.opacity)
                }
            }
            Text(playlist.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text("\(MacLibraryQuery.playlistTracks(playlist, model: model).count) 首")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(playlist.name)
    }
}

// MARK: - Track Tile（Home 曲目货架）

struct MacTrackTile: View {
    let track: Track
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var size: CGFloat = 132
    var onOpen: (() -> Void)? = nil
    var onPlay: (() -> Void)? = nil
    var moreActions: [MacMenuAction] = []

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    title: track.albumTitle,
                    artworkKey: track.artworkKey,
                    colors: theme.colorTokens,
                    size: size,
                    cornerRadius: MacLayout.artworkCornerRadius
                )
                .accessibilityHidden(true)
                if isHovering, let onPlay {
                    Button {
                        onPlay()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help("播放")
                    .accessibilityLabel("播放")
                    .transition(.opacity)
                }
            }
            .frame(width: size, height: size)
            Text(track.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(track.artistName)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title)，\(track.artistName)")
    }
}

// MARK: - 通用菜单动作与 Section 头

/// 右键 / 更多菜单的单个动作。
struct MacMenuAction: Identifiable {
    let id = UUID()
    let title: String
    var systemImage: String? = nil
    var destructive = false
    var disabled = false
    let action: () -> Void
}

/// Section 头：左标题 + 右「查看全部」。
struct MacSectionHeader: View {
    let title: String
    var actionTitle: String? = "查看全部"
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: MacLayout.sectionTitleSize, weight: .bold, design: .default))
            Spacer()
            if let onAction, let actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.link)
                    .font(.body)
            }
        }
        .padding(.horizontal, 2)
    }
}
#endif
