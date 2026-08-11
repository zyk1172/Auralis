import Domain
import LocalCatalog
import Testing
@testable import AppShell

struct ExternalMusicInformationViewStateTests {
    private let globalID = GlobalID(serverID: ServerID(rawValue: "server"), remoteID: "track")

    @Test func totalSwitchAndAllSourceSwitchesResolveToDisabled() {
        #expect(resolve(preferences: .init(enabled: false)) == .disabled)
        #expect(resolve(preferences: .init(
            enabled: true,
            musicBrainzEnabled: false,
            critiqueBrainzEnabled: false,
            listenBrainzEnabled: false
        )) == .disabled)
    }

    @Test func loadingAndAvailableAreDistinct() {
        let preferences = ExternalMusicPreferences()
        #expect(ExternalMusicInformationViewState.resolve(
            preferences: preferences,
            isLoading: true,
            metrics: nil
        ) == .loading)

        #expect(resolve(
            preferences: preferences,
            statuses: [.musicBrainz: .available]
        ) == .available)
    }

    @Test func noDataAndFailureStatesRemainDistinct() {
        let preferences = ExternalMusicPreferences()
        #expect(resolve(preferences: preferences, statuses: [.musicBrainz: .disabled]) == .disabled)
        #expect(resolve(preferences: preferences, statuses: [.musicBrainz: .noData]) == .noData)
        #expect(resolve(preferences: preferences, statuses: [.musicBrainz: .failed]) == .failed)
        #expect(resolve(preferences: preferences, statuses: [.musicBrainz: .rateLimited]) == .rateLimited)
        #expect(resolve(preferences: preferences, statuses: [.musicBrainz: .unavailable]) == .unavailable)
    }

    @Test func aDisabledSourceDoesNotBecomeAvailableOrNoData() {
        let preferences = ExternalMusicPreferences(
            musicBrainzEnabled: true,
            critiqueBrainzEnabled: false,
            listenBrainzEnabled: false
        )
        #expect(resolve(
            preferences: preferences,
            statuses: [
                .musicBrainz: .noData,
                .critiqueBrainz: .available,
            ]
        ) == .noData)
    }

    private func resolve(
        preferences: ExternalMusicPreferences,
        statuses: [CommunityMusicSource: CommunityMetricStatus] = [:]
    ) -> ExternalMusicInformationViewState {
        let metrics = CommunityMusicMetrics(
            globalTrackID: globalID,
            values: statuses.map { source, status in
                CommunityMusicMetric(source: source, status: status)
            }
        )
        return ExternalMusicInformationViewState.resolve(
            preferences: preferences,
            isLoading: false,
            metrics: metrics
        )
    }
}
