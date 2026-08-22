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

    // MARK: - R05 尾项：追加不漂移 + 保存/恢复 occurrence

    @Test("R05：队列 [A,B,A,C] 当前第二个 A，追加 D（Agent appendToQueue 直调）后 currentIndex 仍为 2")
    func appendWhileOnSecondDuplicateKeepsIndex() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("A"), track("C")], currentTrackID: gid("A"))
        _ = store.play(entryID: store.entries[2].id)
        #expect(store.currentIndex == 2)

        // AppModel.appendToQueue 的等价直调：queueStore.append，不重建 entry UUID。
        store.append([track("D")], currentTrackID: gid("A"))

        #expect(store.currentIndex == 2, "追加不得把当前项漂回第一个 A")
        #expect(store.currentEntryID == store.entries[2].id)
        let next = store.advanceForward()
        #expect(next?.id.rawValue == "C", "追加后下一首仍是 C")
    }

    @Test("R05：保存 currentQueueIndex → 重建队列恢复（等价重启/Handoff）→ 定位第二个 A → next 到 C")
    func restoreBySavedIndexKeepsOccurrence() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("A"), track("C")], currentTrackID: gid("A"))
        _ = store.play(entryID: store.entries[2].id)
        let savedIndex = store.currentIndex
        #expect(savedIndex == 2)

        // 模拟恢复：快照只存 trackIDs（无 UUID），重建全新 entry 队列。
        let restored = store.entries.map(\.track)
        store.replace(entries: restored.map { QueueEntry(track: $0) }, currentTrackID: gid("A"))
        // 此时 updateCurrentIndex 会匹配第一个 A（index 0）——必须用 savedIndex 覆盖。
        #expect(store.currentIndex == 0, "重建后默认回退到第一个 A")

        // 恢复代码：queueStore.play(entryID: entries[savedIndex].id) 精确定位。
        guard let savedIndex, store.entries.indices.contains(savedIndex) else {
            Issue.record("savedIndex 越界")
            return
        }
        let entry = store.entries[savedIndex]
        _ = store.play(entryID: entry.id)
        #expect(store.currentIndex == 2, "按保存下标恢复，指向第二个 A")

        // AppModel.currentTrack setter 的 updateCurrentIndex 不得覆盖已定位的下标。
        store.updateCurrentIndex(currentTrackID: gid("A"))
        #expect(store.currentIndex == 2)

        let next = store.advanceForward()
        #expect(next?.id.rawValue == "C", "恢复后 next() 必须走到 C，而不是 B")
    }

    @Test("R05：恢复时 savedIndex 优先于 currentTrackID 匹配（重复歌曲不漂回第一个）")
    func restorePrefersSavedIndexOverTrackIDMatch() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("A"), track("C")], currentTrackID: gid("A"))
        _ = store.play(entryID: store.entries[2].id)
        let savedIndex = store.currentIndex

        // 模拟 Handoff 恢复：新设备重建队列 + currentTrackID=A 同时存在。
        let restored = store.entries.map(\.track)
        store.replace(entries: restored.map { QueueEntry(track: $0) }, currentTrackID: gid("A"))
        guard let savedIndex, store.entries.indices.contains(savedIndex) else {
            Issue.record("savedIndex 越界")
            return
        }
        _ = store.play(entryID: store.entries[savedIndex].id)
        #expect(store.currentIndex == 2)

        // Handoff 的 currentTrack setter 路径（updateCurrentIndex）不得回退。
        store.updateCurrentIndex(currentTrackID: gid("A"))
        #expect(store.currentIndex == 2)
        let next = store.advanceForward()
        #expect(next?.id.rawValue == "C")
    }
}

// MARK: - P0：后台预构建队列 + persistence ID 一致性

extension PlaybackQueuePresentationStoreTests {
    @Test("prepare：10000 首去重后 entries/persistenceIDs 一致，selected index/entryID 正确")
    func prepareLargeQueueIsConsistent() {
        var tracks: [Track] = []
        tracks.reserveCapacity(10_000)
        for i in 0..<10_000 {
            tracks.append(track("T\(i)"))
        }
        let selected = gid("T5000")
        let prepared = PlaybackQueuePresentationStore.prepare(tracks: tracks, selectedTrackID: selected)

        #expect(prepared.entries.count == 10_000)
        #expect(prepared.persistenceTrackIDs.count == prepared.entries.count)
        #expect(prepared.currentIndex == 5000)
        #expect(prepared.currentEntryID == prepared.entries[5000].id)
        #expect(prepared.persistenceTrackIDs[5000] == "T5000")
    }

    @Test("prepare：保留重复歌曲，selected 定位第一次出现")
    func preparePreservesDuplicatesAndFindsFirst() {
        // [A, B, A, C] 保留每个队列 occurrence；selected A 定位到 index 0。
        let prepared = PlaybackQueuePresentationStore.prepare(
            tracks: [track("A"), track("B"), track("A"), track("C")],
            selectedTrackID: gid("A")
        )
        #expect(prepared.entries.map(\.track.id.rawValue) == ["A", "B", "A", "C"])
        #expect(prepared.persistenceTrackIDs == ["A", "B", "A", "C"])
        #expect(prepared.currentIndex == 0)
        #expect(prepared.currentEntryID == prepared.entries[0].id)
    }

    @Test("prepare：selected 不存在时 currentIndex nil")
    func prepareSelectedMissing() {
        let prepared = PlaybackQueuePresentationStore.prepare(
            tracks: [track("A"), track("B")],
            selectedTrackID: gid("Z")
        )
        #expect(prepared.currentIndex == nil)
        #expect(prepared.currentEntryID == nil)
    }

    @Test("installPreparedQueue：MainActor 仅安装，persistenceIDs 对齐，不额外扫描")
    func installPreparedQueueInstallsOnly() {
        let store = PlaybackQueuePresentationStore()
        let prepared = PlaybackQueuePresentationStore.prepare(
            tracks: [track("A"), track("B"), track("C")],
            selectedTrackID: gid("B")
        )
        store.installPreparedQueue(prepared)

        #expect(store.entries.count == 3)
        #expect(store.currentIndex == 1)
        #expect(store.currentEntryID == store.entries[1].id)
        #expect(store.persistenceTrackIDs == ["A", "B", "C"])
        #expect(store.persistenceTrackIDs.count == store.entries.count)
    }

    @Test("persistenceTrackIDs：replace/append/playNext/remove/removeUpcoming/move 全程与 entries 对齐")
    func persistenceIDsStayInSync() {
        let store = PlaybackQueuePresentationStore()

        // replace
        store.replace([track("A"), track("B"), track("C")], currentTrackID: gid("A"))
        assertPersistenceTracks(store, expected: ["A", "B", "C"])

        // append
        store.append([track("D")], currentTrackID: gid("A"))
        assertPersistenceTracks(store, expected: ["A", "B", "C", "D"])

        // playNext（插到当前 A 之后 → index1）
        store.playNext(track("X"), currentTrackID: gid("A"))
        assertPersistenceTracks(store, expected: ["A", "X", "B", "C", "D"])

        // remove（移除 B）
        if let bEntry = store.entries.first(where: { $0.track.id.rawValue == "B" }) {
            _ = store.remove(entryID: bEntry.id, currentTrackID: gid("A"))
        }
        assertPersistenceTracks(store, expected: ["A", "X", "C", "D"])

        // removeUpcoming（当前 A 之后全清）
        guard let idx = store.currentIndex else {
            Issue.record("no current index"); return
        }
        store.removeUpcoming(from: idx, currentTrackID: gid("A"))
        assertPersistenceTracks(store, expected: ["A"])

        // move（从 A 之后 [A,B] → 把 D 移到 index1）
        store.append([track("B"), track("D")], currentTrackID: gid("A"))
        assertPersistenceTracks(store, expected: ["A", "B", "D"])
        let dIndex = store.entries.firstIndex { $0.track.id.rawValue == "D" } ?? 0
        store.move(from: IndexSet(integer: dIndex), to: 1, currentTrackID: gid("A"))
        assertPersistenceTracks(store, expected: ["A", "D", "B"])
    }

    @Test("insertAtFront：当前歌曲直接落队首并定位 index 0，不动全队列")
    func insertAtFrontPlacesCurrentAtFront() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("B"), track("C")], currentTrackID: gid("B"))
        #expect(store.currentIndex == 0)

        // 播放更早的歌 X（不在队列）→ 落队首，成为 currentIndex 0。
        store.insertAtFront(track("X"), currentTrackID: gid("X"))
        #expect(store.entries.map(\.track.id.rawValue) == ["X", "B", "C"])
        #expect(store.currentIndex == 0)
        #expect(store.currentEntryID == store.entries[0].id)
        assertPersistenceTracks(store, expected: ["X", "B", "C"])
    }

    @Test("move：重复歌曲按 occurrence 移动，持久化 ID 不删除其它同名项")
    func movePreservesDuplicateOccurrences() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("A"), track("C")], currentTrackID: gid("A"))

        // 只移动第二个 A（index 2）到队首；第一个 A 必须仍在队列中。
        store.move(from: IndexSet(integer: 2), to: 0, currentTrackID: gid("A"))

        #expect(store.entries.map { $0.track.id.rawValue } == ["A", "A", "B", "C"])
        #expect(store.persistenceTrackIDs == ["A", "A", "B", "C"])
        #expect(store.persistenceTrackIDs.count == store.entries.count)
    }

    @Test("entries(after:) 返回 ArraySlice 且不复制全队列")
    func entriesAfterReturnsSlice() {
        let store = PlaybackQueuePresentationStore()
        store.replace([track("A"), track("B"), track("C")], currentTrackID: gid("B"))
        let slice = store.entries(after: store.currentIndex)
        #expect(Array(slice.map(\.track.id.rawValue)) == ["C"])
        // nil current → 全部
        let all = store.entries(after: nil)
        #expect(all.count == 3)
    }

    private func assertPersistenceTracks(_ store: PlaybackQueuePresentationStore, expected: [String]) {
        #expect(store.persistenceTrackIDs == expected, "persistenceTrackIDs mismatch: \(store.persistenceTrackIDs)")
        #expect(store.persistenceTrackIDs.count == store.entries.count, "count drift")
    }
}
