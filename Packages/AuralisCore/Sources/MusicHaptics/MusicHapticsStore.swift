import Foundation

/// Actor-owned manifest keeps cache decisions O(1); normal playback never scans directories.
public actor MusicHapticsStore {
    public static let transientLimitBytes: Int64 = 200 * 1024 * 1024

    private enum Tier: String, Codable { case transient, favorite }

    private struct Entry: Codable {
        var key: String
        var identity: MusicHapticsIdentity
        var filename: String
        var tier: Tier
        var byteCount: Int64
        var createdAt: Date
        var lastAccessedAt: Date
        var orphanedAt: Date?
    }

    private struct PartialEntry: Codable {
        var key: String
        var identity: MusicHapticsIdentity
        var filename: String
        var byteCount: Int64
        var updatedAt: Date
    }

    private struct Manifest: Codable {
        var entries: [String: Entry] = [:]
        var preferences: [String: TrackHapticsPreference] = [:]
        var partials: [String: PartialEntry] = [:]

        private enum CodingKeys: String, CodingKey {
            case entries, preferences, partials
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entries = try container.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
            preferences = try container.decodeIfPresent([String: TrackHapticsPreference].self, forKey: .preferences) ?? [:]
            // Older releases had no partial checkpoint section.
            partials = try container.decodeIfPresent([String: PartialEntry].self, forKey: .partials) ?? [:]
        }
    }

    private let fm: FileManager
    private let transientDirectory: URL
    private let partialDirectory: URL
    private let favoriteDirectory: URL
    private let manifestURL: URL
    private var manifest = Manifest()
    private var prepared = false

    public init(fileManager: FileManager = .default, root: URL? = nil) {
        fm = fileManager
        let cacheBase = root ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let supportBase = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        transientDirectory = cacheBase.appendingPathComponent("Auralis/MusicHaptics", isDirectory: true)
        partialDirectory = cacheBase.appendingPathComponent("Auralis/MusicHaptics/Partials", isDirectory: true)
        let support = supportBase.appendingPathComponent("Auralis/MusicHaptics", isDirectory: true)
        favoriteDirectory = support.appendingPathComponent("Favorites", isDirectory: true)
        manifestURL = support.appendingPathComponent("manifest.json")
    }

    public func prepare() throws {
        guard !prepared else { return }
        try fm.createDirectory(at: transientDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: favoriteDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL) {
            manifest = (try? JSONDecoder().decode(Manifest.self, from: data)) ?? Manifest()
        }
        try removeTemporaryFiles(in: transientDirectory)
        try removeTemporaryFiles(in: partialDirectory)
        try removeTemporaryFiles(in: favoriteDirectory)
        manifest.entries = manifest.entries.filter { fm.fileExists(atPath: url(for: $0.value).path) }
        manifest.partials = manifest.partials.filter { fm.fileExists(atPath: partialURL(for: $0.value).path) }
        prepared = true
        try save()
    }

    public func timeline(for identity: MusicHapticsIdentity) throws -> MusicHapticsTimeline? {
        try prepare()
        guard var entry = bestEntry(for: identity), entry.orphanedAt == nil else { return nil }
        let timeline = try PropertyListDecoder().decode(
            MusicHapticsTimeline.self,
            from: Data(contentsOf: url(for: entry))
        )
        guard timeline.isComplete,
              timeline.algorithmVersion == MusicHapticsTimeline.algorithmVersion,
              timeline.identity.matchConfidence(with: identity) >= 0.82
        else { return nil }
        entry.lastAccessedAt = .now
        manifest.entries[entry.key] = entry
        try save()
        return timeline
    }

    /// Returns the last partial result for this recording, including holes in
    /// coverage. Incomplete checkpoints never qualify as a playback timeline.
    public func partial(for identity: MusicHapticsIdentity) throws -> MusicHapticsPartialCheckpoint? {
        try prepare()
        guard var entry = bestPartial(for: identity) else { return nil }
        let checkpoint = try PropertyListDecoder().decode(
            MusicHapticsPartialCheckpoint.self,
            from: Data(contentsOf: partialURL(for: entry))
        )
        guard checkpoint.formatVersion == MusicHapticsPartialCheckpoint.formatVersion,
              checkpoint.algorithmVersion == MusicHapticsTimeline.algorithmVersion,
              checkpoint.identity.matchConfidence(with: identity) >= 0.82,
              checkpoint.duration.isFinite,
              checkpoint.duration > 0
        else { return nil }
        entry.updatedAt = .now
        manifest.partials[entry.key] = entry
        try save()
        return checkpoint
    }

    public func store(_ timeline: MusicHapticsTimeline, favorite: Bool) throws {
        try prepare()
        guard timeline.isComplete,
              timeline.algorithmVersion == MusicHapticsTimeline.algorithmVersion
        else { return }
        let key = timeline.identity.stableKey
        let tier: Tier = favorite ? .favorite : .transient
        let filename = filename(for: key, suffix: "haptic")
        let destination = directory(for: tier).appendingPathComponent(filename)
        let temporary = destination.appendingPathExtension("tmp")
        let data = try PropertyListEncoder().encode(timeline)
        try data.write(to: temporary, options: .atomic)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
        if let old = manifest.entries[key], old.tier != tier { try? fm.removeItem(at: url(for: old)) }
        manifest.entries[key] = Entry(
            key: key,
            identity: timeline.identity,
            filename: filename,
            tier: tier,
            byteCount: Int64(data.count),
            createdAt: .now,
            lastAccessedAt: .now,
            orphanedAt: nil
        )
        removePartialLocked(for: timeline.identity)
        try evictTransientIfNeeded()
        try save()
    }

    /// Stores an incomplete result without promoting it to the playback tier.
    /// The file is replaced atomically so a process termination cannot leave a
    /// half-written checkpoint.
    public func storePartial(_ checkpoint: MusicHapticsPartialCheckpoint) throws {
        try prepare()
        guard checkpoint.algorithmVersion == MusicHapticsTimeline.algorithmVersion,
              checkpoint.duration.isFinite,
              checkpoint.duration > 0
        else { return }
        let key = checkpoint.identity.stableKey
        let checkpointToStore: MusicHapticsPartialCheckpoint
        if let existingEntry = manifest.partials[key],
           let existing = try? PropertyListDecoder().decode(
               MusicHapticsPartialCheckpoint.self,
               from: Data(contentsOf: partialURL(for: existingEntry))
           ),
           existing.formatVersion == MusicHapticsPartialCheckpoint.formatVersion,
           existing.algorithmVersion == checkpoint.algorithmVersion,
           existing.identity.matchConfidence(with: checkpoint.identity) >= 0.82 {
            checkpointToStore = existing.merged(with: checkpoint)
        } else {
            checkpointToStore = checkpoint
        }
        let filename = filename(for: key, suffix: "partial")
        let destination = partialDirectory.appendingPathComponent(filename)
        let temporary = destination.appendingPathExtension("tmp")
        let data = try PropertyListEncoder().encode(checkpointToStore)
        try data.write(to: temporary, options: .atomic)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
        manifest.partials[key] = PartialEntry(
            key: key,
            identity: checkpointToStore.identity,
            filename: filename,
            byteCount: Int64(data.count),
            updatedAt: checkpointToStore.updatedAt
        )
        try evictTransientIfNeeded()
        try save()
    }

    public func removePartial(for identity: MusicHapticsIdentity) throws {
        try prepare()
        removePartialLocked(for: identity)
        try save()
    }

    public func preference(for identity: MusicHapticsIdentity) throws -> TrackHapticsPreference {
        try prepare()
        return manifest.preferences[identity.stableKey] ?? .inherit
    }

    public func setPreference(_ value: TrackHapticsPreference, for identity: MusicHapticsIdentity) throws {
        try prepare()
        if value == .inherit {
            manifest.preferences.removeValue(forKey: identity.stableKey)
        } else {
            manifest.preferences[identity.stableKey] = value
        }
        try save()
    }

    public func updateFavorite(_ favorite: Bool, for identity: MusicHapticsIdentity) throws {
        try prepare()
        guard var entry = bestEntry(for: identity) else { return }
        let destinationTier: Tier = favorite ? .favorite : .transient
        guard entry.tier != destinationTier else { return }
        let destination = directory(for: destinationTier).appendingPathComponent(entry.filename)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: url(for: entry), to: destination)
        entry.tier = destinationTier
        entry.lastAccessedAt = .now
        manifest.entries[entry.key] = entry
        try evictTransientIfNeeded()
        try save()
    }

    public func usage() throws -> MusicHapticsUsage {
        try prepare()
        return MusicHapticsUsage(
            transientBytes: manifest.entries.values.filter { $0.tier == .transient }.reduce(0) { $0 + $1.byteCount }
                + manifest.partials.values.reduce(0) { $0 + $1.byteCount },
            favoriteBytes: manifest.entries.values.filter { $0.tier == .favorite }.reduce(0) { $0 + $1.byteCount }
        )
    }

    public func clearTransient() throws {
        try prepare()
        for entry in manifest.entries.values where entry.tier == .transient {
            try? fm.removeItem(at: url(for: entry))
        }
        for entry in manifest.partials.values {
            try? fm.removeItem(at: partialURL(for: entry))
        }
        manifest.entries = manifest.entries.filter { $0.value.tier != .transient }
        manifest.partials.removeAll()
        try save()
    }

    /// Call only after a successful authoritative catalog reconciliation; unreachable servers are a no-op.
    public func reconcile(with tracks: [MusicHapticsIdentity], authoritative: Bool, now: Date = .now) throws {
        try prepare()
        guard authoritative else { return }
        for (key, var entry) in manifest.entries {
            if tracks.contains(where: { entry.identity.matchConfidence(with: $0) >= 0.82 }) {
                entry.orphanedAt = nil
                manifest.entries[key] = entry
                continue
            }
            guard let orphanedAt = entry.orphanedAt else {
                entry.orphanedAt = now
                manifest.entries[key] = entry
                continue
            }
            let grace: TimeInterval = entry.tier == .favorite ? 30 * 86_400 : 7 * 86_400
            if now.timeIntervalSince(orphanedAt) >= grace {
                try? fm.removeItem(at: url(for: entry))
                manifest.entries.removeValue(forKey: key)
            }
        }
        // Iterate over a snapshot because stale checkpoints are removed from
        // the manifest inside this loop.
        for (key, entry) in Array(manifest.partials) {
            guard !tracks.contains(where: { entry.identity.matchConfidence(with: $0) >= 0.82 }) else { continue }
            if now.timeIntervalSince(entry.updatedAt) >= 7 * 86_400 {
                try? fm.removeItem(at: partialURL(for: entry))
                manifest.partials.removeValue(forKey: key)
            }
        }
        try save()
    }

    private func bestEntry(for identity: MusicHapticsIdentity) -> Entry? {
        manifest.entries.values.max {
            $0.identity.matchConfidence(with: identity) < $1.identity.matchConfidence(with: identity)
        }
    }

    private func bestPartial(for identity: MusicHapticsIdentity) -> PartialEntry? {
        manifest.partials.values.max {
            $0.identity.matchConfidence(with: identity) < $1.identity.matchConfidence(with: identity)
        }
    }

    private func removePartialLocked(for identity: MusicHapticsIdentity) {
        guard let entry = bestPartial(for: identity),
              entry.identity.matchConfidence(with: identity) >= 0.82
        else { return }
        try? fm.removeItem(at: partialURL(for: entry))
        manifest.partials.removeValue(forKey: entry.key)
    }

    private func directory(for tier: Tier) -> URL { tier == .transient ? transientDirectory : favoriteDirectory }
    private func url(for entry: Entry) -> URL { directory(for: entry.tier).appendingPathComponent(entry.filename) }
    private func partialURL(for entry: PartialEntry) -> URL { partialDirectory.appendingPathComponent(entry.filename) }

    private func filename(for key: String, suffix: String) -> String {
        Data(key.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
            + ".\(suffix)"
    }

    private func evictTransientIfNeeded() throws {
        var total = manifest.entries.values
            .filter { $0.tier == .transient }
            .reduce(Int64(0)) { $0 + $1.byteCount }
        for entry in manifest.entries.values
            .filter({ $0.tier == .transient })
            .sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt })
        where total > Self.transientLimitBytes {
            try? fm.removeItem(at: url(for: entry))
            manifest.entries.removeValue(forKey: entry.key)
            total -= entry.byteCount
        }

        var partialTotal = manifest.partials.values.reduce(Int64(0)) { $0 + $1.byteCount }
        for entry in manifest.partials.values.sorted(by: { $0.updatedAt < $1.updatedAt })
        where total + partialTotal > Self.transientLimitBytes {
            try? fm.removeItem(at: partialURL(for: entry))
            manifest.partials.removeValue(forKey: entry.key)
            partialTotal -= entry.byteCount
        }
    }

    private func removeTemporaryFiles(in directory: URL) throws {
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "tmp" {
            try? fm.removeItem(at: file)
        }
    }

    private func save() throws {
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }
}
