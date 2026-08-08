import Domain
import Foundation
import MusicLibrary
import OpenSubsonicKit

public protocol OpenSubsonicCatalogLoading: Sendable {
    var serverID: ServerID { get }
    func musicFolders() async throws -> [OpenSubsonicMusicFolder]
    func artists(musicFolderID: String?) async throws -> [Artist]
    func albums(
        type: OpenSubsonicAlbumListType,
        size: Int,
        offset: Int,
        musicFolderID: String?
    ) async throws -> [Album]
    func album(id: AlbumID) async throws -> OpenSubsonicAlbumDetail
}

extension OpenSubsonicClient: OpenSubsonicCatalogLoading {
    public var serverID: ServerID { configuration.serverID }

    public func albums(
        type: OpenSubsonicAlbumListType,
        size: Int,
        offset: Int,
        musicFolderID: String?
    ) async throws -> [Album] {
        try await albums(
            type: type,
            size: size,
            offset: offset,
            fromYear: nil,
            toYear: nil,
            genre: nil,
            musicFolderID: musicFolderID
        )
    }
}

public enum OpenSubsonicLibrarySourceError: Error, Equatable, Sendable {
    case serverMismatch(expected: ServerID, actual: ServerID)
    case invalidContinuation
    case invalidPageSize(Int)
}

/// Converts the offset-oriented OpenSubsonic API into opaque, cancellable
/// `LibrarySyncSource` pages. Track pages fetch album details with bounded
/// concurrency and are not retained after the page has been delivered.
public actor OpenSubsonicLibrarySyncSource: LibrarySyncSource {
    private enum Section: String, Sendable {
        case artists
        case albums
        case tracks
    }

    private struct Cursor: Sendable {
        let section: Section
        let folderIndex: Int
        let offset: Int

        var encoded: String { "v1|\(section.rawValue)|\(folderIndex)|\(offset)" }

        init(section: Section, folderIndex: Int = 0, offset: Int = 0) {
            self.section = section
            self.folderIndex = folderIndex
            self.offset = offset
        }

        init(encoded: String, expected: Section) throws {
            let parts = encoded.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 4,
                  parts[0] == "v1",
                  parts[1] == expected.rawValue,
                  let folderIndex = Int(parts[2]), folderIndex >= 0,
                  let offset = Int(parts[3]), offset >= 0
            else {
                throw OpenSubsonicLibrarySourceError.invalidContinuation
            }
            section = expected
            self.folderIndex = folderIndex
            self.offset = offset
        }
    }

    private let client: any OpenSubsonicCatalogLoading
    private let maximumConcurrentAlbumRequests: Int
    private var folderIDs: [String?]?
    private var artistsCache: [Artist]?
    private var seenAlbumIDs: Set<AlbumID> = []
    private var seenTrackIDs: Set<TrackID> = []

    public init(
        client: any OpenSubsonicCatalogLoading,
        maximumConcurrentAlbumRequests: Int = 6
    ) {
        self.client = client
        self.maximumConcurrentAlbumRequests = max(1, maximumConcurrentAlbumRequests)
    }

    public func artistsPage(
        serverID: ServerID,
        request: LibraryPageRequest
    ) async throws -> LibraryPage<Artist> {
        try validate(serverID: serverID, pageSize: request.pageSize)
        let cursor = try cursor(request.continuation, section: .artists)
        if request.continuation == nil { artistsCache = nil }
        let artists = try await allArtists()
        let items = page(artists, offset: cursor.offset, limit: request.pageSize)
        let nextOffset = cursor.offset + items.count
        return LibraryPage(
            items: items,
            nextContinuation: nextOffset < artists.count
                ? Cursor(section: .artists, offset: nextOffset).encoded
                : nil
        )
    }

    public func albumsPage(
        serverID: ServerID,
        request: LibraryPageRequest
    ) async throws -> LibraryPage<Album> {
        try validate(serverID: serverID, pageSize: request.pageSize)
        if request.continuation == nil { seenAlbumIDs.removeAll(keepingCapacity: true) }
        var cursor = try cursor(request.continuation, section: .albums)
        let folders = try await folders()

        while cursor.folderIndex < folders.count {
            try Task.checkCancellation()
            let raw = try await client.albums(
                type: .alphabeticalByName,
                size: min(500, request.pageSize),
                offset: cursor.offset,
                musicFolderID: folders[cursor.folderIndex]
            )
            let items = raw.filter { seenAlbumIDs.insert($0.id).inserted }
            let next = nextCursor(
                section: .albums,
                current: cursor,
                receivedCount: raw.count,
                requestedCount: min(500, request.pageSize),
                folderCount: folders.count
            )
            if !items.isEmpty || next == nil {
                return LibraryPage(items: items, nextContinuation: next?.encoded)
            }
            cursor = next!
        }
        return LibraryPage(items: [])
    }

    public func tracksPage(
        serverID: ServerID,
        request: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        try validate(serverID: serverID, pageSize: request.pageSize)
        if request.continuation == nil { seenTrackIDs.removeAll(keepingCapacity: true) }
        var cursor = try cursor(request.continuation, section: .tracks)
        let folders = try await folders()

        while cursor.folderIndex < folders.count {
            try Task.checkCancellation()
            let requestedAlbumCount = min(50, request.pageSize)
            let albums = try await client.albums(
                type: .alphabeticalByName,
                size: requestedAlbumCount,
                offset: cursor.offset,
                musicFolderID: folders[cursor.folderIndex]
            )
            let details = try await albumDetails(albums)
            var pageSeen: Set<TrackID> = []
            let items = details
                .flatMap(\.tracks)
                .filter { !seenTrackIDs.contains($0.id) && pageSeen.insert($0.id).inserted }
            seenTrackIDs.formUnion(pageSeen)

            let next = nextCursor(
                section: .tracks,
                current: cursor,
                receivedCount: albums.count,
                requestedCount: requestedAlbumCount,
                folderCount: folders.count
            )
            if !items.isEmpty || next == nil {
                return LibraryPage(items: items, nextContinuation: next?.encoded)
            }
            cursor = next!
        }
        return LibraryPage(items: [])
    }

    private func validate(serverID: ServerID, pageSize: Int) throws {
        guard serverID == client.serverID else {
            throw OpenSubsonicLibrarySourceError.serverMismatch(
                expected: client.serverID,
                actual: serverID
            )
        }
        guard pageSize > 0 else { throw OpenSubsonicLibrarySourceError.invalidPageSize(pageSize) }
    }

    private func cursor(_ encoded: String?, section: Section) throws -> Cursor {
        guard let encoded else { return Cursor(section: section) }
        return try Cursor(encoded: encoded, expected: section)
    }

    private func folders() async throws -> [String?] {
        if let folderIDs { return folderIDs }
        let values = try await client.musicFolders().map { Optional($0.id) }
        let resolved: [String?] = values.isEmpty ? [nil] : values
        folderIDs = resolved
        return resolved
    }

    private func allArtists() async throws -> [Artist] {
        if let artistsCache { return artistsCache }
        var values: [ArtistID: Artist] = [:]
        for folderID in try await folders() {
            try Task.checkCancellation()
            for artist in try await client.artists(musicFolderID: folderID) {
                values[artist.id] = artist
            }
        }
        let sorted = values.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id.rawValue < $1.id.rawValue : comparison == .orderedAscending
        }
        artistsCache = sorted
        return sorted
    }

    private func nextCursor(
        section: Section,
        current: Cursor,
        receivedCount: Int,
        requestedCount: Int,
        folderCount: Int
    ) -> Cursor? {
        if receivedCount == requestedCount {
            return Cursor(
                section: section,
                folderIndex: current.folderIndex,
                offset: current.offset + receivedCount
            )
        }
        let nextFolder = current.folderIndex + 1
        return nextFolder < folderCount ? Cursor(section: section, folderIndex: nextFolder) : nil
    }

    private func albumDetails(_ albums: [Album]) async throws -> [OpenSubsonicAlbumDetail] {
        guard !albums.isEmpty else { return [] }
        var results: [(Int, OpenSubsonicAlbumDetail)] = []
        results.reserveCapacity(albums.count)

        var start = 0
        while start < albums.count {
            try Task.checkCancellation()
            let end = min(albums.count, start + maximumConcurrentAlbumRequests)
            let batch = Array(albums[start..<end])
            let indexed = try await withThrowingTaskGroup(
                of: (Int, OpenSubsonicAlbumDetail).self,
                returning: [(Int, OpenSubsonicAlbumDetail)].self
            ) { group in
                for (localIndex, album) in batch.enumerated() {
                    let index = start + localIndex
                    group.addTask { [client] in
                        try Task.checkCancellation()
                        return (index, try await client.album(id: album.id))
                    }
                }
                var values: [(Int, OpenSubsonicAlbumDetail)] = []
                for try await value in group { values.append(value) }
                return values
            }
            results.append(contentsOf: indexed)
            start = end
        }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func page<Value>(_ values: [Value], offset: Int, limit: Int) -> [Value] {
        guard limit > 0, offset < values.count else { return [] }
        let start = max(0, offset)
        return Array(values[start..<min(values.count, start + limit)])
    }
}
