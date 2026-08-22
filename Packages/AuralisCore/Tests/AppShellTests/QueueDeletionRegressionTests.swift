import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

private actor QueueDeletionProbeEngine: PlaybackControlling {
    private var playbackState = PlaybackState.idle

    func state() async -> PlaybackState { playbackState }

    func play(track: Track) async throws {
        playbackState = .playing
    }

    func pause() async { playbackState = .paused }

    func resume() async throws { playbackState = .playing }

    func stop() async { playbackState = .idle }
}

/// Queue deletion must preserve occurrence identity for duplicate tracks and choose
/// the nearest surviving logical occurrence after batch edits.
@Suite("Queue deletion occurrence regressions")
struct QueueDeletionRegressionTests {
    @Test("Deleting a different duplicate leaves the exact current occurrence active")
    @MainActor
    func deletingOtherDuplicateKeepsCurrentOccurrence() {
        let a = track("A")
        let b = track("B")
        let c = track("C")
        let model = makeModel(catalogTracks: [a, b, c])
        model.playQueue([a, b, a, c])

        let firstAEntryID = model.queueStore.entries[0].id
        let secondAEntryID = model.queueStore.entries[2].id
        model.playQueueEntry(id: secondAEntryID)
        #expect(model.queueStore.currentEntryID == secondAEntryID)

        model.removeQueueEntry(id: firstAEntryID)

        #expect(model.queue.map(\.id.rawValue) == ["B", "A", "C"])
        #expect(model.queueStore.currentEntryID == secondAEntryID)
        #expect(model.currentQueueIndex == 1)
        #expect(model.currentTrack.id == a.id)
        #expect(model.upcomingTracks.map(\.id.rawValue) == ["C"])

        model.next()
        #expect(model.currentTrack.id == c.id)
    }

    @Test("Deleting the current ordinary entry selects the next surviving entry")
    @MainActor
    func deletingCurrentEntrySelectsSuccessor() {
        let a = track("A")
        let b = track("B")
        let c = track("C")
        let model = makeModel(catalogTracks: [a, b, c])
        model.playQueue([a, b, c])

        let bEntryID = model.queueStore.entries[1].id
        let cEntryID = model.queueStore.entries[2].id
        model.playQueueEntry(id: bEntryID)
        model.removeFromQueue(atOffsets: IndexSet(integer: 1))

        #expect(model.queue.map(\.id.rawValue) == ["A", "C"])
        #expect(model.queueStore.currentEntryID == cEntryID)
        #expect(model.currentQueueIndex == 1)
        #expect(model.currentTrack.id == c.id)
    }

    @Test("Deleting the current tail entry falls back to the nearest predecessor")
    @MainActor
    func deletingCurrentTailSelectsPredecessor() {
        let a = track("A")
        let b = track("B")
        let c = track("C")
        let model = makeModel(catalogTracks: [a, b, c])
        model.playQueue([a, b, c])

        let bEntryID = model.queueStore.entries[1].id
        let cEntryID = model.queueStore.entries[2].id
        model.playQueueEntry(id: cEntryID)
        model.removeQueueEntry(id: cEntryID)

        #expect(model.queue.map(\.id.rawValue) == ["A", "B"])
        #expect(model.queueStore.currentEntryID == bEntryID)
        #expect(model.currentQueueIndex == 1)
        #expect(model.currentTrack.id == b.id)
    }

    @Test("Large queue batch deletion chooses the first surviving successor token")
    @MainActor
    func largeQueueDeletionWithEarlierEntry() async {
        let tracks = largeTracks()
        let model = makeModel(catalogTracks: tracks)
        model.playQueue(tracks)
        guard await waitUntilMainActor({
            model.queueStore.count == 256 && model.currentQueueIndex == 0
        }) else {
            Issue.record("large logical queue window did not install")
            return
        }

        model.playQueueEntry(id: model.queueStore.entries[250].id)
        #expect(model.currentTrack.id.rawValue == "large-250")
        model.removeFromQueue(atOffsets: IndexSet([100, 250]))

        #expect(model.currentTrack.id.rawValue == "large-251")
        #expect(model.upcomingTracks.first?.id.rawValue == "large-252")
    }

    @Test("Large queue batch deletion skips deleted successors but not the next token")
    @MainActor
    func largeQueueDeletionWithFollowingEntry() async {
        let tracks = largeTracks()
        let model = makeModel(catalogTracks: tracks)
        model.playQueue(tracks)
        guard await waitUntilMainActor({
            model.queueStore.count == 256 && model.currentQueueIndex == 0
        }) else {
            Issue.record("large logical queue window did not install")
            return
        }

        model.playQueueEntry(id: model.queueStore.entries[250].id)
        model.removeFromQueue(atOffsets: IndexSet([250, 251]))

        #expect(model.currentTrack.id.rawValue == "large-252")
        #expect(model.upcomingTracks.first?.id.rawValue == "large-253")
    }

    @Test("Large queue batch deletion at the tail falls back to the prior token")
    @MainActor
    func largeQueueDeletionAtTail() async {
        let tracks = largeTracks()
        let model = makeModel(catalogTracks: tracks)
        model.playTrack(tracks[518], in: tracks)
        guard await waitUntilMainActor({
            model.queueStore.count == 2 && model.currentTrack.id.rawValue == "large-518"
        }) else {
            Issue.record("large logical queue tail window did not install")
            return
        }

        model.removeFromQueue(atOffsets: IndexSet([0, 1]))

        #expect(model.currentTrack.id.rawValue == "large-517")
        #expect(model.upcomingTracks.isEmpty)
    }

    // MARK: - Fixtures

    @MainActor
    private func makeModel(catalogTracks: [Track]) -> AuralisAppModel {
        AuralisAppModel(
            catalog: LibraryCatalog(
                account: ServerAccount(
                    id: "server",
                    displayName: "Server",
                    baseURL: URL(string: "https://music.example.test")!,
                    username: "listener",
                    credentialReference: "test"
                ),
                artists: [], albums: [], tracks: catalogTracks,
                genres: [], playlists: [], history: [], downloads: [],
                lyrics: [:], recommendations: []
            ),
            engine: QueueDeletionProbeEngine(),
            connector: NoopConnector(),
            defaults: UserDefaults(suiteName: "queue-delete-tests-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("queue-delete-\(UUID().uuidString).sqlite")
        )
    }

    private func track(_ id: String) -> Track {
        Track(
            id: TrackID(rawValue: id), serverID: "server",
            albumID: "album", artistID: "artist", title: id,
            artistName: "Artist", albumTitle: "Album", duration: 180,
            streamURL: URL(string: "https://music.example.test/\(id).flac")
        )
    }

    private func largeTracks() -> [Track] {
        (0..<520).map { track("large-\($0)") }
    }

    @MainActor
    private func waitUntilMainActor(
        attempts: Int = 2_000,
        _ condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
}

private final class NoopConnector: ServerConnecting, @unchecked Sendable {
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw CancellationError()
    }
}
