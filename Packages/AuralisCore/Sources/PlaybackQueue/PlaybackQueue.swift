import Domain
import Foundation

public struct QueueSnapshot: Codable, Hashable, Sendable {
    public var tracks: [Track]
    public var currentIndex: Int?

    public init(tracks: [Track] = [], currentIndex: Int? = nil) {
        self.tracks = tracks
        self.currentIndex = currentIndex
    }

    public var current: Track? {
        guard let currentIndex, tracks.indices.contains(currentIndex) else { return nil }
        return tracks[currentIndex]
    }
}

public actor PlaybackQueueStore {
    private var snapshot: QueueSnapshot

    public init(snapshot: QueueSnapshot = .init()) {
        self.snapshot = snapshot
    }

    public func value() -> QueueSnapshot { snapshot }

    public func replace(with tracks: [Track], startingAt index: Int = 0) {
        snapshot.tracks = tracks
        snapshot.currentIndex = tracks.isEmpty ? nil : min(max(index, 0), tracks.count - 1)
    }

    public func append(_ tracks: [Track]) {
        snapshot.tracks.append(contentsOf: tracks)
        if snapshot.currentIndex == nil, !snapshot.tracks.isEmpty { snapshot.currentIndex = 0 }
    }

    public func playNext(_ track: Track) {
        let insertion = min((snapshot.currentIndex ?? -1) + 1, snapshot.tracks.count)
        snapshot.tracks.insert(track, at: insertion)
        if snapshot.currentIndex == nil { snapshot.currentIndex = 0 }
    }

    public func advance() -> Track? {
        guard let index = snapshot.currentIndex else { return nil }
        let next = index + 1
        guard snapshot.tracks.indices.contains(next) else { return nil }
        snapshot.currentIndex = next
        return snapshot.tracks[next]
    }

    public func move(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().compactMap { snapshot.tracks.indices.contains($0) ? snapshot.tracks[$0] : nil }
        guard !moving.isEmpty else { return }
        let currentID = snapshot.current?.id
        let movingIDs = Set(moving.map(\.id))
        snapshot.tracks.removeAll { movingIDs.contains($0.id) }
        let insertion = min(max(0, destination - offsets.filter { $0 < destination }.count), snapshot.tracks.count)
        snapshot.tracks.insert(contentsOf: moving, at: insertion)
        if let currentID, let newIndex = snapshot.tracks.firstIndex(where: { $0.id == currentID }) {
            snapshot.currentIndex = newIndex
        }
    }

    @discardableResult
    public func remove(id: TrackID) -> Bool {
        guard let index = snapshot.tracks.firstIndex(where: { $0.id == id }) else { return false }
        let wasCurrent = index == snapshot.currentIndex
        snapshot.tracks.remove(at: index)
        if snapshot.tracks.isEmpty {
            snapshot.currentIndex = nil
        } else if wasCurrent {
            snapshot.currentIndex = min(index, snapshot.tracks.count - 1)
        } else if let currentIndex = snapshot.currentIndex, index < currentIndex {
            snapshot.currentIndex = currentIndex - 1
        }
        return true
    }
}
