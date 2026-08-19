#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// Artist Detail：Hero（mosaic/monogram）+ 常听歌曲 + 专辑网格。
/// 「常听歌曲」按本机播放次数排序（用户个人常听，不是外部热门），单曲行不嵌套 Table。
///
/// 崩溃/卡顿防护：艺术家曲目与专辑按 `artist.macGlobalID|catalogRevision` 在 `.task(id:)`
/// 里解析一次并缓存到 @State，body 只消费缓存数组；不再在每次 body 求值时全库扫描
/// （数千歌曲/专辑的艺术家 + 播放中频繁重绘时，原本 O(N) × body 次数会卡死主线程）。
struct MacArtistView: View {
    let artist: Artist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var artistTracks: [Track] = []
    @State private var artistAlbums: [Album] = []

    /// 缓存键：艺术家身份 + 目录修订号。目录刷新或切换艺术家时重新解析。
    private var artistResolveKey: String {
        "\(artist.macGlobalID)|\(model.catalogRevision)"
    }

    /// 用户自己的常听歌曲：只展示真正播放过的 Top 12。完整曲目仍可从歌曲页搜索，
    /// Artist Hero 不再因一个拥有数千首歌的艺术家而创建整套行视图。
    private var topTracks: [Track] {
        Self.topPlayedTracks(artistTracks, playCounts: model.playCounts)
    }

    /// 常听 Top N（纯函数，供测试直接调用）：只取播放次数 > 0 的曲目，
    /// 按播放次数降序，取前 limit 首。基于缓存后的 artistTracks，不重新扫描目录。
    static func topPlayedTracks(_ tracks: [Track], playCounts: [TrackID: Int], limit: Int = 12) -> [Track] {
        Array(tracks
            .filter { (playCounts[$0.id] ?? 0) > 0 }
            .sorted { (playCounts[$0.id] ?? 0) > (playCounts[$1.id] ?? 0) }
            .prefix(limit))
    }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MacUIVisualTokens.Artwork.gridGap)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if !topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "常听歌曲", bundle: .module))
                            .font(.system(size: MacUIVisualTokens.Typography.sectionTitle, weight: .bold))
                        MacDetailTrackList(
                            tracks: topTracks,
                            model: model,
                            theme: theme,
                            showAlbum: true,
                            onNavigate: onNavigate
                        )
                    }
                }
                if !artistAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "专辑", bundle: .module))
                            .font(.system(size: MacUIVisualTokens.Typography.sectionTitle, weight: .bold))
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(artistAlbums, id: \.macGlobalID) { album in
                                MacAlbumTile(
                                    album: album,
                                    theme: theme,
                                    size: 150,
                                    onOpen: { onNavigate(.album(album)) },
                                    onPlay: { model.playQueue(MacLibraryQuery.albumTracks(album, model: model)) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .navigationTitle(artist.name)
        .onAppear {
            MacUITrace.action(
                "MacArtistView.create",
                "artists=\(model.catalog.artists.count) tracks=\(model.catalog.tracks.count) "
                    + "albums=\(model.catalog.albums.count) rev=\(model.catalogRevision)"
            )
        }
        .task(id: artistResolveKey) {
            artistTracks = MacLibraryQuery.artistTracks(artist, model: model)
            artistAlbums = MacLibraryQuery.artistAlbums(artist, model: model)
            MacUITrace.action(
                "MacArtistView.resolve",
                "artistTracks=\(artistTracks.count) artistAlbums=\(artistAlbums.count) "
                    + "rev=\(model.catalogRevision)"
            )
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            mosaic
                .frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 10) {
                Text(artist.name)
                    .font(.system(size: 30, weight: .bold, design: .default))
                Text("\(artistAlbums.count) 张专辑 · \(artistTracks.count) 首歌曲")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        if !topTracks.isEmpty { model.playQueue(topTracks) }
                    } label: {
                        Label(String(localized: "播放", bundle: .module), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Button {
                        model.playShuffledQueue(artistTracks)
                    } label: {
                        Label(String(localized: "随机播放", bundle: .module), systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Button {
                        model.toggleArtistFavorite(artist)
                    } label: {
                        Image(systemName: model.isArtistFavorite(artist) ? "heart.fill" : "heart")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .help(model.isArtistFavorite(artist) ? "取消收藏艺术家" : "收藏艺术家")
                    .accessibilityLabel(model.isArtistFavorite(artist) ? String(localized: "取消收藏艺术家", bundle: .module) : String(localized: "收藏艺术家", bundle: .module))
                    Menu {
                        Button(String(localized: "下载全部", bundle: .module)) { model.downloadAll(artistTracks) }
                        Button(String(localized: "随机播放全部", bundle: .module)) { model.playShuffledQueue(artistTracks) }
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
            Spacer()
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private var mosaic: some View {
        let reps = Array(artistAlbums.prefix(4))
        if let key = artist.artworkKey {
            ArtworkView(title: artist.name, artworkKey: key, colors: theme.colorTokens, size: 200, cornerRadius: 100)
        } else if reps.count == 4 {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(reps, id: \.macGlobalID) { album in
                    ArtworkView(title: album.title, artworkKey: album.artworkKey, colors: theme.colorTokens, size: 96, cornerRadius: 8)
                }
            }
            .frame(width: 196, height: 196)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 100, style: .continuous)
                    .fill(.quaternary)
                Text(String(artist.name.prefix(1)).uppercased())
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 200, height: 200)
        }
    }
}
#endif