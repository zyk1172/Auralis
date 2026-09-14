// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Combine
import Domain
import Foundation

/// Apple local-library runtime. It owns security-scoped roots and emits real `Track` values
/// that the existing AVFoundation player can consume without a parallel playback stack.
@MainActor
final class LocalMusicLibraryStore: ObservableObject {
    static let shared = LocalMusicLibraryStore()
    static let localServerID = ServerID(rawValue: "auralis-local")

    @Published private(set) var sources: [LocalMusicSource] = []
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var lastScan: LocalLibraryScanSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?

    private let sourcesURL: URL
    private var accessedRoots: [LocalLibraryID: URL] = [:]
    private static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ogg", "opus"
    ]

    init(directory: URL? = nil) {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let root = directory ?? support.appendingPathComponent("Auralis/LocalMusic", isDirectory: true)
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        sourcesURL = root.appendingPathComponent("sources.json")
        if let data = try? Data(contentsOf: sourcesURL),
           let decoded = try? JSONDecoder().decode([LocalMusicSource].self, from: data) {
            sources = decoded
        }
        restoreSecurityScopedRoots()
    }

    deinit {
        for url in accessedRoots.values {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func addSource(url: URL) async {
        do {
#if os(macOS)
            let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
#else
            // iOS document-picker URLs already carry security-scoped access;
            // the explicit bookmark option is unavailable on iOS.
            let bookmarkOptions: URL.BookmarkCreationOptions = []
#endif
            let data = try url.bookmarkData(
                options: bookmarkOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let token = data.base64EncodedString()
            let id = LocalLibraryID(rawValue: "folder-\(Self.fnv64(token))")
            if let old = accessedRoots[id] {
                old.stopAccessingSecurityScopedResource()
            }
            _ = url.startAccessingSecurityScopedResource()
            accessedRoots[id] = url
            let source = LocalMusicSource(
                id: id,
                displayName: url.lastPathComponent,
                locationToken: token
            )
            if let index = sources.firstIndex(where: { $0.id == id }) {
                sources[index] = source
            } else {
                sources.append(source)
            }
            try persistSources()
            _ = await scan(source: source)
        } catch {
            lastError = "无法保存本地音乐文件夹授权"
        }
    }

    func removeSource(_ source: LocalMusicSource) {
        if let root = accessedRoots.removeValue(forKey: source.id) {
            root.stopAccessingSecurityScopedResource()
        }
        sources.removeAll { $0.id == source.id }
        tracks.removeAll { Self.belongs($0, to: source.id) }
        try? persistSources()
    }

    @discardableResult
    func scanAll() async -> LocalLibraryScanSnapshot {
        isScanning = true
        lastError = nil
        defer { isScanning = false }
        var total = LocalLibraryScanSnapshot()
        for source in sources where source.isEnabled {
            let snapshot = await scan(source: source, manageState: false)
            total.discoveredFiles += snapshot.discoveredFiles
            total.importedTracks += snapshot.importedTracks
            total.updatedTracks += snapshot.updatedTracks
            total.removedTracks += snapshot.removedTracks
            total.failedFiles += snapshot.failedFiles
        }
        total.completedAt = .now
        lastScan = total
        return total
    }

    @discardableResult
    func scan(source: LocalMusicSource, manageState: Bool = true) async -> LocalLibraryScanSnapshot {
        if manageState {
            isScanning = true
            lastError = nil
        }
        defer {
            if manageState { isScanning = false }
        }
        guard let root = resolveRoot(source) else {
            lastError = "本地音乐文件夹授权已失效，请重新添加"
            return LocalLibraryScanSnapshot(failedFiles: 1)
        }

        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        var imported: [Track] = []
        var failed = 0
        var discovered = 0
        while let file = enumerator?.nextObject() as? URL {
            guard Self.supportedExtensions.contains(file.pathExtension.lowercased()) else { continue }
            discovered += 1
            if let track = await Self.makeTrack(file: file, source: source, root: root) {
                imported.append(track)
            } else {
                failed += 1
            }
        }

        let oldIDs = Set(tracks.filter { Self.belongs($0, to: source.id) }.map(\.id))
        let newIDs = Set(imported.map(\.id))
        tracks.removeAll { Self.belongs($0, to: source.id) }
        tracks.append(contentsOf: imported)
        let snapshot = LocalLibraryScanSnapshot(
            discoveredFiles: discovered,
            importedTracks: newIDs.subtracting(oldIDs).count,
            updatedTracks: newIDs.intersection(oldIDs).count,
            removedTracks: oldIDs.subtracting(newIDs).count,
            failedFiles: failed,
            completedAt: .now
        )
        lastScan = snapshot
        return snapshot
    }

    private func restoreSecurityScopedRoots() {
        for source in sources {
            _ = resolveRoot(source)
        }
    }

    private func resolveRoot(_ source: LocalMusicSource) -> URL? {
        if let existing = accessedRoots[source.id] {
            return existing
        }
        guard let data = Data(base64Encoded: source.locationToken) else { return nil }
        var stale = false
#if os(macOS)
        let bookmarkOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
#else
        // iOS does not expose the security-scope resolution flag. The resolved
        // document URL is still activated below before it is scanned.
        let bookmarkOptions: URL.BookmarkResolutionOptions = [.withoutUI]
#endif
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: bookmarkOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        accessedRoots[source.id] = url
        return url
    }

    private func persistSources() throws {
        try JSONEncoder().encode(sources).write(to: sourcesURL, options: .atomic)
    }

    private static func belongs(_ track: Track, to sourceID: LocalLibraryID) -> Bool {
        track.id.rawValue.hasPrefix("local-file-\(fnv64(sourceID.rawValue))-")
    }

    private static func makeTrack(file: URL, source: LocalMusicSource, root: URL) async -> Track? {
        let asset = AVURLAsset(url: file)
        let durationTime = try? await asset.load(.duration)
        let duration = durationTime.map(CMTimeGetSeconds) ?? 0
        guard duration.isFinite, duration >= 0 else { return nil }
        let common = (try? await asset.load(.commonMetadata)) ?? []
        var title: String?
        var artist: String?
        var album: String?
        for item in common {
            let value = try? await item.load(.stringValue)
            switch item.commonKey?.rawValue {
            case "title": title = value
            case "artist": artist = value
            case "albumName": album = value
            default: break
            }
        }
        let relative = file.path.replacingOccurrences(of: root.path, with: "")
        let sourceHash = fnv64(source.id.rawValue)
        let fileHash = fnv64(relative)
        let artistName = artist?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "未知艺术家"
        let albumTitle = album?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "未知专辑"
        return Track(
            id: TrackID(rawValue: "local-file-\(sourceHash)-\(fileHash)"),
            serverID: localServerID,
            albumID: AlbumID(rawValue: "local-album-\(fnv64(artistName + "|" + albumTitle))"),
            artistID: ArtistID(rawValue: "local-artist-\(fnv64(artistName))"),
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? file.deletingPathExtension().lastPathComponent,
            artistName: artistName,
            albumTitle: albumTitle,
            duration: duration,
            sourceInfo: AudioSourceInfo(codec: file.pathExtension.lowercased()),
            streamURL: file
        )
    }

    private static func fnv64(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
