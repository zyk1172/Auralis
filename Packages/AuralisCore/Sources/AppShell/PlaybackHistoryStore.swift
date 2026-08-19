import Domain
import Foundation
import LocalCatalog

/// Owns local playback history and the per-play qualification state.
/// Selecting a row is not a play. A session enters recent history only after the
/// engine reports `.playing`, and its play count increases once after 30 seconds
/// or 50% of the track (whichever comes first).
struct PlaybackHistoryStore: Sendable {
    private(set) var counts: [String: Int]
    private(set) var recentKeys: [String]
    private var deferredLegacyCounts: [String: Int]
    private var deferredLegacyRecentKeys: [String]
    private var activeGlobalID: GlobalID?
    private var countedActivePlay = false

    init(counts: [String: Int], recentKeys: [String], legacyServerID: ServerID? = nil) {
        var migratedCounts: [String: Int] = [:]
        var deferredCounts: [String: Int] = [:]
        for (key, value) in counts {
            if GlobalID(key) != nil {
                migratedCounts[key] = value
            } else if let legacyServerID, !key.isEmpty {
                migratedCounts[GlobalID(serverID: legacyServerID, remoteID: key).description] = value
            } else if !key.isEmpty {
                deferredCounts[key] = value
            }
        }
        var migratedRecent: [String] = []
        var deferredRecent: [String] = []
        for key in recentKeys {
            if GlobalID(key) != nil {
                migratedRecent.append(key)
            } else if let legacyServerID, !key.isEmpty {
                migratedRecent.append(GlobalID(serverID: legacyServerID, remoteID: key).description)
            } else if !key.isEmpty {
                deferredRecent.append(key)
            }
        }
        self.counts = migratedCounts
        self.recentKeys = Array(Self.uniqued(migratedRecent).prefix(100))
        self.deferredLegacyCounts = deferredCounts
        self.deferredLegacyRecentKeys = deferredRecent
    }

    mutating func reconcileLegacy(serverID: ServerID) -> Bool {
        guard !deferredLegacyCounts.isEmpty || !deferredLegacyRecentKeys.isEmpty else { return false }
        for (remoteID, value) in deferredLegacyCounts {
            let key = GlobalID(serverID: serverID, remoteID: remoteID).description
            counts[key] = max(counts[key] ?? 0, value)
        }
        let migratedRecent = deferredLegacyRecentKeys.map {
            GlobalID(serverID: serverID, remoteID: $0).description
        }
        recentKeys = Array(Self.uniqued(migratedRecent + recentKeys).prefix(100))
        deferredLegacyCounts.removeAll()
        deferredLegacyRecentKeys.removeAll()
        return true
    }

    mutating func resetSelection() {
        activeGlobalID = nil
        countedActivePlay = false
    }

    @discardableResult
    mutating func markStarted(_ globalID: GlobalID) -> Bool {
        let isNewSession = activeGlobalID != globalID
        activeGlobalID = globalID
        if isNewSession { countedActivePlay = false }

        var seen = Set<String>()
        var next = recentKeys.filter { existing in
            existing != globalID.description && seen.insert(existing).inserted
        }
        next.insert(globalID.description, at: 0)
        if next.count > 100 { next.removeSubrange(100...) }
        guard next != recentKeys else { return false }
        recentKeys = next
        return true
    }

    @discardableResult
    mutating func qualifyIfNeeded(
        globalID: GlobalID,
        position: TimeInterval,
        duration: TimeInterval,
        force: Bool = false
    ) -> Bool {
        guard activeGlobalID == globalID, !countedActivePlay else { return false }
        let halfDuration = duration > 0 ? duration * 0.5 : 30
        let threshold = min(30, max(halfDuration, 1))
        guard force || position >= threshold else { return false }
        counts[globalID.description, default: 0] += 1
        countedActivePlay = true
        return true
    }

    func counts(for serverID: ServerID) -> [TrackID: Int] {
        let prefix = serverID.rawValue + ":"
        return Dictionary(uniqueKeysWithValues: counts.compactMap { key, count in
            guard key.hasPrefix(prefix) else { return nil }
            return (TrackID(rawValue: String(key.dropFirst(prefix.count))), count)
        })
    }

    func count(for globalID: GlobalID) -> Int {
        counts[globalID.description] ?? 0
    }

    func recentIDs(for serverID: ServerID) -> [TrackID] {
        recentKeys.compactMap { key in
            guard let globalID = GlobalID(key), globalID.serverID == serverID else { return nil }
            return TrackID(rawValue: globalID.remoteID)
        }
    }

    var encodedCounts: [String: Int] {
        counts.merging(deferredLegacyCounts) { current, _ in current }
    }

    var encodedRecentKeys: [String] {
        Self.uniqued(recentKeys + deferredLegacyRecentKeys)
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}