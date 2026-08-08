import Domain
import Foundation
import LocalCatalog

/// 执行 Agent 工具调用的引擎。
///
/// 职责：参数校验、Track ID 真实性校验、按权限分级执行本地操作，返回结构化结果。
/// 权限确认由 Runner 在调用前裁决；本类只负责“已获授权”的执行。
public struct AgentToolkit {
    /// 执行单个工具调用。
    /// - Parameters:
    ///   - call: 工具调用（名称 + 字符串参数）。
    ///   - bridge: 播放/服务器/标注桥接。
    ///   - catalog: 本地目录。
    ///   - serverID: 当前活动服务器，用于多服务器隔离与存在性校验。
    public static func execute(
        _ call: ToolCall,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?
    ) async -> ToolResult {
        guard let descriptor = AgentToolRegistry.descriptor(for: call.name) else {
            return ToolResult(call: call, permission: .readOnly, success: false, summary: "未知工具：\(call.name)")
        }

        do {
            return try await dispatch(call, descriptor: descriptor, bridge: bridge, catalog: catalog, serverID: serverID)
        } catch {
            return ToolResult(call: call, permission: descriptor.permission, success: false,
                              summary: "执行失败：\(error.localizedDescription)")
        }
    }

    /// 统一执行入口（v2）：系统服务工具走 SystemToolExecutor，其余走原有执行路径。
    /// 未提供 systemService 时，系统服务工具返回「系统服务不可用」而非伪造成功。
    public static func executeV2(
        _ call: ToolCall,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        systemService: (any AgentSystemService)?
    ) async -> ToolResult {
        guard let descriptor = AgentToolRegistry.descriptor(for: call.name) else {
            return ToolResult(call: call, permission: .readOnly, success: false, summary: "未知工具：\(call.name)")
        }
        if SystemToolNames.contains(call.name) {
            guard let systemService else {
                return ToolResult(call: call, permission: descriptor.permission, success: false,
                                  summary: "系统服务不可用：\(call.name)")
            }
            return await SystemToolExecutor.execute(call, descriptor: descriptor, systemService: systemService)
        }
        return await execute(call, bridge: bridge, catalog: catalog, serverID: serverID)
    }

    // MARK: - Dispatch

    private static func dispatch(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?
    ) async throws -> ToolResult {
        switch call.name {
        // MARK: Catalog reads
        case "searchTracks":
            let q = try require(call, "q")
            let list = try await catalog.searchTracks(query: q, serverID: serverID)
            return .ok(call, descriptor, "找到 \(list.count) 首", .trackCards(list.map(TrackCard.from)))
        case "searchAlbums":
            let q = try require(call, "q")
            let list = try await catalog.searchAlbums(query: q, serverID: serverID)
            return .ok(call, descriptor, "找到 \(list.count) 张专辑", .albumCards(list.map { AlbumCard(globalID: $0.globalID, title: $0.title, artistName: $0.artistName) }))
        case "searchArtists":
            let q = try require(call, "q")
            let list = try await catalog.searchArtists(query: q, serverID: serverID)
            return .ok(call, descriptor, "找到 \(list.count) 位艺术家", .text("找到 \(list.count) 位艺术家"))
        case "getTrack":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            guard let track = try await catalog.getTrack(gid) else {
                return .fail(call, descriptor, "单曲不存在")
            }
            return .ok(call, descriptor, track.title, .text("\(track.title) · \(track.artistName)"))
        case "getAlbum":
            let gid = try await requireAlbumID(call, "albumID", catalog: catalog, serverID: serverID)
            guard let _ = try await catalog.getAlbum(gid) else { return .fail(call, descriptor, "专辑不存在") }
            return .ok(call, descriptor, "已获取专辑", .text(gid.description))
        case "getArtist":
            let gid = try await requireArtistID(call, "artistID", catalog: catalog, serverID: serverID)
            guard let _ = try await catalog.getArtist(gid) else { return .fail(call, descriptor, "艺术家不存在") }
            return .ok(call, descriptor, "已获取艺术家", .text(gid.description))
        case "getFavorites":
            let list = try await catalog.getFavorites(serverID: serverID)
            return .ok(call, descriptor, "收藏 \(list.count) 首", .trackCards(list.map(TrackCard.from)))
        case "getRecentHistory":
            let limit = (try? intParam(call, "limit")) ?? 50
            let list = try await catalog.getRecentHistory(serverID: serverID, limit: max(1, limit))
            return .ok(call, descriptor, "最近播放 \(list.count) 首", .trackCards(list.map(TrackCard.from)))
        case "getLeastPlayed":
            let limit = (try? intParam(call, "limit")) ?? 50
            let list = try await catalog.getLeastPlayed(serverID: serverID, limit: max(1, limit))
            return .ok(call, descriptor, "最少播放 \(list.count) 首", .trackCards(list.map(TrackCard.from)))
        case "getDownloadedTracks":
            let list = try await catalog.getDownloadedTracks(serverID: serverID)
            return .ok(call, descriptor, "已下载 \(list.count) 首", .trackCards(list.map(TrackCard.from)))
        case "getSimilarTracks":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            let list = try await catalog.getSimilarTracks(gid)
            return .ok(call, descriptor, "相似 \(list.count) 首", .trackCards(list.map(TrackCard.from)))
        case "getCurrentTrack":
            if let track = await bridge.currentTrack() {
                return .ok(call, descriptor, track.title, .text("\(track.title) · \(track.artistName)"))
            }
            return .ok(call, descriptor, "当前无播放", .text("当前没有正在播放的歌曲"))
        case "getCurrentQueue":
            let queue = await bridge.currentQueue()
            return .ok(call, descriptor, "队列 \(queue.count) 首", .text("队列共 \(queue.count) 首"))

        // MARK: Playback
        case "playTrack":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            guard await bridge.playTrack(globalID: gid) else {
                return .fail(call, descriptor, "未找到该歌曲，可能尚未同步到本地目录（可先 server_sync_start 同步，或改用 server_search 在线查找）")
            }
            return .ok(call, descriptor, "开始播放", .actionPreview(title: "播放", detail: gid.description))
        case "playAlbum":
            let gid = try await requireAlbumID(call, "albumID", catalog: catalog, serverID: serverID)
            guard await bridge.playAlbum(globalID: gid) else {
                return .fail(call, descriptor, "未找到该专辑中的可播放歌曲")
            }
            return .ok(call, descriptor, "播放专辑", .actionPreview(title: "播放专辑", detail: gid.description))
        case "playPlaylist":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            guard await bridge.playPlaylist(globalID: gid) else {
                return .fail(call, descriptor, "未找到该歌单中的可播放歌曲")
            }
            return .ok(call, descriptor, "播放歌单", .actionPreview(title: "播放歌单", detail: gid.description))
        case "pause":
            await bridge.pause(); return .ok(call, descriptor, "已暂停")
        case "resume":
            await bridge.resume(); return .ok(call, descriptor, "已继续")
        case "seek":
            let seconds = try doubleParam(call, "seconds")
            await bridge.seek(seconds: seconds)
            return .ok(call, descriptor, "已定位到 \(Int(seconds)) 秒")
        case "next":
            await bridge.next(); return .ok(call, descriptor, "下一首")
        case "previous":
            await bridge.previous(); return .ok(call, descriptor, "上一首")
        case "addToQueue":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            await bridge.addToQueue(globalID: gid); return .ok(call, descriptor, "已加入队列")
        case "playNext":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            await bridge.playNext(globalID: gid); return .ok(call, descriptor, "下一首播放")
        case "replaceQueue":
            let gids = try await requireTrackIDs(call, "trackIDs", catalog: catalog, serverID: serverID)
            await bridge.replaceQueue(globalIDs: gids); return .ok(call, descriptor, "已替换队列（\(gids.count) 首）")
        case "removeFromQueue":
            let index = try intParam(call, "index")
            await bridge.removeFromQueue(at: index); return .ok(call, descriptor, "已移除队列第 \(index) 项")
        case "reorderQueue":
            let from = try intParam(call, "from")
            let to = try intParam(call, "to")
            await bridge.reorderQueue(from: from, to: to); return .ok(call, descriptor, "已调整队列顺序")
        case "clearQueue":
            await bridge.clearQueue(); return .ok(call, descriptor, "已清空队列")

        // MARK: Playlist
        case "listPlaylists":
            let list = try await catalog.listPlaylists(serverID: serverID)
            return .ok(call, descriptor, "歌单 \(list.count) 个", .text("共 \(list.count) 个歌单"))
        case "getPlaylist":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            guard let (playlist, tracks) = try await catalog.getPlaylist(gid) else {
                return .fail(call, descriptor, "歌单不存在")
            }
            return .ok(call, descriptor, playlist.name, .playlistProposal(name: playlist.name, tracks: tracks.map { TrackCard.from(CatalogTrackSummary(globalID: GlobalID(serverID: gid.serverID, remoteID: $0.id.rawValue), title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle, duration: $0.duration, isFavorite: $0.isFavorite, userRating: 0, isDownloaded: false)) }))
        case "createPlaylist":
            let name = try require(call, "name")
            guard let gid = await bridge.createPlaylist(name: name) else {
                return .fail(call, descriptor, "创建歌单失败")
            }
            return .ok(call, descriptor, "已创建歌单", .text("\(name) · \(gid.description)"))
        case "renamePlaylist":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            let name = try require(call, "name")
            await bridge.renamePlaylist(globalID: gid, name: name)
            return .ok(call, descriptor, "已重命名")
        case "addTracksToPlaylist":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            try await requireReadOnlyPlaylist(gid, catalog: catalog)
            let gids = try await requireTrackIDs(call, "trackIDs", catalog: catalog, serverID: serverID)
            await bridge.addTracksToPlaylist(playlistGID: gid, trackGIDs: gids)
            return .ok(call, descriptor, "已添加 \(gids.count) 首")
        case "removeTracksFromPlaylist":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            try await requireReadOnlyPlaylist(gid, catalog: catalog)
            let indices = try intsParam(call, "indices")
            await bridge.removeTracksFromPlaylist(playlistGID: gid, atIndices: indices)
            return .ok(call, descriptor, "已移除 \(indices.count) 首")
        case "reorderPlaylist":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            try await requireReadOnlyPlaylist(gid, catalog: catalog)
            let from = try intParam(call, "from")
            let to = try intParam(call, "to")
            await bridge.reorderPlaylist(playlistGID: gid, from: from, to: to)
            return .ok(call, descriptor, "已调整顺序")
        case "duplicatePlaylist":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            await bridge.duplicatePlaylist(playlistGID: gid)
            return .ok(call, descriptor, "已复制歌单")
        case "mergePlaylists":
            let gids = try await requirePlaylistIDs(call, "sourceIDs", catalog: catalog, serverID: serverID)
            let name = try require(call, "name")
            await bridge.mergePlaylists(sourceGIDs: gids, into: name)
            return .ok(call, descriptor, "已合并歌单")
        case "deletePlaylist":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            await bridge.deletePlaylist(globalID: gid)
            return .ok(call, descriptor, "已删除歌单")

        // MARK: Annotation
        case "likeTrack":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            await bridge.likeTrack(globalID: gid); return .ok(call, descriptor, "已收藏")
        case "unlikeTrack":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            await bridge.unlikeTrack(globalID: gid); return .ok(call, descriptor, "已取消收藏")
        case "favoriteAlbum":
            let gid = try await requireAlbumID(call, "albumID", catalog: catalog, serverID: serverID)
            await bridge.favoriteAlbum(globalID: gid); return .ok(call, descriptor, "已收藏专辑")
        case "unfavoriteAlbum":
            let gid = try await requireAlbumID(call, "albumID", catalog: catalog, serverID: serverID)
            await bridge.unfavoriteAlbum(globalID: gid); return .ok(call, descriptor, "已取消收藏专辑")
        case "favoriteArtist":
            let gid = try await requireArtistID(call, "artistID", catalog: catalog, serverID: serverID)
            await bridge.favoriteArtist(globalID: gid); return .ok(call, descriptor, "已收藏艺术家")
        case "unfavoriteArtist":
            let gid = try await requireArtistID(call, "artistID", catalog: catalog, serverID: serverID)
            await bridge.unfavoriteArtist(globalID: gid); return .ok(call, descriptor, "已取消收藏艺术家")
        case "setRating":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            let rating = try intParam(call, "rating")
            await bridge.setRating(globalID: gid, rating: min(max(rating, 1), 5))
            return .ok(call, descriptor, "已评分 \(rating)")
        case "clearRating":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            await bridge.clearRating(globalID: gid); return .ok(call, descriptor, "已清除评分")

        // MARK: Server
        case "listServers":
            let servers = await bridge.listServers()
            return .ok(call, descriptor, "服务器 \(servers.count) 个", .text(servers.map { $0.displayName }.joined(separator: "、")))
        case "getActiveServer":
            if let server = await bridge.getActiveServer() {
                return .ok(call, descriptor, server.displayName, .text(server.displayName))
            }
            return .ok(call, descriptor, "未连接服务器", .text("当前未连接服务器"))
        case "testServerConnection":
            let sid = try requireServerID(call, "serverID")
            let ok = await bridge.testServerConnection(serverID: sid)
            return .ok(call, descriptor, ok ? "连接成功" : "连接失败")
        case "addServer":
            let name = try require(call, "displayName")
            let url = try require(call, "baseURL")
            // token 不进入模型；实际凭据由原生表单采集。
            let ok = await bridge.addServer(displayName: name, baseURL: url, username: "", token: "")
            return .ok(call, descriptor, ok ? "已添加服务器" : "添加服务器失败")
        case "updateServer":
            let sid = try requireServerID(call, "serverID")
            let ok = await bridge.updateServer(serverID: sid, displayName: nil, baseURL: nil, username: nil, token: nil)
            return .ok(call, descriptor, ok ? "已更新服务器" : "更新失败")
        case "switchServer":
            let sid = try requireServerID(call, "serverID")
            await bridge.switchServer(serverID: sid)
            return .ok(call, descriptor, "已切换服务器")
        case "refreshLibrary":
            await bridge.refreshLibrary()
            return .ok(call, descriptor, "已触发刷新")
        case "getSyncStatus":
            let statuses = await bridge.getSyncStatus()
            return .ok(call, descriptor, "同步状态 \(statuses.count) 个", .text(statuses.map { "\($0.serverID.rawValue): \($0.isRunning ? "同步中" : "空闲")" }.joined(separator: "；")))
        case "removeServer":
            let sid = try requireServerID(call, "serverID")
            await bridge.removeServer(serverID: sid)
            return .ok(call, descriptor, "已删除服务器（仅本地清理）")

        // MARK: v2 统一命名工具（第一阶段）

        // 本地库查询
        case "library_get_summary":
            let tracks = try await catalog.allTrackSummaries(serverID: serverID)
            let artists = Set(tracks.map(\.artistName)).count
            let albums = Set(tracks.map(\.albumTitle)).count
            let favorites = try await catalog.getFavorites(serverID: serverID).count
            return .ok(call, descriptor, "\(tracks.count) 首歌曲、\(artists) 位艺术家、\(albums) 张专辑、\(favorites) 首收藏",
                       .text("\(tracks.count) 首歌曲 · \(artists) 位艺术家 · \(albums) 张专辑 · \(favorites) 首收藏"))
        case "library_search":
            let query = try require(call, "query")
            let limit = (try? intParam(call, "limit")) ?? 30
            let kind = (try? require(call, "kind"))?.lowercased() ?? "all"
            let onlyFavorites = (try? boolParam(call, "onlyFavorites")) ?? false
            let onlyOffline = (try? boolParam(call, "onlyOffline")) ?? false
            let safeLimit = min(max(limit, 1), 100)
            var tracks = try await catalog.searchTracks(query: query, serverID: serverID)
            if onlyFavorites { tracks = tracks.filter(\.isFavorite) }
            if onlyOffline { tracks = tracks.filter(\.isDownloaded) }
            if kind == "song" || kind == "all" {
                let list = Array(tracks.prefix(safeLimit))
                if !list.isEmpty {
                    return .ok(call, descriptor, "歌曲 \(list.count) 首", .trackCards(list.map(TrackCard.from)))
                }
            }
            if kind == "album" || kind == "all" {
                let albums = try await catalog.searchAlbums(query: query, serverID: serverID)
                if !albums.isEmpty {
                    return .ok(call, descriptor, "专辑 \(albums.count) 张", .albumCards(albums.prefix(safeLimit).map { AlbumCard(globalID: $0.globalID, title: $0.title, artistName: $0.artistName) }))
                }
            }
            if kind == "artist" || kind == "all" {
                let artists = try await catalog.searchArtists(query: query, serverID: serverID)
                if !artists.isEmpty {
                    return .ok(call, descriptor, "艺术家 \(artists.count) 位", .text(artists.prefix(safeLimit).map(\.name).joined(separator: "、")))
                }
            }
            if kind == "playlist" || kind == "all" {
                let playlists = try await catalog.listPlaylists(serverID: serverID)
                let hits = playlists.filter { $0.name.localizedCaseInsensitiveContains(query) }
                if !hits.isEmpty {
                    return .ok(call, descriptor, "歌单 \(hits.count) 个", .text(hits.prefix(safeLimit).map(\.name).joined(separator: "、")))
                }
            }
            return .fail(call, descriptor, "未找到匹配结果")
        case "library_select_tracks":
            // 集合查询：一次完成 筛选 + 排序 + 去重 + 限量，避免模型逐个歌手搜索凑数。
            let limit = min(max((try? intParam(call, "limit")) ?? 50, 1), 100)
            let languages = try listParam(call, "languages")
            let genres = try listParam(call, "genres")
            let artists = try listParam(call, "artists")
            let yearFrom = try? intParam(call, "yearFrom")
            let yearTo = try? intParam(call, "yearTo")
            let favoritesOnly = (try? boolParam(call, "favoritesOnly")) ?? false
            let excludeRecentlyPlayed = (try? boolParam(call, "excludeRecentlyPlayed")) ?? false
            let recentDays = (try? intParam(call, "recentDays")) ?? 7
            let excludeTrackIDs = try listParam(call, "excludeTrackIDs")
            let playableOnly = (try? boolParam(call, "playableOnly")) ?? true
            let sort = (try? require(call, "sort"))?.lowercased() ?? "popularityProxy"

            var tracks = try await catalog.allTracks(serverID: serverID, limit: 20000)
            if favoritesOnly { tracks = tracks.filter(\.isFavorite) }
            if !genres.isEmpty {
                tracks = tracks.filter { track in
                    track.genres.contains { genre in
                        genres.contains { $0.localizedCaseInsensitiveContains(genre) || genre.localizedCaseInsensitiveContains($0) }
                    }
                }
            }
            if !artists.isEmpty {
                tracks = tracks.filter { track in
                    artists.contains { $0.localizedCaseInsensitiveContains(track.artistName) || track.artistName.localizedCaseInsensitiveContains($0) }
                }
            }
            if let yearFrom { tracks = tracks.filter { ($0.year ?? 0) >= yearFrom } }
            if let yearTo { tracks = tracks.filter { ($0.year ?? 9999) <= yearTo } }
            if playableOnly { tracks = tracks.filter { $0.streamURL != nil } }
            if !excludeTrackIDs.isEmpty {
                let excluded = Set(excludeTrackIDs)
                tracks = tracks.filter {
                    !excluded.contains(GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue).description)
                }
            }

            // 语言过滤：语言字段缺失时（内嵌标签未写 language）不硬性排除，
            // 回退为“热度优先的候选”，让模型从真实候选中做语义选择，而不是逐个歌手搜索。
            var languageNote = ""
            if !languages.isEmpty {
                let filtered = tracks.filter { track in
                    guard let language = track.language, !language.isEmpty else { return false }
                    return languages.contains { Self.languageMatches($0, language) }
                }
                if !filtered.isEmpty {
                    // 有语言标签：严格按语言过滤（即使数量少也不混入其他语言）。
                    tracks = filtered
                } else {
                    // 完全没有语言标签：不硬性排除，按热度返回候选供模型语义判断。
                    languageNote = "（未检测到语言标签，已按热度返回候选，请按歌曲名/艺术家判断语言）"
                }
            }

            // 热度代理：播放次数 ×3 + 收藏 ×2 + 评分/2 + 最近播放权重。
            let popularity = (try? await catalog.popularityScores(serverID: serverID)) ?? [:]
            let favoriteIDs = Set((try? await catalog.getFavorites(serverID: serverID))?.map(\.globalID) ?? [])
            let recentIDs = (try? await catalog.getRecentHistory(serverID: serverID, limit: 500))?.map(\.globalID) ?? []
            let recentRank = Dictionary(uniqueKeysWithValues: recentIDs.enumerated().map { ($0.element, $0.offset) })
            let gidOf: (Track) -> GlobalID = { GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue) }

            if excludeRecentlyPlayed {
                let cutoff = Date().addingTimeInterval(-Double(max(recentDays, 1)) * 86400)
                tracks = tracks.filter { track in
                    guard let pop = popularity[gidOf(track)] else { return true }
                    return pop.lastPlayedAt.map { $0 < cutoff } ?? true
                }
            }

            func proxyScore(_ track: Track) -> Int {
                let gid = gidOf(track)
                let pop = popularity[gid]
                let recencyWeight = recentRank[gid].map { max(0, 20 - $0 / 20) } ?? 0
                return (pop?.playCount ?? 0) * 3
                    + (favoriteIDs.contains(gid) ? 2 : 0)
                    + (track.rating ?? 0) / 2
                    + recencyWeight
            }

            switch sort {
            case "favorites":
                tracks.sort { (favoriteIDs.contains(gidOf($0)) ? 1 : 0, $0.title) > (favoriteIDs.contains(gidOf($1)) ? 1 : 0, $1.title) }
            case "recentlyPlayed":
                tracks.sort { (recentRank[gidOf($0)] ?? Int.max) < (recentRank[gidOf($1)] ?? Int.max) }
            case "title":
                tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            case "recentlyAdded", "random":
                tracks.shuffle()
            default:
                tracks.sort { proxyScore($0) > proxyScore($1) }
            }

            let selected = Array(tracks.prefix(limit))
            guard !selected.isEmpty else {
                return .fail(call, descriptor, "没有符合条件（\([languages.isEmpty ? "" : "语言=" + languages.joined(separator: "/"), genres.isEmpty ? "" : "流派=" + genres.joined(separator: "/"), artists.isEmpty ? "" : "艺术家=" + artists.joined(separator: "/")].filter { !$0.isEmpty }.joined(separator: "，"))）的歌曲")
            }
            let cards = selected.map(TrackCard.from)
            let detail = selected.prefix(40).map { track -> String in
                let pop = popularity[gidOf(track)]
                var parts = ["《\(track.title)》-\(track.artistName)（\(gidOf(track).description)）"]
                if let year = track.year { parts.append("\(year)年") }
                if let language = track.language, !language.isEmpty { parts.append("\(language)") }
                parts.append("播放\(pop?.playCount ?? 0)次")
                if track.isFavorite { parts.append("收藏") }
                return parts.joined(separator: "·")
            }.joined(separator: "；")
            let summary = "候选 \(selected.count) 首（\(sort == "popularityProxy" ? "按本地热度代理排序" : sort)）\(languageNote)；\(detail)"
            return .ok(call, descriptor, summary, .trackCards(cards))

        case "library_get_song":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            guard let track = try await catalog.getTrack(gid) else { return .fail(call, descriptor, "单曲不存在") }
            let downloaded = (try? await catalog.getDownloadedTracks(serverID: serverID).contains { $0.globalID == gid }) ?? false
            return .ok(call, descriptor, track.title, .text(Self.songDetailLine(track, downloaded: downloaded)))
        case "library_get_album":
            let gid = try await requireAlbumID(call, "albumID", catalog: catalog, serverID: serverID)
            guard let album = try await catalog.getAlbum(gid) else { return .fail(call, descriptor, "专辑不存在") }
            let tracks = try await catalog.tracksForAlbum(gid)
            return .ok(call, descriptor, album.title, .text("\(album.title) · \(album.artistName) · \(tracks.count) 首"))
        case "library_get_artist":
            let gid = try await requireArtistID(call, "artistID", catalog: catalog, serverID: serverID)
            guard let artist = try await catalog.getArtist(gid) else { return .fail(call, descriptor, "艺术家不存在") }
            let tracks = try await catalog.tracksForArtist(gid)
            return .ok(call, descriptor, artist.name, .text("\(artist.name) · \(tracks.count) 首歌曲"))
        case "library_get_playlist":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            guard let (playlist, tracks) = try await catalog.getPlaylist(gid) else { return .fail(call, descriptor, "歌单不存在") }
            return .ok(call, descriptor, playlist.name, .playlistProposal(name: playlist.name, tracks: tracks.prefix(50).map { TrackCard.from(CatalogTrackSummary(globalID: GlobalID(serverID: gid.serverID, remoteID: $0.id.rawValue), title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle, duration: $0.duration, isFavorite: $0.isFavorite, userRating: 0, isDownloaded: false)) }))
        case "library_get_recently_played":
            let limit = (try? intParam(call, "limit")) ?? 20
            let list = try await catalog.getRecentHistory(serverID: serverID, limit: min(max(limit, 1), 100))
            return .ok(call, descriptor, "最近播放 \(list.count) 首", .trackCards(list.map(TrackCard.from)))
        case "library_get_starred":
            let list = try await catalog.getFavorites(serverID: serverID)
            return .ok(call, descriptor, "收藏 \(list.count) 首", .trackCards(list.map(TrackCard.from)))
        case "library_get_random_songs":
            let limit = (try? intParam(call, "limit")) ?? 10
            let all = try await catalog.allTrackSummaries(serverID: serverID)
            let sample = Array(all.shuffled().prefix(min(max(limit, 1), 50)))
            return .ok(call, descriptor, "随机 \(sample.count) 首", .trackCards(sample.map(TrackCard.from)))
        case "library_get_similar_songs":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            let list = try await catalog.getSimilarTracks(gid)
            return .ok(call, descriptor, "相似 \(list.count) 首", .trackCards(list.map(TrackCard.from)))
        case "library_get_genres":
            // 流派来自服务器返回的曲目标签（Navidrome 的 getGenres/曲目 genre 字段），
            // 本地按曲目聚合统计；显示名用中文翻译（GenreLocalization）。
            let limit = min(max((try? intParam(call, "limit")) ?? 30, 1), 100)
            let tracks = try await catalog.allTracks(serverID: serverID, limit: 20000)
            var counts: [String: Int] = [:]
            for track in tracks {
                for genre in track.genres {
                    let key = genre.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { continue }
                    counts[key, default: 0] += 1
                }
            }
            let sorted = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            guard !sorted.isEmpty else {
                return .fail(call, descriptor, "资料库暂无流派（服务器可能未在音乐文件内写入内嵌流派标签，需在 Navidrome 重新扫描）")
            }
            let text = "共 \(sorted.count) 个流派（歌曲数降序）：" + sorted.prefix(limit)
                .map { "\(GenreLocalization.displayName(for: $0.key)) \($0.value) 首" }
                .joined(separator: "、")
            return .ok(call, descriptor, "\(sorted.count) 个流派", .text(text))
        case "library_get_tracks_by_genre":
            let genre = try require(call, "genre").trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = min(max((try? intParam(call, "limit")) ?? 20, 1), 50)
            let tracks = try await catalog.allTracks(serverID: serverID, limit: 20000)
            let hits = tracks.filter { track in
                track.genres.contains { $0.localizedCaseInsensitiveCompare(genre) == .orderedSame }
            }
            guard !hits.isEmpty else {
                return .fail(call, descriptor, "没有找到属于「\(GenreLocalization.displayName(for: genre))」的歌曲")
            }
            let cards = hits.prefix(limit).map(TrackCard.from)
            return .ok(call, descriptor, "「\(GenreLocalization.displayName(for: genre))」\(hits.count) 首", .trackCards(cards))
        case "library_get_catalog_index":
            // 曲库分类索引：让模型快速了解曲库构成（歌手/专辑/流派/语言/年代），只含元数据。
            let category = (try? require(call, "category"))?.lowercased() ?? "overview"
            let index = try await catalog.makeCatalogIndex(serverID: serverID)
            let text: String
            switch category {
            case "artists":
                text = "曲库共 \(index.artistCount) 位艺术家（按歌曲数降序）：" + index.artists.prefix(200)
                    .map { "\($0.name)（\($0.songCount) 首/\($0.albumCount) 张）" }.joined(separator: "、")
            case "albums":
                text = "曲库共 \(index.albumCount) 张专辑：" + index.albums.prefix(200)
                    .map { "《\($0.title)》-\($0.artist)\($0.year.map { "（\($0)）" } ?? "")（\($0.songCount) 首）" }.joined(separator: "、")
            case "genres":
                text = "曲库共 \(index.genres.count) 个流派（歌曲数降序）：" + index.genres.prefix(200)
                    .map { "\(GenreLocalization.displayName(for: $0.name))（\($0.songCount) 首）" }.joined(separator: "、")
            case "languages":
                text = "曲库语言分布：" + (index.languages.isEmpty ? "未写入语言标签" : index.languages.prefix(100)
                    .map { "\($0.language)（\($0.songCount) 首）" }.joined(separator: "、"))
            case "years":
                text = "曲库年代分布：" + (index.years.isEmpty ? "无年份信息" : index.years.prefix(100)
                    .map { "\($0.year) 年（\($0.songCount) 首）" }.joined(separator: "、"))
            default:
                text = "曲库共 \(index.songCount) 首歌曲、\(index.artistCount) 位艺术家、\(index.albumCount) 张专辑、\(index.genres.count) 个流派、\(index.languages.count) 种语言。可调用 library_get_catalog_index(category=artists/albums/genres/languages/years) 查看明细。"
            }
            return .ok(call, descriptor, text.prefix(2000).description, .text(text))
        case "library_get_catalog_tracks":
            // 按分类取歌曲清单（artist/album/genre/language/year/favorites/recent/popular/all），
            // 只含元数据（无歌词/海报），供模型按需注入对话后做推荐。
            let category = (try? require(call, "category"))?.lowercased() ?? "all"
            let value = call.arguments["value"]
            let limit = (try? intParam(call, "limit")) ?? 100
            let lines = try await catalog.catalogTracks(
                serverID: serverID, category: category, value: value, limit: limit
            )
            guard !lines.isEmpty else {
                return .fail(call, descriptor, "该分类下没有歌曲（category=\(category)\(value.map { ", value=\($0)" } ?? "")）")
            }
            func lineText(_ t: CatalogTrackLine) -> String {
                var parts = ["\(t.id)｜《\(t.title)》-\(t.artist)-\(t.album)"]
                if let year = t.year { parts.append("\(year)年") }
                if let language = t.language, !language.isEmpty { parts.append(language) }
                if !t.genres.isEmpty { parts.append(t.genres.prefix(2).map(GenreLocalization.displayName(for:)).joined(separator: "/")) }
                parts.append("\(t.duration)秒")
                if t.playCount > 0 { parts.append("播放\(t.playCount)次") }
                if t.isFavorite { parts.append("收藏") }
                if let rating = t.rating { parts.append("评分\(rating)") }
                return parts.joined(separator: "·")
            }
            let text = "「\(category)」\(lines.count) 首：" + lines.map(lineText).joined(separator: "；")
            return .ok(call, descriptor, "「\(category)」\(lines.count) 首", .text(text))

        case "library_find_duplicates":
            let limit = min(max((try? intParam(call, "limit")) ?? 10, 1), 50)
            let all = try await catalog.allTrackSummaries(serverID: serverID)
            var groups: [String: [CatalogTrackSummary]] = [:]
            for summary in all {
                let key = "\(summary.artistName.localizedLowercase)|\(summary.title.localizedLowercase)"
                groups[key, default: []].append(summary)
            }
            let duplicates = groups.values.filter { $0.count > 1 }.prefix(limit)
            let text = duplicates.isEmpty
                ? "未发现疑似重复歌曲"
                : "疑似重复 \(duplicates.count) 组：" + duplicates.map { "《\($0[0].title)》×\($0.count)" }.joined(separator: "、")
            return .ok(call, descriptor, text, .text(text))
        case "library_find_metadata_issues":
            let limit = min(max((try? intParam(call, "limit")) ?? 10, 1), 50)
            let tracks = try await catalog.allTracks(serverID: serverID)
            var issues: [String] = []
            for track in tracks {
                if track.artistName.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("缺少艺术家：《\(track.title)》") }
                if track.albumTitle.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("缺少专辑：《\(track.title)》") }
                if track.year == nil { issues.append("缺少年份：《\(track.title)》") }
                if track.genres.isEmpty { issues.append("缺少流派：《\(track.title)》") }
                if track.artworkKey == nil { issues.append("缺少封面：《\(track.title)》") }
                if track.duration <= 0 || track.duration > 7200 { issues.append("异常时长：《\(track.title)》") }
            }
            // 同一艺术家存在多个名称写法（按归一化名称分组，同组多种写法即报告）。
            var artistWritings: [String: Set<String>] = [:]
            for track in tracks {
                let normalized = Self.normalizedArtistName(track.artistName)
                guard !normalized.isEmpty else { continue }
                artistWritings[normalized, default: []].insert(track.artistName)
            }
            let multiWritings = artistWritings.filter { $0.value.count > 1 }
            for (_, writings) in multiWritings.prefix(limit) {
                issues.append("艺术家写法不一致：" + writings.sorted().joined(separator: " / "))
            }
            let text = issues.isEmpty
                ? "未发现元数据问题"
                : "发现 \(issues.count) 个问题：" + issues.prefix(limit).joined(separator: "；")
            return .ok(call, descriptor, text, .text(text))
        case "library_find_unplayable":
            let limit = min(max((try? intParam(call, "limit")) ?? 10, 1), 50)
            let tracks = try await catalog.allTracks(serverID: serverID)
            let downloaded = Set(try await catalog.getDownloadedTracks(serverID: serverID).map(\.globalID))
            let bad = tracks.filter {
                $0.streamURL == nil
                    && !downloaded.contains(GlobalID(serverID: $0.serverID, remoteID: $0.id.rawValue))
            }.prefix(limit)
            let text = bad.isEmpty
                ? "未发现无法播放的歌曲"
                : "无播放地址且未离线：" + bad.map { "《\($0.title)》" }.joined(separator: "、")
            return .ok(call, descriptor, text, .text(text))
        case "smart_queue_generate":
            // 只返回队列预览，不替换当前队列；用户确认后由 queue_replace（需确认）应用。
            let limit = min(max((try? intParam(call, "limit")) ?? 20, 1), 100)
            let all = try await catalog.allTrackSummaries(serverID: serverID)
            let recent = Set(try await catalog.getRecentHistory(serverID: serverID, limit: 50).map(\.globalID))
            let picks = all.filter { !recent.contains($0.globalID) }.shuffled().prefix(limit)
            let text = "智能队列预览 \(picks.count) 首（确认后再替换队列）"
            return .ok(call, descriptor, text, .trackCards(picks.map(TrackCard.from)))

        // 播放
        case "playback_get_state":
            if let track = await bridge.currentTrack() {
                let queue = await bridge.currentQueue()
                return .ok(call, descriptor, "\(track.title) · 队列 \(queue.count) 首", .text("\(track.title) · \(track.artistName) · 队列 \(queue.count) 首"))
            }
            return .ok(call, descriptor, "当前无播放", .text("当前没有正在播放的歌曲"))
        case "playback_play_song":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            guard await bridge.playTrack(globalID: gid) else {
                return .fail(call, descriptor, "未找到该歌曲，可能尚未同步到本地目录（可先 server_sync_start 同步，或改用 server_search 在线查找）")
            }
            return .ok(call, descriptor, "开始播放")
        case "playback_play_album":
            let gid = try await requireAlbumID(call, "albumID", catalog: catalog, serverID: serverID)
            guard await bridge.playAlbum(globalID: gid) else {
                return .fail(call, descriptor, "未找到该专辑中的可播放歌曲")
            }
            return .ok(call, descriptor, "开始播放专辑")
        case "playback_play_artist":
            let gid = try await requireArtistID(call, "artistID", catalog: catalog, serverID: serverID)
            let summaries = try await catalog.tracksForArtist(gid)
            let gids = summaries.map(\.globalID)
            guard !gids.isEmpty else { return .fail(call, descriptor, "该艺术家没有可播放的歌曲") }
            await bridge.replaceQueue(globalIDs: gids)
            return .ok(call, descriptor, "开始播放 \(gids.count) 首")
        case "playback_play_random":
            _ = (try? intParam(call, "limit")) ?? 30
            await bridge.playRandom(); return .ok(call, descriptor, "已开始随机播放")
        case "playback_play_playlist":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            guard await bridge.playPlaylist(globalID: gid) else {
                return .fail(call, descriptor, "未找到该歌单中的可播放歌曲")
            }
            return .ok(call, descriptor, "开始播放歌单")
        case "playback_pause":
            await bridge.pause(); return .ok(call, descriptor, "已暂停")
        case "playback_resume":
            await bridge.resume(); return .ok(call, descriptor, "已继续")
        case "playback_next":
            await bridge.next(); return .ok(call, descriptor, "下一首")
        case "playback_previous":
            await bridge.previous(); return .ok(call, descriptor, "上一首")
        case "playback_seek":
            let seconds = try doubleParam(call, "seconds")
            await bridge.seek(seconds: seconds)
            return .ok(call, descriptor, "已定位到 \(Int(seconds)) 秒")
        case "playback_set_speed":
            let rate = Float(try doubleParam(call, "rate"))
            await bridge.setPlaybackRate(rate)
            return .ok(call, descriptor, "播放速度已设为 \(rate)x")
        case "playback_set_sleep_timer":
            let mode = try require(call, "mode")
            let minutes = (try? doubleParam(call, "minutes")) ?? 30
            await bridge.setSleepTimer(mode: mode, minutes: minutes)
            return .ok(call, descriptor, "已设置睡眠定时：\(mode)")
        case "playback_cancel_sleep_timer":
            await bridge.cancelSleepTimer(); return .ok(call, descriptor, "已取消睡眠定时")
        case "playback_get_sleep_timer":
            let (mode, remaining) = await bridge.getSleepTimer()
            let text = "睡眠定时：\(mode) · 剩余 \(Int(remaining)) 秒"
            return .ok(call, descriptor, text, .text(text))
        case "playback_set_shuffle":
            let enabled = try boolParam(call, "enabled")
            await bridge.setShuffle(enabled)
            return .ok(call, descriptor, enabled ? "已开启随机播放" : "已关闭随机播放")
        case "playback_set_repeat":
            let modeRaw = try require(call, "mode").lowercased()
            let mode: RepeatMode
            switch modeRaw {
            case "off": mode = .off
            case "all", "queue", "list": mode = .all
            case "one", "single": mode = .one
            default: throw AgentToolError.invalidParameter("mode", modeRaw)
            }
            await bridge.setRepeatMode(mode)
            return .ok(call, descriptor, "循环模式：\(mode.title)")

        // 队列
        case "queue_get":
            let queue = await bridge.currentQueue()
            return .ok(call, descriptor, "队列 \(queue.count) 首", .text(queue.prefix(30).map(\.title).joined(separator: "、")))
        case "queue_append":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            await bridge.addToQueue(globalID: gid); return .ok(call, descriptor, "已加入队列")
        case "queue_play_next":
            let gid = try await requireTrackID(call, "trackID", catalog: catalog, serverID: serverID)
            await bridge.playNext(globalID: gid); return .ok(call, descriptor, "已插入到当前歌曲之后")
        case "queue_replace":
            let gids = try await requireTrackIDs(call, "trackIDs", catalog: catalog, serverID: serverID)
            await bridge.replaceQueue(globalIDs: gids); return .ok(call, descriptor, "已替换队列（\(gids.count) 首）")
        case "queue_clear":
            await bridge.clearQueue(); return .ok(call, descriptor, "已清空队列")
        case "queue_move":
            let from = try intParam(call, "from")
            let to = try intParam(call, "to")
            await bridge.reorderQueue(from: from, to: to)
            return .ok(call, descriptor, "已调整队列顺序")
        case "queue_shuffle_remaining":
            await bridge.shuffleRemaining(); return .ok(call, descriptor, "已随机剩余队列")
        case "queue_save_as_playlist":
            let name = try require(call, "name")
            let ok = await bridge.saveQueueAsPlaylist(name: name)
            return ok ? .ok(call, descriptor, "已保存为歌单：\(name)") : .fail(call, descriptor, "保存歌单失败")

        // 收藏 / 歌单
        case "favorite_set":
            let type = try require(call, "targetType").lowercased()
            let value = try boolParam(call, "value")
            switch type {
            case "song":
                let gid = try await requireTrackID(call, "targetID", catalog: catalog, serverID: serverID)
                if value { await bridge.likeTrack(globalID: gid) } else { await bridge.unlikeTrack(globalID: gid) }
            case "album":
                let gid = try await requireAlbumID(call, "targetID", catalog: catalog, serverID: serverID)
                if value { await bridge.favoriteAlbum(globalID: gid) } else { await bridge.unfavoriteAlbum(globalID: gid) }
            case "artist":
                let gid = try await requireArtistID(call, "targetID", catalog: catalog, serverID: serverID)
                if value { await bridge.favoriteArtist(globalID: gid) } else { await bridge.unfavoriteArtist(globalID: gid) }
            default: throw AgentToolError.invalidParameter("targetType", type)
            }
            return .ok(call, descriptor, value ? "已收藏" : "已取消收藏")
        case "playlist_create":
            let name = try require(call, "name")
            guard let gid = await bridge.createPlaylist(name: name) else { return .fail(call, descriptor, "创建歌单失败") }
            return .ok(call, descriptor, "已创建歌单", .text("\(name) · \(gid.description)"))
        case "playlist_add_songs":
            let gid = try await requirePlaylistID(call, "playlistID", catalog: catalog, serverID: serverID)
            try await requireReadOnlyPlaylist(gid, catalog: catalog)
            let gids = try await requireTrackIDs(call, "trackIDs", catalog: catalog, serverID: serverID)
            await bridge.addTracksToPlaylist(playlistGID: gid, trackGIDs: gids)
            return .ok(call, descriptor, "已添加 \(gids.count) 首")

        // MARK: v2 服务器工具

        case "server_list":
            let servers = await bridge.listServers()
            let lines = servers.map { "\($0.displayName)（ID \($0.id.rawValue)）" }
            return .ok(call, descriptor, "服务器 \(servers.count) 个", .text(lines.isEmpty ? "尚未配置服务器" : lines.joined(separator: "、")))
        case "server_get_current":
            if let server = await bridge.getActiveServer() {
                return .ok(call, descriptor, server.displayName, .text("当前服务器：\(server.displayName)（ID \(server.id.rawValue)）"))
            }
            return .ok(call, descriptor, "未连接服务器", .text("当前未连接服务器"))
        case "server_test_connection":
            let sid = try requireServerID(call, "serverID")
            let ok = await bridge.testServerConnection(serverID: sid)
            return .ok(call, descriptor, ok ? "连接成功" : "连接失败",
                       .text(ok ? "服务器 \(sid.rawValue) 可达" : "服务器 \(sid.rawValue) 无响应或凭据失效，请检查网络与登录状态"))
        case "server_get_capabilities":
            if let server = await bridge.getActiveServer() {
                return .ok(call, descriptor, "当前服务器：\(server.displayName)", .text("当前服务器：\(server.displayName)（ID \(server.id.rawValue)）。能力以实际连接检测结果为准，可执行 server_test_connection 验证连通性。"))
            }
            return .ok(call, descriptor, "未连接服务器", .text("当前未连接服务器，无法检测能力"))
        case "server_sync_status":
            let statuses = await bridge.getSyncStatus()
            if statuses.isEmpty {
                return .ok(call, descriptor, "无同步记录", .text("还没有同步记录，可先连接服务器再同步音乐库。"))
            }
            let lines = statuses.map { status in
                var line = "\(status.serverID.rawValue): \(status.isRunning ? "同步中" : "空闲")"
                if let at = status.lastCompletedAt {
                    line += " · 上次完成 \(at.formatted(date: .abbreviated, time: .shortened))"
                }
                return line
            }
            return .ok(call, descriptor, "同步状态 \(statuses.count) 个", .text(lines.joined(separator: "；")))
        case "server_sync_start":
            // 触发增量同步（同步音乐库），属于修改型操作。
            await bridge.refreshLibrary()
            return .ok(call, descriptor, "已触发音乐库同步", .text("已开始后台同步，可稍后用 server_sync_status 查询进度。"))
        case "server_search":
            // 服务器在线搜索（HTTP）：本地目录没有时，实时向服务器查询歌曲信息。
            let query = try require(call, "query")
            let limit = (try? intParam(call, "limit")) ?? 20
            let tracks = await bridge.serverSearch(query: query, limit: min(max(limit, 1), 50))
            guard !tracks.isEmpty else {
                return .fail(call, descriptor, "服务器上未找到匹配的歌曲：\(query)")
            }
            let cards = tracks.prefix(30).map { track in
                TrackCard(
                    globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue),
                    title: track.title,
                    artistName: track.artistName,
                    albumTitle: track.albumTitle,
                    duration: track.duration,
                    isFavorite: track.isFavorite
                )
            }
            return .ok(call, descriptor, "服务器找到 \(tracks.count) 首", .trackCards(cards))

        default:
            return .fail(call, descriptor, "未实现的工具")
        }
    }

    // MARK: - Param helpers

    /// GlobalID 必须属于当前活跃服务器：切换服务器后旧会话中的 ID 一律视为无效，
    /// 防止用上一台服务器的 ID 操作当前服务器（这是播放/收藏/歌单 400 与串库的根因之一）。
    private static func serverIDMatches(_ gid: GlobalID, _ serverID: ServerID?) -> Bool {
        guard let serverID else { return true }
        return gid.serverID == serverID
    }

    private static func require(_ call: ToolCall, _ key: String) throws -> String {
        guard let value = call.arguments[key], !value.isEmpty else {
            throw AgentToolError.missingParameter(key)
        }
        return value
    }

    private static func listParam(_ call: ToolCall, _ key: String) throws -> [String] {
        guard let raw = call.arguments[key], !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 语言匹配：支持「中文」「zh」「cmn」「Chinese」等常见写法，子串包含即可。
    private static func languageMatches(_ want: String, _ actual: String) -> Bool {
        let a = want.trimmingCharacters(in: .whitespaces).lowercased()
        let b = actual.trimmingCharacters(in: .whitespaces).lowercased()
        if a == b { return true }
        if a.contains(b) || b.contains(a) { return true }
        let aliases: [String: Set<String>] = [
            "中文": ["zh", "cmn", "chinese", "mandarin", "zh-cn", "zh-hans", "zh-hant"],
            "粤语": ["yue", "cantonese"],
            "英语": ["en", "english"],
            "日语": ["ja", "japanese"],
            "韩语": ["ko", "korean"],
        ]
        for (name, set) in aliases where a.contains(name) || name.contains(a) {
            if set.contains(b) || b.contains(name) || name.contains(b) { return true }
        }
        return false
    }

    private static func intParam(_ call: ToolCall, _ key: String) throws -> Int {
        let raw = try require(call, key)
        guard let value = Int(raw) else { throw AgentToolError.invalidParameter(key, raw) }
        return value
    }

    private static func intsParam(_ call: ToolCall, _ key: String) throws -> [Int] {
        let raw = try require(call, key)
        return try raw.split(separator: ",").map { piece in
            guard let value = Int(piece.trimmingCharacters(in: .whitespaces)) else {
                throw AgentToolError.invalidParameter(key, String(piece))
            }
            return value
        }
    }

    private static func boolParam(_ call: ToolCall, _ key: String) throws -> Bool {
        guard let raw = call.arguments[key]?.lowercased() else {
            throw AgentToolError.missingParameter(key)
        }
        switch raw {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw AgentToolError.invalidParameter(key, raw)
        }
    }

    private static func doubleParam(_ call: ToolCall, _ key: String) throws -> Double {
        let raw = try require(call, key)
        guard let value = Double(raw) else { throw AgentToolError.invalidParameter(key, raw) }
        return value
    }

    private static func requireTrackID(_ call: ToolCall, _ key: String, catalog: LocalCatalogStore, serverID: ServerID?) async throws -> GlobalID {
        let raw = try require(call, key)
        guard let gid = GlobalID(raw),
              serverIDMatches(gid, serverID),
              let _ = try await catalog.getTrack(gid)
        else {
            throw AgentToolError.invalidTrackID(raw)
        }
        return gid
    }

    private static func requireAlbumID(_ call: ToolCall, _ key: String, catalog: LocalCatalogStore, serverID: ServerID?) async throws -> GlobalID {
        let raw = try require(call, key)
        guard let gid = GlobalID(raw),
              serverIDMatches(gid, serverID),
              let _ = try await catalog.getAlbum(gid)
        else {
            throw AgentToolError.invalidEntityID(key, raw)
        }
        return gid
    }

    private static func requireArtistID(_ call: ToolCall, _ key: String, catalog: LocalCatalogStore, serverID: ServerID?) async throws -> GlobalID {
        let raw = try require(call, key)
        guard let gid = GlobalID(raw),
              serverIDMatches(gid, serverID),
              let _ = try await catalog.getArtist(gid)
        else {
            throw AgentToolError.invalidEntityID(key, raw)
        }
        return gid
    }

    private static func requirePlaylistID(_ call: ToolCall, _ key: String, catalog: LocalCatalogStore, serverID: ServerID?) async throws -> GlobalID {
        let raw = try require(call, key)
        guard let gid = GlobalID(raw),
              serverIDMatches(gid, serverID),
              try await catalog.listPlaylists().contains(where: { $0.globalID == gid }) else {
            throw AgentToolError.invalidEntityID(key, raw)
        }
        return gid
    }

    private static func requireTrackIDs(_ call: ToolCall, _ key: String, catalog: LocalCatalogStore, serverID: ServerID?) async throws -> [GlobalID] {
        let raw = try require(call, key)
        var result: [GlobalID] = []
        for piece in raw.split(separator: ",") {
            let trimmed = String(piece).trimmingCharacters(in: .whitespaces)
            guard let gid = GlobalID(trimmed),
                  serverIDMatches(gid, serverID),
                  try await catalog.getTrack(gid) != nil
            else {
                throw AgentToolError.invalidTrackID(trimmed)
            }
            result.append(gid)
        }
        return result
    }

    private static func requirePlaylistIDs(_ call: ToolCall, _ key: String, catalog: LocalCatalogStore, serverID: ServerID?) async throws -> [GlobalID] {
        let raw = try require(call, key)
        let playlists = try await catalog.listPlaylists()
        return try raw.split(separator: ",").map { piece -> GlobalID in
            let trimmed = String(piece).trimmingCharacters(in: .whitespaces)
            guard let gid = GlobalID(trimmed), playlists.contains(where: { $0.globalID == gid }) else {
                throw AgentToolError.invalidEntityID(key, trimmed)
            }
            return gid
        }
    }

    private static func requireServerID(_ call: ToolCall, _ key: String) throws -> ServerID {
        let raw = try require(call, key)
        return ServerID(rawValue: raw)
    }

    /// 单曲详情摘要：名称/艺术家/专辑/时长/年份/格式/码率/收藏/评分/离线状态。
    /// 艺术家名称归一化（大小写/全半角/空白折叠），用于检测同一艺术家的多种写法。
    private static func normalizedArtistName(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined()
    }

    private static func songDetailLine(_ track: Track, downloaded: Bool) -> String {
        var parts: [String] = ["\(track.title) · \(track.artistName) · \(track.albumTitle)"]
        if track.duration > 0 { parts.append("\(Int(track.duration)) 秒") }
        if let year = track.year { parts.append("\(year) 年") }
        if let codec = track.sourceInfo.codec, !codec.isEmpty { parts.append("格式 \(codec)") }
        if let bitRate = track.sourceInfo.bitRate, bitRate > 0 { parts.append("\(bitRate) kbps") }
        parts.append(track.isFavorite ? "已收藏" : "未收藏")
        if let rating = track.rating { parts.append("评分 \(rating)") }
        parts.append(downloaded ? "已离线" : "未离线")
        return parts.joined(separator: " · ")
    }

    private static func requireReadOnlyPlaylist(_ gid: GlobalID, catalog: LocalCatalogStore) async throws {
        let playlists = try await catalog.listPlaylists()
        guard let playlist = playlists.first(where: { $0.globalID == gid }) else {
            throw AgentToolError.invalidEntityID("playlistID", gid.description)
        }
        guard !playlist.isReadOnly else {
            throw AgentToolError.readOnlyPlaylist(gid.description)
        }
    }
}

public enum AgentToolError: Error, LocalizedError, Sendable {
    case missingParameter(String)
    case invalidParameter(String, String)
    case invalidTrackID(String)
    case invalidEntityID(String, String)
    case readOnlyPlaylist(String)

    public var errorDescription: String? {
        switch self {
        case let .missingParameter(key): "缺少参数：\(key)"
        case let .invalidParameter(key, value): "参数 \(key) 非法：\(value)"
        case let .invalidTrackID(value): "Track ID 不真实或不存在：\(value)"
        case let .invalidEntityID(key, value): "\(key) 不真实或不存在：\(value)"
        case let .readOnlyPlaylist(value): "只读歌单禁止修改：\(value)"
        }
    }
}

extension ToolResult {
    static func ok(_ call: ToolCall, _ descriptor: ToolDescriptor, _ summary: String, _ payload: AgentMessage? = nil) -> ToolResult {
        ToolResult(call: call, permission: descriptor.permission, success: true, summary: summary, payload: payload)
    }

    static func fail(_ call: ToolCall, _ descriptor: ToolDescriptor, _ summary: String) -> ToolResult {
        ToolResult(call: call, permission: descriptor.permission, success: false, summary: summary)
    }
}
