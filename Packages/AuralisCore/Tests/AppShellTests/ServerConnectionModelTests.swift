import Application
import AppShell
import Domain
import Foundation
import TestSupport
import Testing

private struct SuccessfulConnector: ServerConnecting {
    let result: ServerConnectionResult
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        #expect(!input.password.isEmpty)
        return result
    }
}

@Test("Successful connection replaces the empty catalog with server domain models")
@MainActor
func successfulConnectionSwitchesCatalog() async throws {
    let fixture = TestCatalogFactory.make()
    let account = ServerAccount(
        id: "test-server",
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        credentialReference: "test-credential"
    )
    let remoteTracks = Array(fixture.tracks.prefix(3)).map { track in
        Track(
            id: TrackID(rawValue: "remote-\(track.id.rawValue)"),
            serverID: account.id,
            albumID: track.albumID,
            artistID: track.artistID,
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            duration: track.duration
        )
    }
    let result = ServerConnectionResult(
        account: account,
        capabilities: .init(supportsStructuredLyrics: true),
        artists: [],
        albums: [],
        tracks: remoteTracks,
        serverType: "test-server",
        serverVersion: "1.0"
    )
    let model = AuralisAppModel(connector: SuccessfulConnector(result: result))
    await model.connect(to: .init(
        displayName: "Test Library",
        baseURL: account.baseURL!,
        username: "listener",
        password: "test-only-value"
    ))
    #expect(model.catalog.account.id == account.id)
    #expect(model.catalog.tracks.count == 3)
    #expect(model.serverCapabilities.supportsStructuredLyrics)
    guard case let .connected(_, serverType, _, trackCount) = model.serverConnectionState else {
        Issue.record("Expected a connected state")
        return
    }
    #expect(serverType == "test-server")
    #expect(trackCount == 3)
}
