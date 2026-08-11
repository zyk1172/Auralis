@testable import AppShell
import Domain
import LocalCatalog
import Testing

@Test("点选不计播放，开始后进入最近，达到阈值只计一次")
func playbackHistoryQualification() {
    let globalID = GlobalID(serverID: "server", remoteID: "song")
    var store = PlaybackHistoryStore(counts: [:], recentKeys: [])

    store.resetSelection()
    #expect(store.counts.isEmpty)
    #expect(store.recentKeys.isEmpty)

    let didStart = store.markStarted(globalID)
    #expect(didStart)
    #expect(store.recentKeys == ["server:song"])
    let qualifiedTooEarly = store.qualifyIfNeeded(globalID: globalID, position: 10, duration: 120)
    let qualifiedAtThreshold = store.qualifyIfNeeded(globalID: globalID, position: 30, duration: 120)
    #expect(!qualifiedTooEarly)
    #expect(qualifiedAtThreshold)
    #expect(store.counts["server:song"] == 1)
    let qualifiedTwice = store.qualifyIfNeeded(globalID: globalID, position: 90, duration: 120)
    #expect(!qualifiedTwice)
    #expect(store.counts["server:song"] == 1)
}

@Test("短曲播放到一半即可计数并按服务器隔离")
func shortPlaybackQualifiesAtHalf() {
    let first = GlobalID(serverID: "one", remoteID: "same")
    let second = GlobalID(serverID: "two", remoteID: "same")
    var store = PlaybackHistoryStore(counts: [:], recentKeys: [])

    _ = store.markStarted(first)
    let firstQualified = store.qualifyIfNeeded(globalID: first, position: 5, duration: 10)
    #expect(firstQualified)
    store.resetSelection()
    _ = store.markStarted(second)
    let secondQualified = store.qualifyIfNeeded(globalID: second, position: 5, duration: 10)
    #expect(secondQualified)

    #expect(store.counts(for: "one")["same"] == 1)
    #expect(store.counts(for: "two")["same"] == 1)
}
