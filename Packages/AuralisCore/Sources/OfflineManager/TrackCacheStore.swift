// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Foundation

/// App-managed local music downloads. Existing remote cache IDs remain valid aliases while every
/// completed server download also receives a deterministic canonical local TrackID.
public actor TrackCacheStore {
    public struct TrackCacheID: Hashable, Sendable, CustomStringConvertible {
        public let serverID: ServerID
        public let trackID: TrackID

        public init(serverID: ServerID, trackID: TrackID) {
            self.serverID = serverID
            self.trackID = trackID
        }

        public var description: String { "\(serverID.rawValue):\(trackID.rawValue)" }
    }

    public struct CachedTrackEntry: Hashable, Sendable, Identifiable {
        public var id: TrackCacheID { cacheID }
        public let cacheID: TrackCacheID
        public let byteCount: Int64
        public let modifiedAt: Date

        public init(cacheID: TrackCacheID, byteCount: Int64, modifiedAt: Date) {
            self.cacheID = cacheID
            self.byteCount = byteCount
            self.modifiedAt = modifiedAt
        }
    }

    public struct PromotedTrackEntry: Hashable, Sendable {
        public let cacheID: TrackCacheID
        public let localTrackID: TrackID
        public let fileURL: URL
    }

    public static let downloadsLibraryID = LocalLibraryID(rawValue: "downloads")
    public static let localNamespace = ServerID(rawValue: "auralis-local")

    private static let managedPackagePrefix = "managed-package:"
    private let directory: URL
    private let indexURL: URL
    private let promotionsURL: URL
    /// Remote GlobalID description -> legacy relative cache filename, or managed-package:absolute path.
    private var index: [String: String] = [:]
    /// Remote GlobalID description -> canonical local TrackID.
    private var promotions: [String: String] = [:]

    public init(directory: URL? = nil) {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let base: URL
        if let directory {
            base = directory
        } else {
            let localRoot = support.appendingPathComponent("Auralis/LocalMusic", isDirectory: true)
            let downloads = localRoot.appendingPathComponent("Downloads", isDirectory: true)
            let legacy = support.appendingPathComponent("Auralis/TrackCache", isDirectory: true)
            if !manager.fileExists(atPath: downloads.path), manager.fileExists(atPath: legacy.path) {
                try? manager.createDirectory(at: localRoot, withIntermediateDirectories: true)
                try? manager.moveItem(at: legacy, to: downloads)
            }
            base = downloads
        }
        self.directory = base
        self.indexURL = base.appendingPathComponent("index.json")
        self.promotionsURL = base.appendingPathComponent("identity-promotions.json")
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            index = decoded
        } else if manager.fileExists(atPath: indexURL.path) {
            index = [:]
            if let migrated = try? JSONEncoder().encode([String: String]()) {
                try? migrated.write(to: indexURL, options: .atomic)
            }
        }
        if let data = try? Data(contentsOf: promotionsURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            promotions = decoded
        }
    }

    public func migrateLegacyEntries(to serverID: ServerID) {
        let legacyKeys = index.keys.filter { !$0.contains(":") }
        guard !legacyKeys.isEmpty else { return }
        for remoteID in legacyKeys {
            let globalKey = TrackCacheID(
                serverID: serverID,
                trackID: TrackID(rawValue: remoteID)
            ).description
            if index[globalKey] == nil { index[globalKey] = index[remoteID] }
            index[remoteID] = nil
            promotions[globalKey] = Self.promotedTrackIDRaw(forGlobalKey: globalKey)
        }
        try? persistIndex()
        try? persistPromotions()
    }

    public func cachedFileURL(for id: TrackCacheID) -> URL? {
        guard let location = index[id.description] else { return nil }
        let url = fileURL(forStoredLocation: location)
        guard FileManager.default.fileExists(atPath: url.path) else {
            index[id.description] = nil
            promotions[id.description] = nil
            try? persistIndex()
            try? persistPromotions()
            return nil
        }
        return url
    }

    public func isCached(_ id: TrackCacheID) -> Bool {
        cachedFileURL(for: id) != nil
    }

    public func isStoredInManagedPackage(_ id: TrackCacheID) -> Bool {
        index[id.description]?.hasPrefix(Self.managedPackagePrefix) == true
    }

    public func cachedTrackIDs() -> Set<TrackCacheID> {
        Set(cachedEntries().map(\.cacheID))
    }

    public func cachedEntries() -> [CachedTrackEntry] {
        backfillPromotionsIfNeeded()
        var result: [CachedTrackEntry] = []
        var staleKeys: [String] = []
        for (key, location) in index {
            guard let cacheID = Self.cacheID(from: key) else { continue }
            let url = fileURL(forStoredLocation: location)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let fileSize = values.fileSize else {
                staleKeys.append(key)
                continue
            }
            result.append(CachedTrackEntry(
                cacheID: cacheID,
                byteCount: Int64(fileSize),
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        if !staleKeys.isEmpty {
            for key in staleKeys {
                index[key] = nil
                promotions[key] = nil
            }
            try? persistIndex()
            try? persistPromotions()
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func store(data: Data, for id: TrackCacheID, codec: String?) throws -> URL {
        guard !data.isEmpty else { throw TrackCacheError.emptyFile }
        try ensureDirectory()
        let name = Self.uniqueFileName(id: id, codec: codec)
        let url = directory.appendingPathComponent(name)
        let previousLocation = index[id.description]
        let previousPromotion = promotions[id.description]
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        index[id.description] = name
        promotions[id.description] = Self.promotedTrackIDRaw(forGlobalKey: id.description)
        do {
            try persistIndex()
            try persistPromotions()
        } catch {
            index[id.description] = previousLocation
            promotions[id.description] = previousPromotion
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        removeReplacedLocation(previousLocation, keeping: name)
        return url
    }

    public func moveDownloadedFile(at sourceURL: URL, for id: TrackCacheID, codec: String?) throws -> URL {
        let sourceSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard sourceSize > 0 else { throw TrackCacheError.emptyFile }
        try ensureDirectory()
        let name = Self.uniqueFileName(id: id, codec: codec)
        let destination = directory.appendingPathComponent(name)
        let previousLocation = index[id.description]
        let previousPromotion = promotions[id.description]
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        index[id.description] = name
        promotions[id.description] = Self.promotedTrackIDRaw(forGlobalKey: id.description)
        do {
            try persistIndex()
            try persistPromotions()
        } catch {
            index[id.description] = previousLocation
            promotions[id.description] = previousPromotion
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        removeReplacedLocation(previousLocation, keeping: name)
        return destination
    }

    /// Moves an already cached download into its Files-visible one-song package without creating a
    /// second audio copy. The index keeps an explicit managed-package absolute path so playback,
    /// download status and deletion continue to use the same TrackCacheStore APIs.
    @discardableResult
    public func relocateCachedFile(
        for id: TrackCacheID,
        toManagedPackageAudioURL destination: URL
    ) throws -> URL {
        guard let previousLocation = index[id.description] else { throw TrackCacheError.missingFile }
        let source = fileURL(forStoredLocation: previousLocation)
        guard FileManager.default.fileExists(atPath: source.path) else { throw TrackCacheError.missingFile }

        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newLocation = Self.managedPackagePrefix + destination.path
        if source.standardizedFileURL == destination.standardizedFileURL {
            index[id.description] = newLocation
            try persistIndex()
            return destination
        }

        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: source, to: destination)
        index[id.description] = newLocation
        do {
            try persistIndex()
        } catch {
            index[id.description] = previousLocation
            try? manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.moveItem(at: destination, to: source)
            throw error
        }

        if previousLocation.hasPrefix(Self.managedPackagePrefix) {
            let oldFolder = source.deletingLastPathComponent()
            let newFolder = destination.deletingLastPathComponent()
            if oldFolder.standardizedFileURL != newFolder.standardizedFileURL {
                try? manager.removeItem(at: oldFolder)
            }
        }
        return destination
    }

    public func remove(for id: TrackCacheID) throws {
        guard let location = index[id.description] else { return }
        try removeStoredLocation(location)
        let previousLocation = index[id.description]
        let previousPromotion = promotions[id.description]
        index[id.description] = nil
        promotions[id.description] = nil
        do {
            try persistIndex()
            try persistPromotions()
        } catch {
            index[id.description] = previousLocation
            promotions[id.description] = previousPromotion
            throw error
        }
    }

    public func removeAll(forServer serverID: ServerID) {
        let prefix = serverID.rawValue + ":"
        let keys = index.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        for key in keys {
            if let location = index[key] { try? removeStoredLocation(location) }
            index[key] = nil
            promotions[key] = nil
        }
        try? persistIndex()
        try? persistPromotions()
    }

    public func removeAll() throws {
        let previousIndex = index
        let previousPromotions = promotions
        for location in Set(index.values) {
            try? removeStoredLocation(location)
        }
        index = [:]
        promotions = [:]
        do {
            try persistIndex()
            try persistPromotions()
        } catch {
            index = previousIndex
            promotions = previousPromotions
            throw error
        }
    }

    public func promotedEntries() -> [PromotedTrackEntry] {
        backfillPromotionsIfNeeded()
        return promotions.compactMap { key, localID in
            guard let cacheID = Self.cacheID(from: key), let location = index[key] else { return nil }
            let url = fileURL(forStoredLocation: location)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return PromotedTrackEntry(
                cacheID: cacheID,
                localTrackID: TrackID(rawValue: localID),
                fileURL: url
            )
        }.sorted { $0.localTrackID.rawValue < $1.localTrackID.rawValue }
    }

    public func canonicalLocalTrackID(for remote: TrackCacheID) -> TrackID? {
        backfillPromotionsIfNeeded()
        return promotions[remote.description].map(TrackID.init(rawValue:))
    }

    public func identityTransition(for remote: TrackCacheID) -> TrackIdentityTransition? {
        guard let localTrackID = canonicalLocalTrackID(for: remote) else { return nil }
        return TrackIdentityTransition(
            remoteServerID: remote.serverID,
            remoteTrackID: remote.trackID,
            localLibraryID: Self.downloadsLibraryID,
            localTrackID: localTrackID
        )
    }

    public func totalBytes() -> Int64 {
        cachedEntries().reduce(into: Int64(0)) { $0 += $1.byteCount }
    }

    private func backfillPromotionsIfNeeded() {
        var changed = false
        for key in index.keys {
            guard Self.cacheID(from: key) != nil, promotions[key] == nil else { continue }
            promotions[key] = Self.promotedTrackIDRaw(forGlobalKey: key)
            changed = true
        }
        if changed { try? persistPromotions() }
    }

    private func persistIndex() throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func persistPromotions() throws {
        let data = try JSONEncoder().encode(promotions)
        try data.write(to: promotionsURL, options: .atomic)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(forStoredLocation location: String) -> URL {
        if location.hasPrefix(Self.managedPackagePrefix) {
            return URL(fileURLWithPath: String(location.dropFirst(Self.managedPackagePrefix.count)))
        }
        return directory.appendingPathComponent(location)
    }

    private func removeStoredLocation(_ location: String) throws {
        let manager = FileManager.default
        let url = fileURL(forStoredLocation: location)
        guard manager.fileExists(atPath: url.path) else { return }
        if location.hasPrefix(Self.managedPackagePrefix) {
            try manager.removeItem(at: url.deletingLastPathComponent())
        } else {
            try manager.removeItem(at: url)
        }
    }

    private func removeReplacedLocation(_ previousLocation: String?, keeping currentLocation: String) {
        guard let previousLocation, previousLocation != currentLocation else { return }
        try? removeStoredLocation(previousLocation)
    }

    private static func cacheID(from description: String) -> TrackCacheID? {
        guard let separator = description.firstIndex(of: ":") else { return nil }
        return TrackCacheID(
            serverID: ServerID(rawValue: String(description[..<separator])),
            trackID: TrackID(rawValue: String(description[description.index(after: separator)...]))
        )
    }

    private static func promotedTrackIDRaw(forGlobalKey key: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "local-download-\(String(hash, radix: 16))"
    }

    private static func uniqueFileName(id: TrackCacheID, codec: String?) -> String {
        let readable = id.trackID.rawValue.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
            .prefix(32)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.description.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(readable)-\(String(hash, radix: 16))-\(UUID().uuidString).\(fileExtension(codec: codec))"
    }

    private static func fileExtension(codec: String?) -> String {
        switch codec?.lowercased() {
        case "flac": return "flac"
        case "aac", "m4a": return "m4a"
        case "ogg", "opus": return "ogg"
        case "wav": return "wav"
        case "aiff", "aif": return "aiff"
        case "alac": return "m4a"
        default: return "mp3"
        }
    }
}

public enum TrackCacheError: Error, Equatable, Sendable {
    case emptyFile
    case missingFile
}
