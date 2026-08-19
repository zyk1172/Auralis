import Domain
import Foundation
import MusicLibrary
import OpenSubsonicKit

/// 将已认证的 OpenSubsonic 客户端适配为 `LibrarySyncSource`。
/// 专辑/曲目以游标分页拉取，艺人一次性拉取，接入 `LibrarySynchronizer` 完成全量/增量同步。
public actor OpenSubsonicSyncSource: LibrarySyncSource {
    private let client: OpenSubsonicClient
    private var albumCache: [Album]?
    private let tracksBatchSize = 15
    /// 专辑详情抓取的有界并发上限：与 OpenSubsonicLibrarySyncSource 保持一致，
    /// 避免逐张专辑串行拉取把几千张专辑变成几千次串行 HTTP 请求。
    private let maximumConcurrentAlbumRequests = 6

    public init(client: OpenSubsonicClient) {
        self.client = client
    }

    public func artistsPage(serverID _: ServerID, request _: LibraryPageRequest) async throws -> LibraryPage<Artist> {
        let items = try await client.artists()
        return LibraryPage(items: items)
    }

    public func albumsPage(serverID _: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Album> {
        let offset = Int(request.continuation ?? "0") ?? 0
        let items = try await client.albums(type: .alphabeticalByName, size: request.pageSize, offset: offset)
        let next = items.count == request.pageSize ? String(offset + request.pageSize) : nil
        return LibraryPage(items: items, nextContinuation: next)
    }

    public func tracksPage(serverID _: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Track> {
        if albumCache == nil {
            albumCache = try await loadAllAlbums()
        }
        guard let albums = albumCache else { return LibraryPage(items: []) }
        let offset = Int(request.continuation ?? "0") ?? 0
        let upper = min(offset + tracksBatchSize, albums.count)
        guard offset < upper else {
            return LibraryPage(items: [], nextContinuation: nil)
        }
        var tracks: [Track] = []
        let batch = Array(albums[offset..<upper])
        var start = 0
        // 单张专辑抓取失败向上抛出，由 LibrarySynchronizer 按重试策略重试，
        // 而不是静默跳过导致曲目缺失（原实现 try? 吞错）。
        // 有界并发：每批最多 maximumConcurrentAlbumRequests 张专辑并行抓取，
        // 批与批之间串行推进，避免打爆 NAS 也不退化成逐张串行。
        while start < batch.count {
            try Task.checkCancellation()
            let end = min(batch.count, start + maximumConcurrentAlbumRequests)
            let slice = Array(batch[start..<end])
            let details = try await withThrowingTaskGroup(
                of: OpenSubsonicAlbumDetail.self,
                returning: [OpenSubsonicAlbumDetail].self
            ) { group in
                for album in slice {
                    group.addTask { [client] in
                        try Task.checkCancellation()
                        return try await client.album(id: album.id.rawValue)
                    }
                }
                var values: [OpenSubsonicAlbumDetail] = []
                for try await value in group { values.append(value) }
                return values
            }
            for detail in details { tracks.append(contentsOf: detail.tracks) }
            start = end
        }
        let next = upper < albums.count ? String(upper) : nil
        return LibraryPage(items: tracks, nextContinuation: next)
    }

    /// 全量拉取所有专辑（分页直到返回不足一页），移除此前「只取前 500 张」导致的曲目缺失。
    private func loadAllAlbums() async throws -> [Album] {
        var all: [Album] = []
        var offset = 0
        let pageSize = 500
        while true {
            try Task.checkCancellation()
            let page = try await client.albums(type: .alphabeticalByName, size: pageSize, offset: offset)
            all.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }
        return all
    }
}