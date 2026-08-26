import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import Testing

@Suite("Recommendation Index fixed taxonomy v3")
struct RecommendationIndexFixedTaxonomyTests {
    private func makeStore() throws -> LocalCatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-fixed-taxonomy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
    }

    private func seedTrack(
        _ store: LocalCatalogStore,
        serverID: ServerID,
        remoteID: String,
        title: String
    ) async throws -> GlobalID {
        let track = Track(
            id: TrackID(rawValue: remoteID),
            serverID: serverID,
            albumID: AlbumID(rawValue: "album-\(remoteID)"),
            artistID: ArtistID(rawValue: "artist-\(remoteID)"),
            title: title,
            artistName: "Artist",
            albumTitle: "Album",
            duration: 180
        )
        let sync = try await store.beginSync(serverID: serverID, mode: .full)
        try await store.stageTracks([track], session: sync)
        try await store.completeSync(sync, completedAt: .now)
        return GlobalID(serverID: serverID, remoteID: track.id.rawValue)
    }

    private func seedTracks(
        _ store: LocalCatalogStore,
        serverID: ServerID,
        specs: [(remoteID: String, title: String)]
    ) async throws -> [GlobalID] {
        let tracks = specs.map { spec in
            Track(
                id: TrackID(rawValue: spec.remoteID),
                serverID: serverID,
                albumID: AlbumID(rawValue: "album-\(spec.remoteID)"),
                artistID: ArtistID(rawValue: "artist-\(spec.remoteID)"),
                title: spec.title,
                artistName: "Artist",
                albumTitle: "Album",
                duration: 180
            )
        }
        let sync = try await store.beginSync(serverID: serverID, mode: .full)
        try await store.stageTracks(tracks, session: sync)
        try await store.completeSync(sync, completedAt: .now)
        return tracks.map { GlobalID(serverID: serverID, remoteID: $0.id.rawValue) }
    }

    @Test("Taxonomy is internally valid and sacred is a fixed mood")
    func taxonomyValidationAndSacred() {
        #expect(RecommendationIndexTaxonomy.validate().isEmpty)
        #expect(RecommendationIndexTaxonomy.byID[TagID(rawValue: "mood.sacred")] != nil)
        #expect(RecommendationIndexTaxonomy.byID[TagID(rawValue: "instrument.piano")] != nil)
        #expect(RecommendationIndexTaxonomy.byID[TagID(rawValue: "vocal.instrumental")] != nil)
    }

    @Test("Taxonomy search resolves common user language to stable IDs")
    func taxonomySearchResolvesCommonLanguage() {
        func firstID(_ query: String) -> String? {
            RecommendationIndexTaxonomy.search(query, limit: 10).first?.id.rawValue
        }
        #expect(firstID("神圣") == "mood.sacred")
        #expect(firstID("钢琴") == "instrument.piano")
        #expect(firstID("无歌词") == "vocal.instrumental")
        #expect(firstID("深夜") == "scene.late_night")
        #expect(firstID("写代码") == "scene.coding")
        #expect(firstID("下雨") == "scene.rainy")
        #expect(firstID("女声") == "vocal.female_lead")
    }

    @Test("Fixed taxonomy writes persist stable IDs and read back display names")
    func writeAndReadFixedTaxonomy() async throws {
        let store = try makeStore()
        let serverID: ServerID = "fixed-v3"
        let gid = try await seedTrack(store, serverID: serverID, remoteID: "t1", title: "Sacred")
        let classification = RecommendationIndexClassification(
            id: gid.description,
            moods: ["mood.sacred"],
            scenes: ["scene.late_night"],
            energy: 4,
            vocals: ["vocal.instrumental"],
            textures: ["texture.spacious"],
            styles: ["style.city_pop"],
            confidence: 0.9,
            instruments: ["instrument.piano"]
        )

        let written = try await store.writeRecommendationIndex(
            [classification],
            serverID: serverID,
            requireExact: true
        )
        #expect(written == 1)
        let status = try await store.recommendationIndexStatus(serverID: serverID)
        #expect(status.pendingUniqueTracks == 0)

        let indexed = try await store.readRecommendationIndex(serverID: serverID)
        #expect(indexed.count == 1)
        let tags = try #require(indexed.first?.tags)
        #expect(tags["mood"]?.contains("神圣") == true)
        #expect(tags["scene"]?.contains("深夜") == true)
        #expect(tags["vocal"]?.contains("器乐 / 无人声") == true)
        #expect(tags["instrument"]?.contains("钢琴") == true)
        #expect(tags["style"]?.contains("City Pop") == true)
        #expect(tags["texture"]?.contains("空间宽阔") == true)
    }

    @Test("Strict catalog write rejects unknown taxonomy IDs")
    func strictWriteRejectsUnknownTaxonomy() async throws {
        let store = try makeStore()
        let serverID: ServerID = "fixed-v3-strict"
        let gid = try await seedTrack(store, serverID: serverID, remoteID: "t1", title: "Unknown")
        let classification = RecommendationIndexClassification(
            id: gid.description,
            moods: ["mood.definitely_missing"],
            energy: 3,
            confidence: 0.8
        )
        await #expect(throws: RecommendationIndexWriteError.self) {
            try await store.writeRecommendationIndex(
                [classification],
                serverID: serverID,
                requireExact: true
            )
        }
    }

    @Test("Structured recommendation query supports include/exclude/prefer")
    func structuredQueryUsesFixedTags() async throws {
        let store = try makeStore()
        let serverID: ServerID = "fixed-v3-query"
        let ids = try await seedTracks(store, serverID: serverID, specs: [
            ("late-sacred", "Late Sacred"),
            ("rainy-sacred", "Rainy Sacred"),
            ("late-calm", "Late Calm"),
        ])
        let lateSacred = ids[0]
        let rainySacred = ids[1]
        let lateCalm = ids[2]

        try await store.writeRecommendationIndex([
            RecommendationIndexClassification(id: lateSacred.description, moods: ["mood.sacred"], scenes: ["scene.late_night"], energy: 4, confidence: 0.9),
            RecommendationIndexClassification(id: rainySacred.description, moods: ["mood.sacred"], scenes: ["scene.rainy"], energy: 4, confidence: 0.8),
            RecommendationIndexClassification(id: lateCalm.description, moods: ["mood.calm"], scenes: ["scene.late_night"], energy: 2, confidence: 0.9),
        ], serverID: serverID, requireExact: true)

        let late = try await store.recommendationIndexTrackIDs(
            serverID: serverID,
            matching: RecommendationIndexQuery(
                includeTags: ["scene.late_night"],
                preferTags: ["mood.sacred"],
                limit: 10
            )
        )
        #expect(Set(late) == Set([lateSacred, lateCalm]))

        let excluded = try await store.recommendationIndexTrackIDs(
            serverID: serverID,
            matching: RecommendationIndexQuery(
                includeTags: ["scene.late_night"],
                excludeTags: ["mood.calm"],
                limit: 10
            )
        )
        #expect(Set(excluded) == Set([lateSacred]))
    }
}
