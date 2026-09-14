// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Testing

@Test("local catalog overlay preserves remote and local identities for the same recording")
func localCatalogOverlayPreservesSourceIdentity() {
    let remote = Track(
        id: "remote-track", serverID: "server-a", albumID: "album-a", artistID: "artist-a",
        title: "Same Song", artistName: "Artist", albumTitle: "Album", duration: 200,
        sourceInfo: AudioSourceInfo(codec: "mp3")
    )
    let local = Track(
        id: "local-track", serverID: LocalCatalogOverlay.localServerID,
        albumID: "local-album", artistID: "local-artist",
        title: "Same Song", artistName: "Artist", albumTitle: "Album", duration: 200,
        sourceInfo: AudioSourceInfo(codec: "flac")
    )
    let snapshot = LocalCatalogOverlaySnapshot(tracks: [local, local])
    let merged = LocalCatalogOverlay.mergedTracks(remote: [remote], local: snapshot)

    // Exact duplicate GlobalIDs collapse, but source-distinct versions stay addressable.
    #expect(merged.count == 2)
    #expect(merged.map(\.serverID) == [remote.serverID, LocalCatalogOverlay.localServerID])
    #expect(merged.map(\.sourceInfo.normalizedCodec) == ["mp3", "flac"])
}

@Test("local catalog overlay keeps identical remote IDs isolated by server")
func localCatalogOverlayKeepsCrossServerIdentity() {
    let first = Track(
        id: "same-id", serverID: "server-a", albumID: "album", artistID: "artist",
        title: "Same Song", artistName: "Artist", albumTitle: "Album", duration: 200
    )
    let second = Track(
        id: "same-id", serverID: "server-b", albumID: "album", artistID: "artist",
        title: "Same Song", artistName: "Artist", albumTitle: "Album", duration: 200
    )

    let merged = LocalCatalogOverlay.mergedTracks(
        remote: [first, second],
        local: .empty
    )

    #expect(merged.count == 2)
    #expect(merged.map(\.serverID) == [first.serverID, second.serverID])
}

@Test("replacing local genre overlay does not accumulate old counts")
func localCatalogOverlaySubtractsPreviousGenres() {
    let previous = LocalCatalogOverlaySnapshot(genres: [Genre(name: "Rock", songCount: 3)])
    let mixed = [Genre(name: "Rock", songCount: 8), Genre(name: "Jazz", songCount: 2)]
    let remote = LocalCatalogOverlay.removingLocalGenreContribution(from: mixed, previousLocal: previous)
    let next = LocalCatalogOverlaySnapshot(genres: [Genre(name: "Rock", songCount: 4)])
    let merged = LocalCatalogOverlay.mergedGenres(remote: remote, local: next)

    #expect(merged.first(where: { $0.name == "Rock" })?.songCount == 9)
    #expect(merged.first(where: { $0.name == "Jazz" })?.songCount == 2)
}