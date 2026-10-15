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

    @Test("Combination arguments fail closed and appear in both recommendation tool contracts")
    func combinationArguments() throws {
        let call = ToolCall(name: "recommend_by_tags", arguments: [
            "anyTagGroups": .array([.array([.string("自习"), .string("钢琴")])]),
            "preferTags": .array([.string("自习"), .string("学习"), .string("钢琴")]),
            "minimumPreferredMatches": .number(2),
        ])
        let query = try TagRecommendationTool.query(call, limit: 10).validated()
        #expect(query.anyTagGroups == [["instrument.piano", "scene.study"]])
        #expect(query.preferTags.count == 2)
        #expect(query.minimumPreferredMatches == 2)
        for name in ["recommend_by_tags", "recommendation_ground_candidates"] {
            let descriptor = try #require(AgentToolRegistry.descriptor(for: name))
            #expect(descriptor.parameters.contains { $0.name == "anyTagGroups" })
            #expect(descriptor.parameters.contains { $0.name == "minimumPreferredMatches" })
        }
        for bad in [AIJSONValue.string("bad"), .array([.array([])]), .array([.array([.number(1)])])] {
            #expect(throws: (any Error).self) {
                try TagRecommendationTool.query(ToolCall(name: call.name, arguments: ["anyTagGroups": bad]), limit: 10)
            }
        }
        for bad in [AIJSONValue.number(1.5), .number(1e100), .string("2"), .number(-1)] {
            #expect(throws: (any Error).self) {
                try TagRecommendationTool.query(ToolCall(name: call.name, arguments: ["minimumPreferredMatches": bad]), limit: 10)
            }
        }
    }

    @Test("Collision seeds and automatic fallback both preserve complete alternative groups")
    func combinationFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
        let tracks = [track("partial", title: "Partial", artist: "A"), track("piano", title: "Piano", artist: "B"),
                      track("guitar", title: "Guitar", artist: "C")]
        let sync = try await store.beginSync(serverID: server, mode: .full)
        try await store.stageTracks(tracks, session: sync)
        try await store.completeSync(sync, completedAt: .now)
        _ = try await store.writeRecommendationIndex([
            .init(id: "server:partial", scenes: ["scene.study"], confidence: 0.9),
            .init(id: "server:piano", scenes: ["scene.study", "scene.pomodoro"], confidence: 0.9, instruments: ["instrument.piano"]),
            .init(id: "server:guitar", scenes: ["scene.late_night"], confidence: 0.9, instruments: ["instrument.acoustic_guitar"]),
        ], serverID: server)
        let call = ToolCall(name: "recommendation_ground_candidates", arguments: [
            "candidates": .array([.object(["title": .string("Partial"), "artist": .string("A")]), .object(["title": .string("Piano"), "artist": .string("B")])]),
            "targetCount": .number(3),
            "anyTagGroups": .array([.array([.string("自习"), .string("钢琴")]), .array([.string("深夜"), .string("木吉他")])]),
            "preferTags": .array([.string("scene.study"), .string("scene.late_night"), .string("instrument.piano"), .string("instrument.acoustic_guitar")]),
            "minimumPreferredMatches": .number(2),
        ])
        let descriptor = try #require(AgentToolRegistry.descriptor(for: call.name))
        let result = try await SemanticCollisionRecommendation.execute(call, descriptor: descriptor, catalog: store, serverID: server)
        #expect(result.facts["recommendation.collision.matched"] == "1")
        #expect(result.facts["recommendation.collision.tag_supplemented"] == "1")
        #expect(result.facts["recommendation.collision.fallback_needed"] == "true")
        if case let .trackCards(cards) = result.payload {
            #expect(cards.map(\.globalID.remoteID) == ["piano", "guitar"])
        } else { Issue.record("Expected grounded track cards") }
    }

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
