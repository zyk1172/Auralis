@testable import AppShell
import Domain
import Foundation
import LocalCatalog
import Testing

/// R05 回归：队列当前项以 entry UUID 为权威身份（index-based）。
/// 重复歌曲 [A, B, A, C] 播放第二个 A 时，currentIndex 必须停留在 2，
/// 不得从歌曲 TrackID 反推回第一个匹配（index 0）。
@MainActor
struct PlaybackQueuePresentationStoreTests {
    private let serverID = ServerID(rawValue: "srv")

    private func track(_ id: String) -> Track {
        Track(
            id: TrackID(rawValue: id),
            serverID: serverID,
            albumID: AlbumID(rawValue: "album-\(id)"),
            artistID: ArtistID(rawValue: "artist"),
            title: id,
            artistName: "Artist",
            albumTitle: "Album",
            duration: 180
        )
    }

    private func gid(_ id: String) -> GlobalID {
        GlobalID(serverID: serverID, remoteID: id)
    }

    @Test("重复歌曲：play(entryID:) 播第二个 A，advanceForward 正确走到 C（下标不漂移）")
    func advanceFromSecondDuplicateIsIndexBased() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("A"), track("C")], currentTrackID: gid("A"))

        // 用户点击队列中的第二个 A（index 2）——按 entry UUID 定位。
        let secondAEntryID = store.entries[2].id
        let played = store.play(entryID: secondAEntryID)
        #expect(played?.id.rawValue == "A")
        #expect(store.currentIndex == 2)
        #expect(store.currentEntryID == secondAEntryID)

        // next() 语义：advanceForward 走到 C（index 3），而不是回退到 B（index 1）。
        let next = store.advanceForward()
        #expect(next?.id.rawValue == "C")
        #expect(store.currentIndex == 3)
        #expect(store.currentEntryID == store.entries[3].id)

        // 播放引擎确认 currentTrack = C 后 updateCurrentIndex 不得把下标拉回第一个 A。
        store.updateCurrentIndex(currentTrackID: gid("C"))
        #expect(store.currentIndex == 3)
    }

    @Test("currentEntryID 失效（队列替换）时回退按 GlobalID 匹配第一个")
    func updateCurrentIndexFallsBackWhenEntryGone() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("A"), track("C")], currentTrackID: gid("A"))

        // 当前播第二个 A（index 2）。
        _ = store.play(entryID: store.entries[2].id)
        #expect(store.currentIndex == 2)

        // 队列被整体替换（如播放新歌单）：entry UUID 全部重建 → currentEntryID 失效，
        // updateCurrentIndex 回退到第一个匹配（显式点歌语义）。
        store.replace([track("A"), track("B")], currentTrackID: gid("A"))
        #expect(store.currentIndex == 0)
        #expect(store.currentEntryID == store.entries[0].id)
    }

    @Test("currentEntryID 指向的 entry 与当前歌匹配时保持下标（next 已显式推进）")
    func updateCurrentIndexKeepsPositionWhenEntryMatches() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("A")], currentTrackID: gid("A"))
        _ = store.play(entryID: store.entries[2].id)
        #expect(store.currentIndex == 2)

        // 同一首歌的元数据刷新（toggleFavorite 等）也会走 currentTrack setter：
        // currentEntryID 指向的歌仍是当前歌 → 下标保持 2，不漂移到 0。
        store.updateCurrentIndex(currentTrackID: gid("A"))
        #expect(store.currentIndex == 2)
        #expect(store.currentEntryID == store.entries[2].id)
    }

    @Test("remove 删除当前 entry 后回退到剩余队列中第一个匹配项")
    func removeCurrentEntryFallsBackSensibly() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("A"), track("C")], currentTrackID: gid("A"))
        _ = store.play(entryID: store.entries[2].id)
        #expect(store.currentIndex == 2)

        // 删除正在播放的第二个 A → [A, B, C]，当前歌 A 回退到剩余第一个 A（index 0）。
        _ = store.remove(entryID: store.entries[2].id, currentTrackID: gid("A"))
        #expect(store.entries.map(\.track.id.rawValue) == ["A", "B", "C"])
        #expect(store.currentIndex == 0)
        #expect(store.currentEntryID == store.entries[0].id)
    }

    @Test("advanceBackward 从第二个 A 回退到 B（index 1）")
    func advanceBackwardFromDuplicateUsesIndex() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("A"), track("C")], currentTrackID: gid("A"))
        _ = store.play(entryID: store.entries[2].id)

        let previous = store.advanceBackward()
        #expect(previous?.id.rawValue == "B")
        #expect(store.currentIndex == 1)
    }

    @Test("shuffleRemaining 在 entry 层面 shuffle：当前项 entryID 与下标保持")
    func shuffleRemainingKeepsCurrentEntry() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("A"), track("C"), track("D")], currentTrackID: gid("A"))
        _ = store.play(entryID: store.entries[2].id)
        let currentID = store.currentEntryID
        #expect(store.currentIndex == 2)

        // 模拟 AppModel.shuffleRemainingInQueue：head 保留 entry（含当前项），tail 打乱。
        let head = Array(store.entries.prefix(store.currentIndex! + 1))
        let tail = Array(store.entries.suffix(2)).shuffled()
        store.replace(entries: head + tail, currentTrackID: gid("A"))

        #expect(store.currentEntryID == currentID)
        #expect(store.currentIndex == 2)
    }
}
