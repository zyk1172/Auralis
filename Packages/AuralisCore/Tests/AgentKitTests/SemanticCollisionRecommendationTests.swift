// SPDX-License-Identifier: GPL-3.0-only
@testable import AgentKit
import Domain
import LocalCatalog
import Testing

@Suite("Semantic collision recommendation")
struct SemanticCollisionRecommendationTests {
    private let server = ServerID(rawValue: "server")

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
