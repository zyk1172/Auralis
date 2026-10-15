// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Domain
import LocalCatalog
import Testing

@Suite("Multi-dimensional tag recommendation")
struct TagRecommendationRankerTests {
    @Test("Alternative combinations match whole groups and return multi-group songs once")
    func alternativeGroups() throws {
        let both = candidate("both", tags: ["scene.study", "instrument.piano", "scene.late_night", "instrument.acoustic_guitar", "vocal.instrumental"])
        let first = candidate("first", tags: ["scene.study", "instrument.piano", "vocal.instrumental"])
        let second = candidate("second", tags: ["scene.late_night", "instrument.acoustic_guitar", "vocal.instrumental"])
        let crossed = candidate("crossed", tags: ["scene.study", "instrument.acoustic_guitar", "vocal.instrumental"])
        let sad = candidate("sad", tags: Array(both.tags.keys) + ["mood.sad"])
        let vocal = candidate("vocal", tags: ["scene.study", "instrument.piano"])
        let query = TagRecommendationQuery(includeTags: ["纯音乐"], excludeTags: ["伤感"], anyTagGroups: [
            ["自习", "钢琴"], ["深夜", "木吉他"], ["钢琴", "学习"],
        ])
        let result = try TagRecommendationRanker.recommend(candidates: [crossed, first, second, sad, vocal, both], query: query)
        #expect(result.first?.track.id.rawValue == "both")
        #expect(Set(result.map(\.track.id.rawValue)) == ["both", "first", "second"])
        #expect(result.count == 3)
        #expect(result.first?.matchedTags.count == 5)
        #expect(try query.validated().anyTagGroups.count == 2)
    }

    @Test("Independent same-dimension matches boost rank; aliases cannot inflate minimum match counts")
    func minimumMatchesAndCoverage() throws {
        let full = candidate("z-full", tags: ["scene.study", "scene.focus", "instrument.piano"])
        let partial = candidate("a-partial", tags: ["scene.study", "instrument.piano"])
        let query = TagRecommendationQuery(preferTags: ["自习", "学习", "专心", "钢琴"], minimumPreferredMatches: 2)
        #expect(try query.validated().preferTags.count == 3)
        let result = try TagRecommendationRanker.recommend(candidates: [partial, full], query: query)
        #expect(result.first?.track.id.rawValue == "z-full")
        #expect(result.count == 2)
        var all = query
        all.minimumPreferredMatches = 3
        #expect(try TagRecommendationRanker.recommend(candidates: [partial, full], query: all).map(\.track.id.rawValue) == ["z-full"])
        #expect(throws: TagRecommendationError.self) { try TagRecommendationQuery(preferTags: ["自习", "学习"], minimumPreferredMatches: 2).validated() }
        #expect(throws: TagRecommendationError.self) { try TagRecommendationQuery(anyTagGroups: [[]]).validated() }
        #expect(throws: TagRecommendationError.self) { try TagRecommendationQuery(anyTagGroups: [["unknown"]]).validated() }
    }

    private func candidate(_ id: String, artist: String = "", album: String = "", tags: [String], confidence: Double = 0.9) -> TagRecommendationCandidate {
        .init(track: Track(id: TrackID(rawValue: id), serverID: "server", albumID: AlbumID(rawValue: "album-\(id)"), artistID: ArtistID(rawValue: "artist-\(id)"),
                           title: "Song \(id)", artistName: artist.isEmpty ? id : artist, albumTitle: album, duration: 180),
              tags: Dictionary(uniqueKeysWithValues: tags.map { ($0, confidence) }))
    }

    @Test("Scene and instrument coverage outranks one matching dimension")
    func balancesDimensions() throws {
        let full = candidate("full", tags: ["scene.late_night", "instrument.piano"])
        let partial = candidate("partial", tags: ["scene.late_night"], confidence: 1)
        let result = try TagRecommendationRanker.recommend(candidates: [partial, full], query: .init(preferTags: ["scene.late_night", "instrument.piano"]))
        #expect(result.first?.track.id.rawValue == "full")
        #expect(result.first?.matchedTags == ["instrument.piano", "scene.late_night"])
    }

    @Test("All include tags, exclusions and numeric ranges stay hard")
    func preservesHardConstraints() throws {
        let good = candidate("good", tags: ["scene.late_night", "instrument.piano"])
        let sad = candidate("sad", tags: ["scene.late_night", "instrument.piano", "mood.sad"])
        let partial = candidate("partial", tags: ["scene.late_night"])
        let candidates = [good, sad, partial].map { TagRecommendationCandidate(track: $0.track, tags: $0.tags, numericFeatures: ["energy": 3]) }
        let result = try TagRecommendationRanker.recommend(candidates: candidates, query: .init(
            includeTags: ["scene.late_night", "instrument.piano"], excludeTags: ["mood.sad"], numericRanges: ["energy": 1...4]))
        #expect(result.map(\.track.id.rawValue) == ["good"])
        #expect(try TagRecommendationRanker.recommend(candidates: candidates, query: .init(numericRanges: ["energy": 8...10])).isEmpty)
    }

    @Test("Weak or unrelated tags cannot pad a short result")
    func noRandomPadding() throws {
        let result = try TagRecommendationRanker.recommend(candidates: [candidate("weak", tags: ["mood.calm"], confidence: 0.2), candidate("other", tags: ["mood.sad"])],
                                                         query: .init(preferTags: ["mood.calm"]))
        #expect(result.isEmpty)
        #expect(throws: TagRecommendationError.self) { try TagRecommendationQuery().validated() }
        #expect(throws: TagRecommendationError.self) { try TagRecommendationQuery(includeTags: ["unknown"]).validated() }
        #expect(throws: TagRecommendationError.self) { try TagRecommendationQuery(excludeTags: ["mood.sad"]).validated() }
        #expect(throws: TagRecommendationError.self) { try TagRecommendationQuery(preferTags: ["温暖"]).validated() }
    }

    @Test("Preferences boost ranking without becoming hard constraints")
    func preferencesStaySoft() throws {
        let full = candidate("full", tags: ["mood.calm", "instrument.piano"])
        let allowed = candidate("allowed", tags: ["mood.calm"])
        let result = try TagRecommendationRanker.recommend(candidates: [allowed, full], query: .init(includeTags: ["mood.calm"], preferTags: ["instrument.piano"]))
        #expect(result.map(\.track.id.rawValue) == ["full", "allowed"])
    }

    @Test("Artist/album diversity includes the existing collision selections")
    func respectsExistingSelections() throws {
        let seed = candidate("seed", artist: "Artist A", album: "Album", tags: ["mood.calm"])
        let same = candidate("same", artist: "Artist A", album: "Album", tags: ["mood.calm"])
        let different = candidate("different", artist: "Artist B", tags: ["mood.calm"])
        let result = try TagRecommendationRanker.recommend(candidates: [seed, same, different],
            query: .init(preferTags: ["mood.calm"], maxPerArtist: 3, maxPerAlbum: 1), existingTracks: [seed.track])
        #expect(result.map(\.track.id.rawValue) == ["different"])
    }

    @Test("Exclusions use GlobalID and ties do not depend on input order")
    func stableAndServerScoped() throws {
        let a = candidate("a", tags: ["mood.calm"]), b = candidate("b", tags: ["mood.calm"])
        let query = TagRecommendationQuery(preferTags: ["mood.calm"], excludedTrackIDs: ["other:a"])
        let first = try TagRecommendationRanker.recommend(candidates: [a, b], query: query)
        let second = try TagRecommendationRanker.recommend(candidates: [b, a], query: query)
        #expect(first.map(\.track.id) == second.map(\.track.id))
        #expect(first.count == 2)
        #expect(try TagRecommendationRanker.recommend(candidates: [a, b], query: .init(preferTags: ["mood.calm"], excludedTrackIDs: ["server:a"])).map(\.track.id.rawValue) == ["b"])
    }

    @Test("Duplicate encodings collapse without collapsing different duration recordings")
    func recordingDeduplication() throws {
        let first = candidate("a", tags: ["mood.calm"])
        func variant(_ id: TrackID, duration: Double) -> Track {
            Track(id: id, serverID: first.track.serverID, albumID: first.track.albumID, artistID: first.track.artistID,
                  title: first.track.title, artistName: first.track.artistName, albumTitle: first.track.albumTitle, duration: duration)
        }
        let duplicate = variant("duplicate", duration: 180)
        let live = variant("live", duration: 300)
        let result = try TagRecommendationRanker.recommend(candidates: [first, .init(track: duplicate, tags: first.tags), .init(track: live, tags: first.tags)],
                                                         query: .init(preferTags: ["mood.calm"]))
        #expect(result.count == 2)
    }
}
