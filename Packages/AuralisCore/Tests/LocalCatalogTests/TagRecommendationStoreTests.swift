// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Domain
import Foundation
import LocalCatalog
import Testing

@Test("Tag recommendations reject stale, disliked and other-server classifications")
func tagRecommendationFreshness() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
    let server: ServerID = "server"
    var tracks = ["good", "stale", "disliked"].map { id in
        Track(id: TrackID(rawValue: id), serverID: server, albumID: AlbumID(rawValue: id), artistID: ArtistID(rawValue: id),
              title: id, artistName: "Artist \(id)", albumTitle: "Album \(id)", duration: 180)
    }
    let sync = try await store.beginSync(serverID: server, mode: .full)
    try await store.stageTracks(tracks, session: sync)
    try await store.completeSync(sync, completedAt: .now)
    _ = try await store.writeRecommendationIndex(tracks.map { track in
        .init(id: "server:\(track.id.rawValue)", moods: ["mood.calm"], confidence: 0.9, instruments: ["instrument.piano"])
    }, serverID: server)
    try await store.setDisliked(GlobalID(serverID: server, remoteID: "disliked"), value: true)
    tracks[1].title = "Changed title"
    let update = try await store.beginSync(serverID: server, mode: .full)
    try await store.stageTracks(tracks, session: update)
    try await store.completeSync(update, completedAt: .now)
    let query = TagRecommendationQuery(includeTags: ["mood.calm"], preferTags: ["instrument.piano"])
    #expect(try await store.recommendByTags(serverIDs: [server], query: query).map(\.track.id.rawValue) == ["good"])
    #expect(try await store.recommendByTags(serverIDs: ["other"], query: query).isEmpty)
}
