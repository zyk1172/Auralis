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
    static let localServerID = LocalCatalogOverlay.localServerID
    static let managedSourceID = LocalLibraryID(rawValue: "managed-local-music")

    @Published private(set) var sources: [LocalMusicSource] = []
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var lyrics: [TrackID: LyricsDocument] = [:]
    @Published private(set) var lastScan: LocalLibraryScanSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?

    private struct ScannedTrack {
        let track: Track
        let lyrics: LyricsDocument?
    }

    private struct MetadataSidecar: Decodable {
        var title: String?
        var artist: String?
        var album: String?
        var year: Int?
        var trackNumber: Int?
        var discNumber: Int?
        var genres: [String]?
        var genre: String?
        var language: String?
        var coverFile: String?
        var lyricsFile: String?
    }

    private static let managedSourceToken = "auralis-managed-local-music"
    private let sourcesURL: URL
    private let managedRootURL: URL?
    private var accessedRoots: [LocalLibraryID: URL] = [:]

    private static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ogg", "opus"
    ]
    private static let artworkExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "heic", "heif"
    ]
    private static let lyricsExtensions: Set<String> = ["lrc", "txt"]

    private static let managedReadme = """
    Auralis 本地音乐目录

    每首歌曲请放在 LocalMusic 下独立的一级文件夹中。一首歌 = 一个文件夹。

    示例：
    LocalMusic/
      歌曲名/
        audio.flac       必需：恰好一个受支持的音频文件
        cover.jpg        推荐：封面，也支持 folder/front/artwork 等常用名称
        lyrics.lrc       推荐：LRC 时间轴歌词；也支持 lyrics.txt
        metadata.json    可选：标题、艺人、专辑、年份、曲号、流派、语言等覆盖信息

    音频支持：MP3、M4A、AAC、ALAC、FLAC、WAV、AIFF、OGG、Opus。
    封面支持：JPG/JPEG、PNG、WebP、HEIC/HEIF。
    歌词支持：LRC、TXT。

    metadata.json 示例：
    {
      "title": "歌曲名",
      "artist": "艺人",
      "album": "专辑",
      "year": 2026,
      "trackNumber": 1,
      "discNumber": 1,
      "genres": ["Pop"],
      "language": "zh-Hans"
    }

    metadata.json 中还可用 coverFile / lyricsFile 指定当前歌曲文件夹内的自定义封面或歌词文件名。
    """

    init(directory: URL? = nil, managedDirectory: URL? = nil) {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let metadataRoot = directory ?? support.appendingPathComponent("Auralis/LocalMusic", isDirectory: true)
        try? manager.createDirectory(at: metadataRoot, withIntermediateDirectories: true)
        sourcesURL = metadataRoot.appendingPathComponent("sources.json")

#if os(iOS)
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let managedRoot = managedDirectory
            ?? documents.appendingPathComponent("LocalMusic", isDirectory: true)
        Self.ensureManagedRoot(at: managedRoot)
        managedRootURL = managedRoot
#else
        if let managedDirectory {
            Self.ensureManagedRoot(at: managedDirectory)
        }
        managedRootURL = managedDirectory
#endif

        if let data = try? Data(contentsOf: sourcesURL),
           let decoded = try? JSONDecoder().decode([LocalMusicSource].self, from: data) {
            sources = decoded.filter { $0.id != Self.managedSourceID }
        }

        // iOS always supplies this URL from Documents. Tests may inject one on macOS so the
        // managed-source contract can be verified without touching a user's real Documents folder.
        if managedRootURL != nil {
            sources.insert(
                LocalMusicSource(
                    id: Self.managedSourceID,
                    displayName: "Auralis 本地音乐",
                    locationToken: Self.managedSourceToken
                ),
                at: 0
            )
        }
        restoreSecurityScopedRoots()
    }

    deinit {
        for url in accessedRoots.values {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func addSource(url: URL) async {
        if let managedRootURL,
           url.standardizedFileURL == managedRootURL.standardizedFileURL,
           let managedSource = sources.first(where: { $0.id == Self.managedSourceID }) {
            _ = await scan(source: managedSource)
            return
        }
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
        guard source.id != Self.managedSourceID else { return }
        if let root = accessedRoots.removeValue(forKey: source.id) {
            root.stopAccessingSecurityScopedResource()
        }
        sources.removeAll { $0.id == source.id }
        let removedIDs = Set(tracks.filter { Self.belongs($0, to: source.id) }.map(\.id))
        tracks.removeAll { Self.belongs($0, to: source.id) }
        for trackID in removedIDs {
            lyrics[trackID] = nil
        }
        try? persistSources()
        let currentTracks = tracks
        let currentLyrics = lyrics
        Task { @MainActor in
            await UnifiedLocalCatalogBridge.publish(tracks: currentTracks, lyrics: currentLyrics)
        }
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
        await UnifiedLocalCatalogBridge.publish(tracks: tracks, lyrics: lyrics)
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

        let result: (items: [ScannedTrack], discovered: Int, failed: Int)
        if source.id == Self.managedSourceID {
            result = await scanManagedPackages(root: root, source: source)
        } else {
            result = await scanLegacyTree(root: root, source: source)
        }

        let oldIDs = Set(tracks.filter { Self.belongs($0, to: source.id) }.map(\.id))
        let newTracks = result.items.map(\.track)
        let newIDs = Set(newTracks.map(\.id))

        tracks.removeAll { Self.belongs($0, to: source.id) }
        tracks.append(contentsOf: newTracks)
        for trackID in oldIDs {
            lyrics[trackID] = nil
        }
        for item in result.items {
            if let document = item.lyrics {
                lyrics[item.track.id] = document
            }
        }

        let snapshot = LocalLibraryScanSnapshot(
            discoveredFiles: result.discovered,
            importedTracks: newIDs.subtracting(oldIDs).count,
            updatedTracks: newIDs.intersection(oldIDs).count,
            removedTracks: oldIDs.subtracting(newIDs).count,
            failedFiles: result.failed,
            completedAt: .now
        )
        lastScan = snapshot
        if manageState {
            await UnifiedLocalCatalogBridge.publish(tracks: tracks, lyrics: lyrics)
        }
        return snapshot
    }

    private func scanManagedPackages(
        root: URL,
        source: LocalMusicSource
    ) async -> (items: [ScannedTrack], discovered: Int, failed: Int) {
        Self.ensureManagedRoot(at: root)
        let manager = FileManager.default
        let children = (try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let packages = children.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var imported: [ScannedTrack] = []
        var failed = 0
        for package in packages {
            if let item = await Self.scanManagedPackage(package, source: source, root: root) {
                imported.append(item)
            } else {
                failed += 1
            }
        }
        return (imported, packages.count, failed)
    }

    private func scanLegacyTree(
        root: URL,
        source: LocalMusicSource
    ) async -> (items: [ScannedTrack], discovered: Int, failed: Int) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        var imported: [ScannedTrack] = []
        var failed = 0
        var discovered = 0
        while let file = enumerator?.nextObject() as? URL {
            guard Self.supportedExtensions.contains(file.pathExtension.lowercased()) else { continue }
            discovered += 1
            let relative = file.path.replacingOccurrences(of: root.path, with: "")
            if let item = await Self.makeScannedTrack(
                file: file,
                packageFolder: file.deletingLastPathComponent(),
                identityPath: relative,
                source: source
            ) {
                imported.append(item)
            } else {
                failed += 1
            }
        }
        return (imported, discovered, failed)
    }

    private static func scanManagedPackage(
        _ folder: URL,
        source: LocalMusicSource,
        root: URL
    ) async -> ScannedTrack? {
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let audioFiles = contents.filter { file in
            guard supportedExtensions.contains(file.pathExtension.lowercased()) else { return false }
            return (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard audioFiles.count == 1, let audioFile = audioFiles.first else { return nil }
        let identityPath = folder.path.replacingOccurrences(of: root.path, with: "")
        return await makeScannedTrack(
            file: audioFile,
            packageFolder: folder,
            identityPath: identityPath,
            source: source
        )
    }

    private func restoreSecurityScopedRoots() {
        for source in sources where source.id != Self.managedSourceID {
            _ = resolveRoot(source)
        }
    }

    private func resolveRoot(_ source: LocalMusicSource) -> URL? {
        if source.id == Self.managedSourceID, let managedRootURL {
            Self.ensureManagedRoot(at: managedRootURL)
            return managedRootURL
        }
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
        let persisted = sources.filter { $0.id != Self.managedSourceID }
        try JSONEncoder().encode(persisted).write(to: sourcesURL, options: .atomic)
    }

    private static func belongs(_ track: Track, to sourceID: LocalLibraryID) -> Bool {
        track.id.rawValue.hasPrefix("local-file-\(fnv64(sourceID.rawValue))-")
    }

    private static func makeScannedTrack(
        file: URL,
        packageFolder: URL,
        identityPath: String,
        source: LocalMusicSource
    ) async -> ScannedTrack? {
        let asset = AVURLAsset(url: file)
        let durationTime = try? await asset.load(.duration)
        let duration = durationTime.map(CMTimeGetSeconds) ?? 0
        guard duration.isFinite, duration >= 0 else { return nil }

        let common = (try? await asset.load(.commonMetadata)) ?? []
        var embeddedTitle: String?
        var embeddedArtist: String?
        var embeddedAlbum: String?
        var embeddedGenres: [String] = []
        for item in common {
            let value = try? await item.load(.stringValue)
            switch item.commonKey?.rawValue {
            case "title": embeddedTitle = value
            case "artist": embeddedArtist = value
            case "albumName": embeddedAlbum = value
            case "type", "genre":
                if let value {
                    embeddedGenres.append(contentsOf: splitGenres(value))
                }
            default:
                break
            }
        }

        let metadata = readMetadata(in: packageFolder)
        let title = metadata?.title?.trimmedNonEmpty
            ?? embeddedTitle?.trimmedNonEmpty
            ?? packageFolder.lastPathComponent.trimmedNonEmpty
            ?? file.deletingPathExtension().lastPathComponent
        let artistName = metadata?.artist?.trimmedNonEmpty
            ?? embeddedArtist?.trimmedNonEmpty
            ?? "未知艺术家"
        let albumTitle = metadata?.album?.trimmedNonEmpty
            ?? embeddedAlbum?.trimmedNonEmpty
            ?? "未知专辑"

        var genres = embeddedGenres
        if let explicitGenres = metadata?.genres {
            genres = explicitGenres.compactMap(\.trimmedNonEmpty)
        } else if let genre = metadata?.genre?.trimmedNonEmpty {
            genres = splitGenres(genre)
        }
        genres = Array(Set(genres)).sorted()

        let sourceHash = fnv64(source.id.rawValue)
        let fileHash = fnv64(identityPath)
        let trackID = TrackID(rawValue: "local-file-\(sourceHash)-\(fileHash)")
        let coverURL = preferredArtwork(
            in: packageFolder,
            audioFile: file,
            explicitFileName: metadata?.coverFile
        )
        let lyricsURL = preferredLyrics(
            in: packageFolder,
            audioFile: file,
            explicitFileName: metadata?.lyricsFile
        )
        let language = metadata?.language?.trimmedNonEmpty

        let track = Track(
            id: trackID,
            serverID: localServerID,
            albumID: AlbumID(rawValue: "local-album-\(fnv64(artistName + "|" + albumTitle))"),
            artistID: ArtistID(rawValue: "local-artist-\(fnv64(artistName))"),
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            duration: duration,
            trackNumber: metadata?.trackNumber,
            discNumber: metadata?.discNumber,
            year: metadata?.year,
            genres: genres,
            language: language,
            artworkKey: coverURL.map { LocalArtworkKey.make(fileURL: $0) },
            sourceInfo: AudioSourceInfo(codec: file.pathExtension.lowercased()),
            streamURL: file
        )

        return ScannedTrack(
            track: track,
            lyrics: lyricsURL.flatMap {
                makeLyricsDocument(file: $0, trackID: trackID, language: language)
            }
        )
    }

    private static func readMetadata(in folder: URL) -> MetadataSidecar? {
        let url = folder.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MetadataSidecar.self, from: data)
    }

    private static func preferredArtwork(
        in folder: URL,
        audioFile: URL,
        explicitFileName: String?
    ) -> URL? {
        if let explicit = safeSidecarURL(
            fileName: explicitFileName,
            in: folder,
            allowedExtensions: artworkExtensions
        ) {
            return explicit
        }

        let audioStem = audioFile.deletingPathExtension().lastPathComponent.lowercased()
        let stems = ["cover", "folder", "front", "artwork", audioStem]
        return preferredSidecar(in: folder, stems: stems, extensions: artworkExtensions)
    }

    private static func preferredLyrics(
        in folder: URL,
        audioFile: URL,
        explicitFileName: String?
    ) -> URL? {
        if let explicit = safeSidecarURL(
            fileName: explicitFileName,
            in: folder,
            allowedExtensions: lyricsExtensions
        ) {
            return explicit
        }

        let audioStem = audioFile.deletingPathExtension().lastPathComponent.lowercased()
        let stems = ["lyrics", audioStem]
        return preferredSidecar(in: folder, stems: stems, extensions: lyricsExtensions)
    }

    private static func preferredSidecar(
        in folder: URL,
        stems: [String],
        extensions: Set<String>
    ) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let regularFiles = contents.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }

        for stem in stems {
            if let match = regularFiles.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == stem.lowercased()
                    && extensions.contains($0.pathExtension.lowercased())
            }) {
                return match
            }
        }
        return nil
    }

    private static func safeSidecarURL(
        fileName: String?,
        in folder: URL,
        allowedExtensions: Set<String>
    ) -> URL? {
        guard let fileName = fileName?.trimmedNonEmpty,
              URL(fileURLWithPath: fileName).lastPathComponent == fileName
        else { return nil }
        let url = folder.appendingPathComponent(fileName)
        guard allowedExtensions.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    private static func makeLyricsDocument(
        file: URL,
        trackID: TrackID,
        language: String?
    ) -> LyricsDocument? {
        guard let raw = readText(file) else { return nil }

        if file.pathExtension.lowercased() == "lrc" {
            let timed = parseLRC(raw)
            if !timed.isEmpty {
                return LyricsDocument(
                    trackID: trackID,
                    language: language,
                    lines: timed,
                    isSynced: true
                )
            }
        }

        let plainLines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { TimedLyricLine(text: $0) }
        guard !plainLines.isEmpty else { return nil }
        return LyricsDocument(
            trackID: trackID,
            language: language,
            lines: plainLines,
            isSynced: false
        )
    }

    private static func parseLRC(_ raw: String) -> [TimedLyricLine] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        ) else { return [] }

        var result: [TimedLyricLine] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let fullRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = regex.matches(in: rawLine, range: fullRange)
            guard let last = matches.last,
                  let textRange = Range(
                    NSRange(location: last.range.location + last.range.length,
                            length: max(0, fullRange.length - last.range.location - last.range.length)),
                    in: rawLine
                  )
            else { continue }

            let text = String(rawLine[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: rawLine),
                      let secondRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Double(String(rawLine[minuteRange])),
                      let seconds = Double(String(rawLine[secondRange]))
                else { continue }

                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let token = String(rawLine[fractionRange])
                    if let value = Double(token) {
                        fraction = value / pow(10, Double(token.count))
                    }
                }

                result.append(TimedLyricLine(
                    startTime: minutes * 60 + seconds + fraction,
                    text: text
                ))
            }
        }
        return result.sorted {
            ($0.startTime ?? .greatestFiniteMagnitude) < ($1.startTime ?? .greatestFiniteMagnitude)
        }
    }

    private static func readText(_ file: URL) -> String? {
        if let value = try? String(contentsOf: file, encoding: .utf8) {
            return value
        }
        return try? String(contentsOf: file, encoding: .utf16)
    }

    private static func ensureManagedRoot(at root: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        let readmeURL = root.appendingPathComponent("README.txt")
        if !manager.fileExists(atPath: readmeURL.path) {
            try? managedReadme.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
    }

    private static func splitGenres(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

/// Called by the application composition roots on every launch. Persisted security-scoped roots are
/// rescanned and republished without requiring the user to open Settings first.
public enum LocalMusicCatalogBootstrap {
    @MainActor
    public static func restore() async {
        let library = LocalMusicLibraryStore.shared
        guard !library.sources.isEmpty else {
            await UnifiedLocalCatalogBridge.publish(tracks: [])
            return
        }
        _ = await library.scanAll()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }

    var trimmedNonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
}
