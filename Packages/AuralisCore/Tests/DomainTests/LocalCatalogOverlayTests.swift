// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Testing

@Test("local catalog overlay keeps active server and local tracks while preferring quality")
func localCatalogOverlayMergesWithoutFakeServerAccount() {
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
    let snapshot = LocalCatalogOverlaySnapshot(tracks: [local])
    let merged = LocalCatalogOverlay.mergedTracks(remote: [remote], local: snapshot)

    #expect(merged.count == 1)
    #expect(merged[0].serverID == LocalCatalogOverlay.localServerID)
    #expect(merged[0].sourceInfo.normalizedCodec == "flac")
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
