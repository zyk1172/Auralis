@testable import AppShell
import Application
import Combine
import Domain
import Foundation
import Testing

private struct PlaybackStoreTestConnector: ServerConnecting {
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw CancellationError()
    }

    func restoreLastConnection() async throws -> ServerConnectionResult? { nil }
}

@Test("播放进度只发布到 PlaybackStore，不再让全局 AppModel 重绘")
@MainActor
func playbackPositionPublishingIsLocallyScoped() {
    let defaults = UserDefaults(suiteName: "playback-store-\(UUID().uuidString)")!
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("playback-store-\(UUID().uuidString).sqlite")
    let model = AuralisAppModel(
        connector: PlaybackStoreTestConnector(),
        defaults: defaults,
        storeURL: storeURL
    )
    var globalChanges = 0
    var playbackChanges = 0
    let globalSubscription = model.objectWillChange.sink { globalChanges += 1 }
    let playbackSubscription = model.playbackStore.objectWillChange.sink { playbackChanges += 1 }

    model.playbackPosition = 12

    #expect(model.playbackPosition == 12)
    #expect(globalChanges == 0)
    #expect(playbackChanges == 1)
    withExtendedLifetime((globalSubscription, playbackSubscription)) {}
}
