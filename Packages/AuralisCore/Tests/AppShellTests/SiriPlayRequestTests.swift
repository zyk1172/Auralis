// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

/// Siri「播放音乐」回归测试。
///
/// 背景：Intents 扩展在 `mediaSearch` 为空时会返回一个占位媒体项
/// （`SiriMediaIdentifier.playAll`）。主 App 必须把它解释成「播放音乐」，
/// 而不是当成一首叫这个名字的歌，更不能静默丢弃请求——
/// 否则 Siri 侧表现为「识别到 Auralis、也调起了 App，但没有声音」。

private struct SiriRestoringConnector: ServerConnecting {
    let result: ServerConnectionResult
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult { result }
    func restoreLastConnection() async throws -> ServerConnectionResult? { result }
}

private func siriAccount() -> ServerAccount {
    ServerAccount(
        id: "test-server",
        displayName: "Test Library",
        baseURL: URL(string: "https://music.example.test")!,
        username: "listener",
        credentialReference: "cred"
    )
}

private func siriTrack(remoteID: String, title: String) -> Track {
    Track(
        id: TrackID(rawValue: remoteID),
        serverID: "test-server",
        albumID: AlbumID(rawValue: "\(remoteID)-album"),
        artistID: ArtistID(rawValue: "\(remoteID)-artist"),
        title: title,
        artistName: "Artist",
        albumTitle: "Album",
        duration: 200
    )
}

@MainActor
private func makeSiriModel(tracks: [Track]) -> AuralisAppModel {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-siri-tests")
        .appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "siri-tests-\(UUID().uuidString)")!
    return AuralisAppModel(
        connector: SiriRestoringConnector(
            result: ServerConnectionResult(
                account: siriAccount(),
                capabilities: .init(supportsStructuredLyrics: true),
                artists: [],
                albums: [],
                tracks: tracks,
                serverType: "test-server",
                serverVersion: "1.0"
            )
        ),
        defaults: defaults,
        storeURL: dir.appendingPathComponent("catalog.sqlite")
    )
}

@MainActor
private func waitFor(_ timeout: Int = 600, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<timeout {
        await Task.yield()
        if condition() { return true }
    }
    return condition()
}

@Test("占位标识不会被解析成精确曲目的 GlobalID")
func siriPlayAllIdentifierIsNotAGlobalID() {
    // 「服务器ID:歌曲ID」才是精确曲目标识；占位值不含冒号，
    // 一旦被 GlobalID 解析成功，主 App 会把它当成真实曲目去查库并静默失败。
    #expect(GlobalID(SiriMediaIdentifier.playAll) == nil)
}

@Test("Siri 只说「播放音乐」时会真的开始播放，而不是丢弃请求")
@MainActor
func siriPlayAllRequestStartsPlayback() async throws {
    let model = makeSiriModel(tracks: [siriTrack(remoteID: "remote-1", title: "First")])
    await model.restorePersistedLibrary()
    _ = await waitFor { model.catalog.tracks.count == 1 }

    model.enqueueSiriPlayAllRequest()
    model.processSiriPlayRequest()

    let started = await waitFor { model.currentTrack.id.rawValue == "remote-1" }
    #expect(started, "「播放音乐」请求没有把当前曲目切到资料库中的曲目")
}

@Test("资料库为空时「播放音乐」不会伪造播放状态")
@MainActor
func siriPlayAllRequestWithoutCatalogStaysIdle() async throws {
    let model = makeSiriModel(tracks: [])
    await model.restorePersistedLibrary()

    model.enqueueSiriPlayAllRequest()
    model.processSiriPlayRequest()
    try await Task.sleep(for: .milliseconds(200))

    #expect(model.currentTrack.id.rawValue == "placeholder")
    #expect(model.playbackState != .playing)
}
