#if os(macOS)
import DesignSystem
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 按照 macOS 音乐 App 的网格、详情和曲目表共享同一套尺寸，避免同级控件各自写一组间距。
private enum MacMusicLayout {
    static let pageInset: CGFloat = 28
    static let gridSpacing: CGFloat = 24
    static let artworkCornerRadius: CGFloat = 10
    static let detailArtworkSize: CGFloat = 264
}

// MARK: - 歌曲表格（macOS 原生 Table）

/// 适合鼠标的歌曲表格：可调列宽、多选（Shift/Cmd）、双击播放、右键菜单、悬停反馈。
struct MacSongTable: View {
    let tracks: [Track]
    @Binding var selection: Set<TrackID>
    let model: AuralisAppModel
    let theme: BuiltInTheme

    var body: some View {
        Table(tracks, selection: $selection) {
            TableColumn("标题") { track in
                Text(track.title)
                    .fontWeight(track.id == model.currentTrack.id ? .semibold : .regular)
                    .lineLimit(1)
            }
            TableColumn("艺术家", value: \.artistName)
            TableColumn("专辑", value: \.albumTitle)
            TableColumn("时长") { track in
                Text(Self.timeText(track.duration))
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            .width(60)
            TableColumn("年份") { track in
                if let year = track.year {
                    Text(String(year)).foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            }
            .width(50)
            TableColumn("格式") { track in
                if let codec = track.sourceInfo.normalizedCodec, !codec.isEmpty {
                    Text(codec.uppercased()).font(.caption2)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            }
            .width(64)
            TableColumn("收藏") { track in
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(track.isFavorite ? theme.colorTokens.accent.color : theme.colorTokens.secondaryText.color.opacity(0.5))
            }
            .width(44)
        }
        .contextMenu(forSelectionType: TrackID.self) { ids in
            if let first = tracks.first(where: { $0.id == ids.first }) {
                Button("播放") { model.selectAndPlay(first) }
                Button("下一首播放") { model.playNext(globalID: GlobalID(serverID: first.serverID, remoteID: first.id.rawValue)) }
                Button("加入队列") { model.addToQueue(globalID: GlobalID(serverID: first.serverID, remoteID: first.id.rawValue)) }
                Divider()
                Button(trackIsFavorite(first) ? "取消收藏" : "收藏") { model.toggleFavorite(first) }
                Button("下载") { model.download(first) }
            }
        } primaryAction: { ids in
            if let first = tracks.first(where: { $0.id == ids.first }) {
                model.selectAndPlay(first)
            }
        }
        .onTapGesture(count: 2) {
            if let first = selection.first, let track = tracks.first(where: { $0.id == first }) {
                model.selectAndPlay(track)
            }
        }
    }

    private func trackIsFavorite(_ track: Track) -> Bool {
        model.catalog.tracks.first(where: { $0.id == track.id })?.isFavorite ?? track.isFavorite
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 通用曲目列表页

/// 用于「最近播放 / 最近添加 / 收藏歌曲」等：标题 + 表格 + 顶部操作。
struct MacTrackListPage: View {
    let title: String
    let tracks: [Track]
    @Binding var selection: Set<TrackID>
    let model: AuralisAppModel
    let theme: BuiltInTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title2.bold())
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Spacer()
                Button("播放全部") { model.playQueue(tracks) }
                    .disabled(tracks.isEmpty)
                Button("随机播放") { model.playRandom() }
                    .disabled(tracks.isEmpty)
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.medium)
            Divider()
            if tracks.isEmpty {
                ContentUnavailableView("暂无歌曲", systemImage: "music.note",
                                       description: Text("这个清单里暂时没有歌曲。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacSongTable(tracks: tracks, selection: $selection, model: model, theme: theme)
            }
        }
        .background(theme.colorTokens.background.color)
    }
}

// MARK: - 音乐库页（歌曲表格 / 专辑网格 / 艺术家 / 流派）

struct MacLibraryPage: View {
    let scope: MacLibraryScope
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<TrackID>

    var body: some View {
        VStack(spacing: 0) {
            header
            switch scope {
            case .songs:
                if model.catalog.tracks.isEmpty {
                    ContentUnavailableView("资料库还没有歌曲", systemImage: "music.note", description: Text("连接服务器并同步后，这里会列出全部歌曲。"))
                } else {
                    MacSongTable(tracks: model.catalog.tracks, selection: $selection, model: model, theme: theme)
                }
            case .albums:
                albumGrid
            case .artists:
                artistList
            case .genres:
                genreList
            }
        }
        .background(theme.colorTokens.background.color)
    }

    private var header: some View {
        HStack(spacing: AuralisSpacing.medium) {
            Text(scope.title).font(.title2.weight(.bold))
                .foregroundStyle(theme.colorTokens.primaryText.color)
            Spacer()
            if scope == .songs, !model.catalog.tracks.isEmpty {
                Button("播放全部") { model.playQueue(model.catalog.tracks) }
                Button("随机播放") { model.playRandom() }
            }
        }
        .padding(.horizontal, MacMusicLayout.pageInset)
        .padding(.vertical, 18)
    }

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 148, maximum: 190), spacing: MacMusicLayout.gridSpacing)],
                alignment: .leading,
                spacing: MacMusicLayout.gridSpacing
            ) {
                ForEach(model.catalog.albums) { album in
                    Button {
                        model.browseDestination = .album(album)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            GeometryReader { geo in
                                ArtworkView(title: album.title, artworkKey: album.artworkKey,
                                            colors: theme.colorTokens, size: max(geo.size.width, 1), cornerRadius: MacMusicLayout.artworkCornerRadius)
                            }
                            .aspectRatio(1, contentMode: .fit)
                            Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                .foregroundStyle(theme.colorTokens.primaryText.color)
                            Text(album.artistName).font(.caption).lineLimit(1)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MacMusicLayout.pageInset)
            .padding(.bottom, 36)
        }
    }

    private var artistList: some View {
        List(model.catalog.artists) { artist in
            Button {
                model.browseDestination = .artist(artist)
            } label: {
                HStack(spacing: AuralisSpacing.medium) {
                    Image(systemName: "person.crop.circle")
                        .font(.title2)
                        .foregroundStyle(theme.colorTokens.accent.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).font(.body.weight(.medium))
                        Text("\(artist.albumCount) 张专辑").font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var genreList: some View {
        let items = Self.sortedGenres(model)
        if items.isEmpty {
            ContentUnavailableView("还没有流派", systemImage: "music.quarternote.3", description: Text("服务器返回的流派（来自音乐文件内嵌标签）会显示在这里；连接并同步后即可按流派浏览。"))
                .task { model.refreshGenres() }
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: AuralisSpacing.large)],
                    alignment: .leading,
                    spacing: AuralisSpacing.medium
                ) {
                    ForEach(items, id: \.genre.id) { item in
                        Button {
                            model.browseDestination = .genre(item.genre)
                        } label: {
                            VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                                HStack {
                                    Image(systemName: "music.quarternote.3")
                                        .font(.title3)
                                        .foregroundStyle(theme.colorTokens.accent.color)
                                    Spacer()
                                    Text("\(item.count)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                                }
                                Text(GenreLocalization.displayName(for: item.genre.name))
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                    .foregroundStyle(theme.colorTokens.primaryText.color)
                                Text("\(item.count) 首")
                                    .font(.caption)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                            }
                            .padding(AuralisSpacing.medium)
                            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                            .background(theme.colorTokens.surface.color)
                            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(AuralisSpacing.large)
            }
            .task { model.refreshGenres() }
        }
    }

    /// 聚合流派并按实际歌曲数降序（数量相同按名称排序）。
    private static func sortedGenres(_ model: AuralisAppModel) -> [(genre: Genre, count: Int)] {
        let items: [(genre: Genre, count: Int)] = model.catalog.genres.map { genre in
            (genre, model.tracks(for: genre).count)
        }
        return items.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return left.genre.name.localizedStandardCompare(right.genre.name) == .orderedAscending
        }
    }
}

// MARK: - 专辑详情（Mac 的主内容导航）

/// 复刻 macOS 音乐 App 的专辑层级：大封面与元数据在同一视觉层，
/// 播放操作紧随标题，曲目用极简行列表而非设置样式的卡片或通用弹窗。
struct MacAlbumDetailPage: View {
    let album: Album
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let onBack: () -> Void
    @State private var hoveredTrackID: TrackID?

    private var tracks: [Track] {
        model.catalog.tracks
            .filter { $0.albumID == album.id }
            .sorted { lhs, rhs in
                let leftDisc = lhs.discNumber ?? 0
                let rightDisc = rhs.discNumber ?? 0
                if leftDisc != rightDisc { return leftDisc < rightDisc }
                let leftTrack = lhs.trackNumber ?? 0
                let rightTrack = rhs.trackNumber ?? 0
                if leftTrack != rightTrack { return leftTrack < rightTrack }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    private var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    private var summary: String {
        let count = "\(tracks.count) 首歌曲"
        let minutes = max(1, Int((totalDuration / 60).rounded()))
        return "\(count)，\(minutes) 分钟"
    }

    private var metadata: String {
        var parts = [String]()
        if let year = album.year { parts.append(String(year)) }
        if let genre = album.genre, !genre.isEmpty { parts.append(GenreLocalization.displayName(for: genre)) }
        parts.append(summary)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    albumHero
                    trackList
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, 54)
                .padding(.bottom, 42)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.colorTokens.background.color)
    }

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("返回专辑")

            Spacer()

            Menu {
                Button("下载专辑") { model.downloadAll(tracks) }
                    .disabled(tracks.isEmpty)
                Button("加入播放队列") { model.queue = tracks }
                    .disabled(tracks.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.primary)
            .help("更多")
        }
        .padding(.horizontal, MacMusicLayout.pageInset)
        .padding(.vertical, 12)
    }

    private var albumHero: some View {
        HStack(alignment: .center, spacing: 30) {
            ArtworkView(
                title: album.title,
                artworkKey: album.artworkKey,
                colors: theme.colorTokens,
                size: MacMusicLayout.detailArtworkSize,
                cornerRadius: 14
            )
            .shadow(color: .black.opacity(0.12), radius: 16, y: 7)

            VStack(alignment: .leading, spacing: 7) {
                Text(album.title)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                    .lineLimit(2)

                Text(album.artistName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.colorTokens.accent.color)
                    .lineLimit(1)

                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                    .lineLimit(2)

                Spacer(minLength: 24)

                HStack(spacing: 10) {
                    circularAction(symbol: "shuffle", help: "随机播放") {
                        guard !tracks.isEmpty else { return }
                        model.queue = tracks.shuffled()
                        if let first = model.queue.first { model.selectAndPlay(first) }
                    }

                    Button {
                        model.playQueue(tracks)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 92, minHeight: 34)
                            .foregroundStyle(theme.colorTokens.accent.color)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(tracks.isEmpty)

                    circularAction(symbol: "arrow.down", help: "下载专辑") {
                        model.downloadAll(tracks)
                    }
                    .disabled(tracks.isEmpty)
                }
            }
            .frame(minHeight: MacMusicLayout.detailArtworkSize, alignment: .leading)
        }
        .padding(.top, 18)
        .padding(.bottom, 26)
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 12) {
                    Text(track.trackNumber.map(String.init) ?? String(index + 1))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                        .frame(width: 28, alignment: .trailing)

                    Button {
                        model.queue = tracks
                        model.selectAndPlay(track)
                    } label: {
                        Text(track.title)
                            .font(.body.weight(track.id == model.currentTrack.id ? .semibold : .regular))
                            .foregroundStyle(track.id == model.currentTrack.id ? theme.colorTokens.accent.color : theme.colorTokens.primaryText.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)

                    Text(timeText(track.duration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                        .frame(width: 48, alignment: .trailing)

                    Menu {
                        Button(track.isFavorite ? "取消收藏" : "收藏") { model.toggleFavorite(track) }
                        Button("下一首播放") { model.playNext(globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)) }
                        Button("下载") { model.download(track) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 30)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(.secondary)
                    .help("更多")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(hoveredTrackID == track.id ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hoveredTrackID = $0 ? track.id : nil }

                if track.id != tracks.last?.id {
                    Divider().padding(.leading, 50)
                }
            }

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
                .padding(.top, 20)
                .padding(.leading, 10)
        }
    }

    private func circularAction(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.colorTokens.accent.color)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func timeText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 歌单页

struct MacPlaylistPage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var selection: Set<TrackID> = []
    @State private var showCreate = false
    @State private var newName = ""
    @State private var renameTarget: Playlist?
    @State private var renameText = ""
    @State private var deleteTarget: Playlist?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("我的歌单").font(.title2.bold())
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Spacer()
                Button("新建歌单") { showCreate = true }
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.medium)
            Divider()
            if model.catalog.playlists.isEmpty {
                ContentUnavailableView("暂无歌单", systemImage: "music.note.list", description: Text("创建或同步歌单后会显示在这里。"))
            } else {
                List(model.catalog.playlists) { playlist in
                    Button {
                        model.browseDestination = .playlist(playlist)
                    } label: {
                        HStack(spacing: AuralisSpacing.medium) {
                            if let coverKey = playlistFirstTrackArtworkKey(model, playlist) {
                                ArtworkView(title: playlist.name, artworkKey: coverKey, colors: theme.colorTokens, size: 40, cornerRadius: 8)
                            } else {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(theme.colorTokens.accent.color)
                                    .frame(width: 40, height: 40)
                                    .background(theme.colorTokens.surface.color)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).font(.body.weight(.medium))
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("重命名") {
                            renameTarget = playlist
                            renameText = playlist.name
                        }
                        Button("删除", role: .destructive) { deleteTarget = playlist }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(theme.colorTokens.background.color)
        .alert("新建歌单", isPresented: $showCreate) {
            TextField("歌单名称", text: $newName)
            Button("创建") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { Task { _ = await model.createPlaylist(named: name) } }
                newName = ""
            }
            Button("取消", role: .cancel) { newName = "" }
        }
        .alert("重命名歌单", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("歌单名称", text: $renameText)
            Button("保存") {
                if let target = renameTarget {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { Task { _ = await model.renamePlaylist(id: target.id, to: name) } }
                }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .alert("删除歌单？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget { Task { _ = await model.deletePlaylist(id: target.id) } }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("删除后本机与服务器上的该歌单将被移除（歌曲本身不受影响）。")
        }
    }
}

// MARK: - 下载页

struct MacDownloadsPage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var selection: Set<TrackID> = []
    @State private var usage = AuralisAppModel.CacheUsage()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("下载").font(.title2.bold())
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Spacer()
                Text("音频缓存 \(Self.bytes(usage.audioBytes)) · \(usage.audioCount) 首")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.medium)
            Divider()
            MacSongTable(tracks: model.catalog.tracks.filter { model.isDownloaded($0) },
                         selection: $selection, model: model, theme: theme)
        }
        .background(theme.colorTokens.background.color)
        .task { usage = await model.cacheUsage() }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

// MARK: - Mac 首页（响应式网格，充分利用窗口宽度）

struct MacHomePage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<TrackID>
    let onOpenServer: () -> Void

    private let gridColumns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: AuralisSpacing.large)]

    var body: some View {
        ScrollView {
            Group {
                if model.catalog.tracks.isEmpty {
                    emptyLibrary
                } else {
                    LazyVStack(alignment: .leading, spacing: AuralisSpacing.xLarge) {
                        if model.currentTrack.id.rawValue != "placeholder" {
                            continuePlaying
                        }
                        serverStatusRow
                        if !model.recentlyPlayedTracks.isEmpty {
                            songShelf(title: "最近播放", tracks: model.recentlyPlayedTracks.prefix(12).map { $0 }) {
                                model.browseDestination = .recentlyPlayed
                            }
                        }
                        if !model.recentlyAddedTracks.isEmpty {
                            songShelf(title: "最近添加", tracks: Array(model.recentlyAddedTracks.prefix(12))) {
                                model.browseDestination = .recentlyAdded
                            }
                        }
                        if !model.favoriteTracks.isEmpty {
                            songShelf(title: "收藏", tracks: model.favoriteTracks.prefix(12).map { $0 }) {
                                model.browseDestination = .favorites
                            }
                        }
                        if !model.catalog.playlists.isEmpty {
                            playlistShelf
                        }
                    }
                }
            }
            .padding(AuralisSpacing.large)
        }
        .background(theme.colorTokens.background.color)
    }

    /// 空资料库沿用 Apple Music 的“内容舞台”而不是设置向导：一张主卡只保留
    /// 一个清晰动作，避免把首次使用拆成生硬的 1/2/3 面板。
    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("资料库")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.colorTokens.secondaryText.color)

            Text("让音乐回到你的 Mac")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(theme.colorTokens.primaryText.color)

            Text("连接你的 Navidrome、OpenSubsonic 或兼容服务器后，专辑、歌手和播放列表都会出现在这里。")
                .font(.title3)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
                .frame(maxWidth: 620, alignment: .leading)

            Button(action: onOpenServer) {
                Label("添加音乐服务器", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 16) {
                emptyArtwork(symbol: "music.note")
                emptyArtwork(symbol: "waveform")
                emptyArtwork(symbol: "headphones")
            }
            .padding(.top, 10)

            serverStatusRow
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: 760, minHeight: 460, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background {
            LinearGradient(
                colors: [theme.colorTokens.accent.color.opacity(0.10), theme.colorTokens.background.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func emptyArtwork(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(theme.colorTokens.accent.color.opacity(0.8))
            .frame(width: 74, height: 74)
            .background(theme.colorTokens.surface.color.opacity(0.85), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var continuePlaying: some View {
        Button {
            model.togglePlayback()
        } label: {
            HStack(spacing: AuralisSpacing.medium) {
                ArtworkView(title: model.currentTrack.albumTitle,
                            artworkKey: model.currentTrack.artworkKey,
                            colors: theme.colorTokens, size: 64, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text("继续播放").font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    Text(model.currentTrack.title).font(.title3.bold()).lineLimit(1)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text(model.currentTrack.artistName).font(.subheadline).lineLimit(1)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer()
                Image(systemName: model.playbackState == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(theme.colorTokens.accent.color)
            }
            .padding(AuralisSpacing.large)
            .background(theme.colorTokens.surface.color.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var serverStatusRow: some View {
        HStack(spacing: AuralisSpacing.small) {
            if case .connected = model.serverConnectionState {
                Label("已连接", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme.colorTokens.success.color)
            } else if case .failed = model.serverConnectionState {
                Label("服务器离线", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.colorTokens.warning.color)
            } else {
                Label("未连接服务器", systemImage: "server.rack")
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Spacer()
            if model.catalog.isConnected {
                Text("\(model.catalog.tracks.count) 首歌曲")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        }
        .font(.caption)
    }

    private func songShelf(title: String, tracks: [Track], onMore: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
            HStack {
                Text(title).font(.title3.bold())
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Spacer()
                Button("查看全部") { onMore() }
                    .buttonStyle(.link)
            }
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: AuralisSpacing.large) {
                ForEach(tracks) { track in
                    Button {
                        model.playQueue([track])
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(title: track.albumTitle, artworkKey: track.artworkKey,
                                        colors: theme.colorTokens, size: 200, cornerRadius: AuralisRadius.medium)
                            Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                .foregroundStyle(theme.colorTokens.primaryText.color)
                            Text(track.artistName).font(.caption).lineLimit(1)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                        .frame(maxWidth: 260, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var playlistShelf: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
            HStack {
                Text("常用歌单").font(.title3.bold())
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Spacer()
                Button("查看全部") { model.browseDestination = .playlists }
                    .buttonStyle(.link)
            }
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: AuralisSpacing.large) {
                ForEach(model.catalog.playlists.prefix(8)) { playlist in
                    Button {
                        model.browseDestination = .playlist(playlist)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: AuralisRadius.medium)
                                    .fill(theme.colorTokens.accent.color.opacity(0.12))
                                if let coverKey = playlistFirstTrackArtworkKey(model, playlist) {
                                    GeometryReader { geo in
                                        ArtworkView(title: playlist.name, artworkKey: coverKey, colors: theme.colorTokens, size: max(geo.size.width, 1))
                                    }
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
                                } else {
                                    Image(systemName: "music.note.list").font(.system(size: 36)).foregroundStyle(theme.colorTokens.accent.color)
                                }
                            }
                            .frame(height: 120)
                            Text(playlist.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                .foregroundStyle(theme.colorTokens.primaryText.color)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// 歌单封面：取歌单内第一首歌曲的封面（同一专辑多首歌曲共享封面）。
@MainActor
private func playlistFirstTrackArtworkKey(_ model: AuralisAppModel, _ playlist: Playlist) -> String? {
    guard let firstID = playlist.trackIDs.first else { return nil }
    return model.catalog.tracks.first { $0.id == firstID }?.artworkKey
}

// MARK: - Mac 搜索页（侧边栏输入，主内容展示结果与承接内容）

struct MacSearchPage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let query: String
    @Binding var selection: Set<TrackID>

    @State private var tracks: [CatalogTrackSummary] = []
    @State private var albums: [CatalogAlbumSummary] = []
    @State private var artists: [CatalogArtistSummary] = []
    @State private var playlists: [Playlist] = []
    @State private var recentSearches: [String] = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private let recentKey = "auralis.mac.recentSearches"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("搜索").font(.title2.bold())
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Spacer()
            }
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.medium)
            Divider()
            if trimmedQuery.isEmpty {
                idleContent
            } else {
                resultsContent
            }
        }
        .background(theme.colorTokens.background.color)
        .onAppear {
            recentSearches = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        }
        .task(id: trimmedQuery) { await runSearch() }
    }

    private func runSearch() async {
        let q = trimmedQuery
        guard !q.isEmpty else {
            tracks = []; albums = []; artists = []; playlists = []
            return
        }
        let store = model.catalogCoordinator.store
        let serverID = model.catalog.activeServerID
        tracks = (try? await store.searchTracks(query: q, serverID: serverID)) ?? []
        albums = (try? await store.searchAlbums(query: q, serverID: serverID)) ?? []
        artists = (try? await store.searchArtists(query: q, serverID: serverID)) ?? []
        playlists = model.catalog.playlists.filter { $0.name.localizedCaseInsensitiveContains(q) }
        saveRecent(q)
    }

    private func saveRecent(_ q: String) {
        var recent = recentSearches.filter { $0.lowercased() != q.lowercased() }
        recent.insert(q, at: 0)
        recent = Array(recent.prefix(8))
        recentSearches = recent
        UserDefaults.standard.set(recent, forKey: recentKey)
    }

    // MARK: - 未输入：承接内容

    private var idleContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AuralisSpacing.large) {
                if !recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                        Text("最近搜索").font(.headline)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        FlowTagsForMac(tags: recentSearches, theme: theme) { tag in
                            model.macSearchQuery = tag
                        }
                    }
                }
                if !recentArtists.isEmpty {
                    VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                        Text("最近播放的艺术家").font(.headline)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: AuralisSpacing.medium)], alignment: .leading) {
                            ForEach(recentArtists, id: \.self) { artist in
                                HStack(spacing: AuralisSpacing.small) {
                                    Image(systemName: "person.crop.circle")
                                        .font(.title2)
                                        .foregroundStyle(theme.colorTokens.accent.color)
                                    Text(artist).lineLimit(1)
                                        .foregroundStyle(theme.colorTokens.primaryText.color)
                                }
                                .padding(8)
                                .background(theme.colorTokens.surface.color.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                }
                if !model.catalog.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                        Text("常用歌单").font(.headline)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: AuralisSpacing.medium)], alignment: .leading) {
                            ForEach(model.catalog.playlists.prefix(6)) { playlist in
                                Button {
                                    model.browseDestination = .playlist(playlist)
                                } label: {
                                    HStack(spacing: AuralisSpacing.small) {
                                        Image(systemName: "music.note.list")
                                            .foregroundStyle(theme.colorTokens.accent.color)
                                        Text(playlist.name).lineLimit(1)
                                            .foregroundStyle(theme.colorTokens.primaryText.color)
                                    }
                                    .padding(8)
                                    .background(theme.colorTokens.surface.color.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text("在左侧搜索框输入关键词，可搜索歌曲、专辑、艺术家与歌单。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            .padding(AuralisSpacing.large)
        }
    }

    private var recentArtists: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for track in model.recentlyPlayedTracks {
            let name = track.artistName
            if seen.insert(name).inserted {
                result.append(name)
                if result.count >= 8 { break }
            }
        }
        return result
    }

    // MARK: - 输入后：分类结果

    private var resultsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AuralisSpacing.large) {
                if !tracks.isEmpty {
                    sectionTitle("歌曲（\(tracks.count)）")
                    ForEach(tracks.prefix(20)) { summary in
                        resultSongRow(summary)
                    }
                }
                if !albums.isEmpty {
                    sectionTitle("专辑（\(albums.count)）")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: AuralisSpacing.large)], alignment: .leading) {
                        ForEach(albums.prefix(12)) { album in
                            Button {
                                if let real = model.catalog.albums.first(where: { $0.id.rawValue == album.globalID.remoteID }) {
                                    model.browseDestination = .album(real)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    GeometryReader { geo in
                                        ArtworkView(title: album.title, artworkKey: nil, colors: theme.colorTokens, size: max(geo.size.width, 1), cornerRadius: AuralisRadius.medium)
                                    }
                                    .aspectRatio(1, contentMode: .fit)
                                    Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                        .foregroundStyle(theme.colorTokens.primaryText.color)
                                    Text(album.artistName).font(.caption).lineLimit(1)
                                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !artists.isEmpty {
                    sectionTitle("艺术家（\(artists.count)）")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: AuralisSpacing.medium)], alignment: .leading) {
                        ForEach(artists.prefix(12)) { artist in
                            HStack(spacing: AuralisSpacing.small) {
                                Image(systemName: "person.crop.circle")
                                    .font(.title2)
                                    .foregroundStyle(theme.colorTokens.accent.color)
                                Text(artist.name).lineLimit(1)
                                    .foregroundStyle(theme.colorTokens.primaryText.color)
                            }
                            .padding(8)
                            .background(theme.colorTokens.surface.color.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                if !playlists.isEmpty {
                    sectionTitle("歌单（\(playlists.count)）")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: AuralisSpacing.medium)], alignment: .leading) {
                        ForEach(playlists.prefix(8)) { playlist in
                            Button {
                                model.browseDestination = .playlist(playlist)
                            } label: {
                                HStack(spacing: AuralisSpacing.small) {
                                    Image(systemName: "music.note.list")
                                        .foregroundStyle(theme.colorTokens.accent.color)
                                    Text(playlist.name).lineLimit(1)
                                        .foregroundStyle(theme.colorTokens.primaryText.color)
                                }
                                .padding(8)
                                .background(theme.colorTokens.surface.color.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty {
                    ContentUnavailableView("未找到结果", systemImage: "magnifyingglass",
                                           description: Text("没有找到与「\(trimmedQuery)」匹配的歌曲、专辑、艺术家或歌单。"))
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(AuralisSpacing.large)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
            .foregroundStyle(theme.colorTokens.primaryText.color)
    }

    private func resultSongRow(_ summary: CatalogTrackSummary) -> some View {
        Button {
            if let track = model.catalog.tracks.first(where: { $0.id.rawValue == summary.globalID.remoteID }) {
                model.playQueue([track])
            }
        } label: {
            HStack(spacing: AuralisSpacing.medium) {
                ArtworkView(title: summary.albumTitle, artworkKey: nil, colors: theme.colorTokens, size: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title).font(.body)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text("\(summary.artistName) · \(summary.albumTitle)").font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 简单的流式标签（可点击）。
private struct FlowTagsForMac: View {
    let tags: [String]
    let theme: BuiltInTheme
    let onTap: (String) -> Void
    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    onTap(tag)
                } label: {
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.colorTokens.surface.color.opacity(0.6))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
#endif
