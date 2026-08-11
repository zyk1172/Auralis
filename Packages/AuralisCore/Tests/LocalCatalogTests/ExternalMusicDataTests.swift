import Domain
import Foundation
import LocalCatalog
import Testing

private func externalDataStore() throws -> LocalCatalogStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExternalMusicDataTests.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
}

@Suite("外部音乐身份与大众指标持久化")
struct ExternalMusicDataTests {
    @Test("ExternalMusicIdentity 使用 GlobalID 完整往返")
    func identityRoundTrip() async throws {
        let store = try externalDataStore()
        let identity = ExternalMusicIdentity(
            globalTrackID: GlobalID(serverID: "nas-a", remoteID: "track-42"),
            recordingMBID: "recording-id",
            releaseMBID: "release-id",
            releaseGroupMBID: "release-group-id",
            artistMBID: "artist-id",
            isrc: "USAAA0000001",
            matchConfidence: 0.97,
            matchMethod: .isrc,
            verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.upsertExternalMusicIdentity(identity)
        let loaded = try await store.externalMusicIdentity(for: identity.globalTrackID)

        #expect(loaded == identity)
        #expect(try await store.externalMusicIdentity(
            for: GlobalID(serverID: "nas-b", remoteID: "track-42")
        ) == nil)
    }

    @Test("中等置信度候选不自动写成正式身份")
    func candidateDoesNotAutoBind() async throws {
        let store = try externalDataStore()
        let globalID = GlobalID(serverID: "nas", remoteID: "ambiguous")
        let candidate = ExternalMusicIdentityCandidate(
            globalTrackID: globalID,
            recordingMBID: "candidate-recording",
            title: "Live Song",
            artistName: "Artist",
            duration: 240,
            confidence: 0.72,
            matchMethod: .metadataFuzzy
        )

        try await store.replaceExternalMusicCandidates([candidate], for: globalID)

        #expect(try await store.externalMusicCandidates(for: globalID) == [candidate])
        #expect(try await store.externalMusicIdentity(for: globalID) == nil)
    }

    @Test("三个大众数据来源分别保存且不合并评分含义")
    func communityMetricsRoundTrip() async throws {
        let store = try externalDataStore()
        let globalID = GlobalID(serverID: "nas", remoteID: "song")
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let values = [
            CommunityMusicMetric(
                source: .musicBrainz, entityID: "recording", rating: 4.2,
                ratingCount: 12, fetchedAt: fetchedAt, status: .available
            ),
            CommunityMusicMetric(
                source: .critiqueBrainz, entityID: "release-group", rating: 4.7,
                ratingCount: 3, reviewCount: 2, fetchedAt: fetchedAt, status: .available
            ),
            CommunityMusicMetric(
                source: .listenBrainz, entityID: "release-group",
                listenCount: 9_001, listenerCount: nil, fetchedAt: fetchedAt, status: .available
            ),
        ]
        for metric in values {
            try await store.upsertCommunityMusicMetric(metric, for: globalID)
        }

        let loaded = try await store.communityMusicMetrics(for: globalID)
        #expect(loaded.value(for: .musicBrainz)?.rating == 4.2)
        #expect(loaded.value(for: .critiqueBrainz)?.reviewCount == 2)
        #expect(loaded.value(for: .listenBrainz)?.listenCount == 9_001)
        #expect(loaded.hasCommunityEvidence)
    }
}
