import Foundation

/// Actor-owned manifest keeps cache decisions O(1); normal playback never scans directories.
public actor MusicHapticsStore {
    public static let transientLimitBytes: Int64 = 200 * 1024 * 1024
    private enum Tier: String, Codable { case transient, favorite }
    private struct Entry: Codable {
        var key: String; var identity: MusicHapticsIdentity; var filename: String; var tier: Tier
        var byteCount: Int64; var createdAt: Date; var lastAccessedAt: Date; var orphanedAt: Date?
    }
    private struct Manifest: Codable { var entries: [String: Entry] = [:]; var preferences: [String: TrackHapticsPreference] = [:] }

    private let fm: FileManager
    private let transientDirectory: URL
    private let favoriteDirectory: URL
    private let manifestURL: URL
    private var manifest = Manifest()
    private var prepared = false

    public init(fileManager: FileManager = .default, root: URL? = nil) {
        fm = fileManager
        let cacheBase = root ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let supportBase = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        transientDirectory = cacheBase.appendingPathComponent("Auralis/MusicHaptics", isDirectory: true)
        let support = supportBase.appendingPathComponent("Auralis/MusicHaptics", isDirectory: true)
        favoriteDirectory = support.appendingPathComponent("Favorites", isDirectory: true)
        manifestURL = support.appendingPathComponent("manifest.json")
    }

    public func prepare() throws {
        guard !prepared else { return }
        try fm.createDirectory(at: transientDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: favoriteDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL) { manifest = (try? JSONDecoder().decode(Manifest.self, from: data)) ?? Manifest() }
        try removeTemporaryFiles(in: transientDirectory)
        try removeTemporaryFiles(in: favoriteDirectory)
        manifest.entries = manifest.entries.filter { fm.fileExists(atPath: url(for: $0.value).path) }
        prepared = true
        try save()
    }

    public func timeline(for identity: MusicHapticsIdentity) throws -> MusicHapticsTimeline? {
        try prepare()
        guard var entry = bestEntry(for: identity), entry.orphanedAt == nil else { return nil }
        let timeline = try PropertyListDecoder().decode(MusicHapticsTimeline.self, from: Data(contentsOf: url(for: entry)))
        guard timeline.isComplete, timeline.identity.matchConfidence(with: identity) >= 0.82 else { return nil }
        entry.lastAccessedAt = .now; manifest.entries[entry.key] = entry; try save()
        return timeline
    }

    public func store(_ timeline: MusicHapticsTimeline, favorite: Bool) throws {
        try prepare(); guard timeline.isComplete else { return }
        let key = timeline.identity.stableKey
        let tier: Tier = favorite ? .favorite : .transient
        let filename = filename(for: key)
        let destination = directory(for: tier).appendingPathComponent(filename)
        let temporary = destination.appendingPathExtension("tmp")
        let data = try PropertyListEncoder().encode(timeline)
        try data.write(to: temporary, options: .atomic)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
        if let old = manifest.entries[key], old.tier != tier { try? fm.removeItem(at: url(for: old)) }
        manifest.entries[key] = Entry(key: key, identity: timeline.identity, filename: filename, tier: tier, byteCount: Int64(data.count), createdAt: .now, lastAccessedAt: .now, orphanedAt: nil)
        try evictTransientIfNeeded(); try save()
    }

    public func preference(for identity: MusicHapticsIdentity) throws -> TrackHapticsPreference { try prepare(); return manifest.preferences[identity.stableKey] ?? .inherit }
    public func setPreference(_ value: TrackHapticsPreference, for identity: MusicHapticsIdentity) throws {
        try prepare(); if value == .inherit { manifest.preferences.removeValue(forKey: identity.stableKey) } else { manifest.preferences[identity.stableKey] = value }; try save()
    }

    public func updateFavorite(_ favorite: Bool, for identity: MusicHapticsIdentity) throws {
        try prepare(); guard var entry = bestEntry(for: identity) else { return }
        let destinationTier: Tier = favorite ? .favorite : .transient
        guard entry.tier != destinationTier else { return }
        let destination = directory(for: destinationTier).appendingPathComponent(entry.filename)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: url(for: entry), to: destination)
        entry.tier = destinationTier; entry.lastAccessedAt = .now; manifest.entries[entry.key] = entry
        try evictTransientIfNeeded(); try save()
    }

    public func usage() throws -> MusicHapticsUsage {
        try prepare()
        return MusicHapticsUsage(transientBytes: manifest.entries.values.filter { $0.tier == .transient }.reduce(0) { $0 + $1.byteCount }, favoriteBytes: manifest.entries.values.filter { $0.tier == .favorite }.reduce(0) { $0 + $1.byteCount })
    }

    public func clearTransient() throws {
        try prepare(); for entry in manifest.entries.values where entry.tier == .transient { try? fm.removeItem(at: url(for: entry)) }
        manifest.entries = manifest.entries.filter { $0.value.tier != .transient }; try save()
    }

    /// Call only after a successful authoritative catalog reconciliation; unreachable servers are a no-op.
    public func reconcile(with tracks: [MusicHapticsIdentity], authoritative: Bool, now: Date = .now) throws {
        try prepare(); guard authoritative else { return }
        for (key, var entry) in manifest.entries {
            if tracks.contains(where: { entry.identity.matchConfidence(with: $0) >= 0.82 }) { entry.orphanedAt = nil; manifest.entries[key] = entry; continue }
            guard let orphanedAt = entry.orphanedAt else { entry.orphanedAt = now; manifest.entries[key] = entry; continue }
            let grace: TimeInterval = entry.tier == .favorite ? 30 * 86_400 : 7 * 86_400
            if now.timeIntervalSince(orphanedAt) >= grace { try? fm.removeItem(at: url(for: entry)); manifest.entries.removeValue(forKey: key) }
        }
        try save()
    }

    private func bestEntry(for identity: MusicHapticsIdentity) -> Entry? { manifest.entries.values.max { $0.identity.matchConfidence(with: identity) < $1.identity.matchConfidence(with: identity) } }
    private func directory(for tier: Tier) -> URL { tier == .transient ? transientDirectory : favoriteDirectory }
    private func url(for entry: Entry) -> URL { directory(for: entry.tier).appendingPathComponent(entry.filename) }
    private func filename(for key: String) -> String { Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "") + ".haptic" }
    private func evictTransientIfNeeded() throws {
        var total = manifest.entries.values.filter { $0.tier == .transient }.reduce(Int64(0)) { $0 + $1.byteCount }
        for entry in manifest.entries.values.filter({ $0.tier == .transient }).sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) where total > Self.transientLimitBytes { try? fm.removeItem(at: url(for: entry)); manifest.entries.removeValue(forKey: entry.key); total -= entry.byteCount }
    }
    private func removeTemporaryFiles(in directory: URL) throws { for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "tmp" { try? fm.removeItem(at: file) } }
    private func save() throws { try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic) }
}
