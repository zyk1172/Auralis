import Domain
import Foundation
import MusicLibrary
import Testing

@Test("Server repository keeps reads and searches scoped to one account")
func repositoryIsolation() async throws {
    let first = catalog(serverID: "repository-a", prefix: "alpha", trackCount: 2)
    let second = catalog(serverID: "repository-b", prefix: "beta", trackCount: 2)
    let store = InMemoryServerMusicLibraryStore(
        serverID: first.serverID,
        artists: first.artists,
        albums: first.albums,
        tracks: first.tracks
    )
    let secondSession = try await store.beginSync(serverID: second.serverID, mode: .full)
    try await store.stageArtists(second.artists, session: secondSession)
    try await store.stageAlbums(second.albums, session: secondSession)
    try await store.stageTracks(second.tracks, session: secondSession)
    for section in LibrarySyncSection.allCases {
        try await store.saveCheckpoint(.init(
            sessionID: secondSession.id,
            serverID: second.serverID,
            section: section,
            processedCount: section == .tracks ? second.tracks.count : 1,
            completedAt: .now
        ), session: secondSession)
    }
    try await store.completeSync(secondSession, completedAt: .now)

    let firstRepository = ServerMusicLibraryRepository(serverID: first.serverID, store: store)
    let secondRepository = ServerMusicLibraryRepository(serverID: second.serverID, store: store)
    #expect(try await firstRepository.search(query: "beta", limit: 10).isEmpty)
    #expect(try await secondRepository.search(query: "beta", limit: 10).count == 2)
    #expect(try await firstRepository.tracks(offset: 0, limit: 10).allSatisfy { $0.serverID == first.serverID })
}

@Test("Full sync paginates and atomically replaces stale records")
func fullSyncPaginationAndReplacement() async throws {
    let serverID: ServerID = "sync-full"
    let stale = catalog(serverID: serverID, prefix: "stale", trackCount: 1)
    let fresh = catalog(serverID: serverID, prefix: "fresh", trackCount: 5)
    let store = InMemoryServerMusicLibraryStore(
        serverID: serverID,
        artists: stale.artists,
        albums: stale.albums,
        tracks: stale.tracks
    )
    let source = FixtureSource(snapshot: fresh)
    let synchronizer = LibrarySynchronizer(source: source, store: store, pageSize: 2)

    let report = try await synchronizer.sync(serverID: serverID, mode: .full)
    #expect(report.artistCount == 1)
    #expect(report.albumCount == 1)
    #expect(report.trackCount == 5)
    #expect(report.pageCount == 5)
    #expect(await store.tracks(serverID: serverID, offset: 0, limit: 10).map(\.id) == fresh.tracks.map(\.id))
}

@Test("Incremental sync updates matching IDs and preserves records absent from the delta")
func incrementalUpsert() async throws {
    let serverID: ServerID = "sync-incremental"
    let initial = catalog(serverID: serverID, prefix: "library", trackCount: 3)
    let store = InMemoryServerMusicLibraryStore()
    let source = FixtureSource(snapshot: initial)
    let synchronizer = LibrarySynchronizer(source: source, store: store, pageSize: 2)
    _ = try await synchronizer.sync(serverID: serverID, mode: .full)

    var changed = initial.tracks[0]
    changed.title = "Changed by server"
    let added = makeTrack(
        id: "library-track-new",
        serverID: serverID,
        artist: initial.artists[0],
        album: initial.albums[0],
        number: 99
    )
    await source.setSnapshot(.init(
        serverID: serverID,
        artists: initial.artists,
        albums: initial.albums,
        tracks: [changed, added]
    ))

    let report = try await synchronizer.sync(serverID: serverID, mode: .incremental)
    #expect(report.trackCount == 2)
    #expect(await store.tracks(serverID: serverID, offset: 0, limit: 10).count == 4)
    #expect(await store.track(id: changed.id, serverID: serverID)?.title == "Changed by server")
}

@Test("Transient source failures follow retry policy without duplicating records")
func retriesTransientFetch() async throws {
    let data = catalog(serverID: "sync-retry", prefix: "retry", trackCount: 2)
    let source = FixtureSource(snapshot: data)
    await source.failNextArtistRequests(2)
    let sleeper = RecordingSleeper()
    let store = InMemoryServerMusicLibraryStore()
    let synchronizer = LibrarySynchronizer(
        source: source,
        store: store,
        pageSize: 10,
        retryPolicy: .init(maximumAttempts: 3, initialDelayNanoseconds: 1),
        sleeper: sleeper
    )

    let report = try await synchronizer.sync(serverID: data.serverID, mode: .full)
    #expect(report.retryCount == 2)
    #expect(await sleeper.delays() == [1, 2])
    #expect(await store.tracks(serverID: data.serverID, offset: 0, limit: 10).count == 2)
}

@Test("A cancelled page suspends the transaction and resumes from its checkpoint")
func cancellationAndResume() async throws {
    let data = catalog(serverID: "sync-resume", prefix: "resume", trackCount: 3)
    let source = FixtureSource(snapshot: data)
    await source.cancelOnceOnTrackContinuation("1")
    let store = InMemoryServerMusicLibraryStore()
    let synchronizer = LibrarySynchronizer(source: source, store: store, pageSize: 1)

    await #expect(throws: CancellationError.self) {
        _ = try await synchronizer.sync(serverID: data.serverID, mode: .full)
    }
    #expect(await store.hasSuspendedSync(serverID: data.serverID, mode: .full))
    #expect(await store.tracks(serverID: data.serverID, offset: 0, limit: 10).isEmpty)

    let report = try await synchronizer.sync(serverID: data.serverID, mode: .full)
    #expect(report.trackCount == 3)
    #expect(await source.trackContinuations() == [nil, "1", "1", "2"])
    #expect(await store.tracks(serverID: data.serverID, offset: 0, limit: 10).count == 3)
}

@Test("A cross-server response aborts without exposing staged pages")
func invalidServerResponseIsAtomic() async throws {
    let serverID: ServerID = "sync-expected"
    let original = catalog(serverID: serverID, prefix: "original", trackCount: 1)
    var invalid = catalog(serverID: serverID, prefix: "invalid", trackCount: 1)
    invalid.tracks = catalog(serverID: "sync-other", prefix: "foreign", trackCount: 1).tracks
    let source = FixtureSource(snapshot: invalid)
    let store = InMemoryServerMusicLibraryStore(
        serverID: serverID,
        artists: original.artists,
        albums: original.albums,
        tracks: original.tracks
    )
    let synchronizer = LibrarySynchronizer(source: source, store: store)

    await #expect(throws: LibrarySyncError.self) {
        _ = try await synchronizer.sync(serverID: serverID, mode: .full)
    }
    #expect(await store.tracks(serverID: serverID, offset: 0, limit: 10) == original.tracks)
}

@Test("Repeated pagination continuations fail instead of looping forever")
func continuationLoopRejected() async throws {
    let data = catalog(serverID: "sync-loop", prefix: "loop", trackCount: 2)
    let source = FixtureSource(snapshot: data)
    await source.enableTrackContinuationLoop()
    let store = InMemoryServerMusicLibraryStore()
    let synchronizer = LibrarySynchronizer(source: source, store: store, pageSize: 1)

    do {
        _ = try await synchronizer.sync(serverID: data.serverID, mode: .full)
        Issue.record("Expected a continuation loop error")
    } catch let error as LibrarySyncError {
        #expect(error == .continuationLoop(section: .tracks, continuation: "loop"))
    }
}

private struct CatalogFixture: Sendable {
    let serverID: ServerID
    var artists: [Artist]
    var albums: [Album]
    var tracks: [Track]
}

private func catalog(serverID: ServerID, prefix: String, trackCount: Int) -> CatalogFixture {
    let artist = Artist(
        id: ArtistID(rawValue: "\(prefix)-artist"),
        serverID: serverID,
        name: "\(prefix) artist",
        albumCount: 1
    )
    let album = Album(
        id: AlbumID(rawValue: "\(prefix)-album"),
        serverID: serverID,
        artistID: artist.id,
        title: "\(prefix) album",
        artistName: artist.name
    )
    let tracks = (0..<trackCount).map { index in
        makeTrack(
            id: "\(prefix)-track-\(index)",
            serverID: serverID,
            artist: artist,
            album: album,
            number: index + 1
        )
    }
    return CatalogFixture(serverID: serverID, artists: [artist], albums: [album], tracks: tracks)
}

private func makeTrack(
    id: String,
    serverID: ServerID,
    artist: Artist,
    album: Album,
    number: Int
) -> Track {
    Track(
        id: TrackID(rawValue: id),
        serverID: serverID,
        albumID: album.id,
        artistID: artist.id,
        title: "Track \(number)",
        artistName: artist.name,
        albumTitle: album.title,
        duration: 180,
        trackNumber: number
    )
}

private enum FixtureSourceError: Error {
    case transient
}

private actor FixtureSource: LibrarySyncSource {
    private var snapshot: CatalogFixture
    private var remainingArtistFailures = 0
    private var cancellationContinuation: String?
    private var didCancel = false
    private var loopsTrackContinuations = false
    private var observedTrackContinuations: [String?] = []

    init(snapshot: CatalogFixture) {
        self.snapshot = snapshot
    }

    func setSnapshot(_ snapshot: CatalogFixture) {
        self.snapshot = snapshot
    }

    func failNextArtistRequests(_ count: Int) {
        remainingArtistFailures = count
    }

    func cancelOnceOnTrackContinuation(_ continuation: String) {
        cancellationContinuation = continuation
        didCancel = false
    }

    func enableTrackContinuationLoop() {
        loopsTrackContinuations = true
    }

    func trackContinuations() -> [String?] {
        observedTrackContinuations
    }

    func artistsPage(serverID: ServerID, request: LibraryPageRequest) throws -> LibraryPage<Artist> {
        if remainingArtistFailures > 0 {
            remainingArtistFailures -= 1
            throw FixtureSourceError.transient
        }
        return page(snapshot.artists, request: request)
    }

    func albumsPage(serverID: ServerID, request: LibraryPageRequest) -> LibraryPage<Album> {
        page(snapshot.albums, request: request)
    }

    func tracksPage(serverID: ServerID, request: LibraryPageRequest) throws -> LibraryPage<Track> {
        observedTrackContinuations.append(request.continuation)
        if let cancellationContinuation,
           request.continuation == cancellationContinuation,
           !didCancel
        {
            didCancel = true
            throw CancellationError()
        }
        if loopsTrackContinuations {
            let offset = Int(request.continuation ?? "0") ?? 0
            let end = min(snapshot.tracks.count, offset + request.pageSize)
            let items = offset < end ? Array(snapshot.tracks[offset..<end]) : []
            return LibraryPage(items: items, nextContinuation: "loop", sourceRevision: "revision-loop")
        }
        return page(snapshot.tracks, request: request)
    }

    private func page<Value: Sendable>(_ values: [Value], request: LibraryPageRequest) -> LibraryPage<Value> {
        let offset = Int(request.continuation ?? "0") ?? 0
        let start = min(max(0, offset), values.count)
        let end = min(values.count, start + request.pageSize)
        let next = end < values.count ? String(end) : nil
        return LibraryPage(
            items: Array(values[start..<end]),
            nextContinuation: next,
            sourceRevision: "revision-current"
        )
    }
}

private actor RecordingSleeper: LibrarySyncSleeping {
    private var values: [UInt64] = []

    func sleep(nanoseconds: UInt64) {
        values.append(nanoseconds)
    }

    func delays() -> [UInt64] { values }
}
