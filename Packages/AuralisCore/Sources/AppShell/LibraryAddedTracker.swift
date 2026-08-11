import Domain
import Foundation
import LocalCatalog

/// Tracks the first time a song became visible in the local catalog.
///
/// Keys are always `GlobalID`, so equal remote IDs from different servers never
/// share a timestamp. Updating a server uses a `Set` of current IDs, keeping the
/// cleanup pass linear instead of repeatedly scanning the complete track array.
struct LibraryAddedTracker: Sendable {
    private(set) var dates: [GlobalID: Date]
    /// Bare remote IDs written by pre-GlobalID builds. If startup happens
    /// before a server is selected, retain these until reconciliation provides
    /// the only namespace in which they can be migrated safely.
    private var deferredLegacyDates: [String: Date]

    init(stored: [String: Double], legacyServerID: ServerID?) {
        var restored: [GlobalID: Date] = [:]
        var deferredLegacy: [String: Date] = [:]
        restored.reserveCapacity(stored.count)
        for (key, timestamp) in stored {
            if let globalID = GlobalID(key) {
                restored[globalID] = Date(timeIntervalSince1970: timestamp)
            } else if let legacyServerID, !key.isEmpty {
                // One-time migration from the old bare TrackID format. The last
                // active server is the only server provenance available.
                restored[GlobalID(serverID: legacyServerID, remoteID: key)] = Date(timeIntervalSince1970: timestamp)
            } else if !key.isEmpty {
                deferredLegacy[key] = Date(timeIntervalSince1970: timestamp)
            }
        }
        dates = restored
        deferredLegacyDates = deferredLegacy
    }

    mutating func reconcile(
        tracks: [Track],
        serverID: ServerID,
        now: Date = .now
    ) -> Bool {
        let previousDates = dates
        let hadDeferredLegacyDates = !deferredLegacyDates.isEmpty
        let validIDs = Set(tracks.map { GlobalID(serverID: serverID, remoteID: $0.id.rawValue) })
        var next = dates.filter { globalID, _ in
            globalID.serverID != serverID || validIDs.contains(globalID)
        }
        next.reserveCapacity(max(next.count, dates.count + tracks.count))
        for globalID in validIDs where next[globalID] == nil {
            next[globalID] = deferredLegacyDates[globalID.remoteID] ?? now
        }
        deferredLegacyDates.removeAll(keepingCapacity: false)
        guard next != previousDates || hadDeferredLegacyDates else { return false }
        dates = next
        return true
    }

    func date(for track: Track) -> Date? {
        dates[GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)]
    }

    var encoded: [String: Double] {
        var result = dates.reduce(into: [String: Double]()) { result, entry in
            result[entry.key.description] = entry.value.timeIntervalSince1970
        }
        for (remoteID, date) in deferredLegacyDates where result[remoteID] == nil {
            result[remoteID] = date.timeIntervalSince1970
        }
        return result
    }
}
