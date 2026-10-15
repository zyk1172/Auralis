// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
@testable import AgentKit
import Domain
import AIKit
import Foundation
import LocalCatalog
import Testing

@Suite("Semantic collision recommendation")
struct SemanticCollisionRecommendationTests {
    private let server = ServerID(rawValue: "server")

    @Test("Collision shortfall is filled by real indexed tracks with a shared artist budget")
    func automaticTagFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
        let tracks = [track("seed", title: "Seed", artist: "A"), track("same", title: "Same Artist", artist: "A"),
                      track("fallback", title: "Fallback", artist: "B"), track("disliked", title: "Disliked", artist: "C")]
        let sync = try await store.beginSync(serverID: server, mode: .full)
        try await store.stageTracks(tracks, session: sync)
        try await store.completeSync(sync, completedAt: .now)
        _ = try await store.writeRecommendationIndex(tracks.map {
            .init(id: "server:\($0.id.rawValue)", moods: ["mood.calm"], confidence: 0.9)
        }, serverID: server)
        try await store.setDisliked(GlobalID(serverID: server, remoteID: "disliked"), value: true)
        let call = ToolCall(name: "recommendation_ground_candidates", arguments: [
            "candidates": .array([.object(["title": .string("Seed"), "artist": .string("A")])]),
            "targetCount": .number(2), "maxPerArtist": .number(1), "preferTags": .array([.string("mood.calm")]),
        ])
        let descriptor = try #require(AgentToolRegistry.descriptor(for: call.name))
        let result = try await SemanticCollisionRecommendation.execute(call, descriptor: descriptor, catalog: store, serverID: server)
        #expect(result.facts["recommendation.collision.matched"] == "1")
        #expect(result.facts["recommendation.collision.tag_supplemented"] == "1")
        #expect(result.facts["recommendation.collision.fallback_needed"] == "false")
        if case let .trackCards(cards) = result.payload {
            #expect(cards.map(\.globalID.remoteID) == ["seed", "fallback"])
        } else { Issue.record("Expected grounded track cards") }
    }

    private func track(
        _ id: String,
        title: String,
        artist: String,
        album: String = "Album"
    ) -> Track {
        Track(
            id: TrackID(rawValue: id),
            serverID: server,
            albumID: AlbumID(rawValue: "album-\(id)"),
            artistID: ArtistID(rawValue: "artist-\(artist)"),
            title: title,
            artistName: artist,
            albumTitle: album,
            duration: 200
        )
    }

    @Test("规范化与 Remaster 版本可以撞入真实歌曲")
    func normalizesAndGroundsRemaster() {
        let library = [track("1", title: "Something - Remastered 2009", artist: "The Beatles")]
        let result = SemanticCollisionMatcher.match(
            candidates: [.init(title: "Something", artist: "The Beatles", album: nil)],
            tracks: library,
            targetCount: 1
        )
        #expect(result.map(\.id.rawValue) == ["1"])
    }

    @Test("同名但艺人错误时不误撞")
    func rejectsWrongArtist() {
        let library = [track("1", title: "Hello", artist: "Adele")]
        let result = SemanticCollisionMatcher.match(
            candidates: [.init(title: "Hello", artist: "Lionel Richie", album: nil)],
            tracks: library,
            targetCount: 1
        )
        #expect(result.isEmpty)
    }

    @Test("缺少艺人且同名歧义时拒绝猜测")
    func rejectsAmbiguousTitleOnlyCandidate() {
        let library = [
            track("1", title: "Home", artist: "Artist A"),
            track("2", title: "Home", artist: "Artist B"),
        ]
        let result = SemanticCollisionMatcher.match(
            candidates: [.init(title: "Home", artist: nil, album: nil)],
            tracks: library,
            targetCount: 1
        )
        #expect(result.isEmpty)
    }

    @Test("不喜欢、重复与同艺人过量在 Runtime 层被过滤")
    func enforcesLocalFilters() {
        let a1 = track("1", title: "One", artist: "A")
        let a2 = track("2", title: "Two", artist: "A")
        let b1 = track("3", title: "Three", artist: "B")
        let disliked = Set([GlobalID(serverID: server, remoteID: "1")])
        let result = SemanticCollisionMatcher.match(
            candidates: [
                .init(title: "One", artist: "A", album: nil),
                .init(title: "Two", artist: "A", album: nil),
                .init(title: "Two", artist: "A", album: nil),
                .init(title: "Three", artist: "B", album: nil),
            ],
            tracks: [a1, a2, b1],
            disliked: disliked,
            targetCount: 3,
            maxPerArtist: 1
        )
        #expect(result.map(\.id.rawValue) == ["2", "3"])
    }
}
