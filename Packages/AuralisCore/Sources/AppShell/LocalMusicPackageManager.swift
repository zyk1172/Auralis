// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Domain
import Foundation

/// Owns the one-song package format. On iOS/iPadOS the root is Files-visible Documents/LocalMusic;
/// other Apple platforms keep download packages inside the existing app-managed support directory.
enum LocalMusicPackageManager {
    struct ImportResult: Sendable, Equatable {
        var imported = 0
        var failed = 0
    }

    private struct PackageMetadata: Codable {
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
        var managedByAuralisDownload: Bool?
        var sourceServerID: String?
        var sourceTrackID: String?
    }

    private struct EmbeddedMetadata {
        var title: String?
        var artist: String?
        var album: String?
        var genres: [String] = []
        var artworkData: Data?
    }

    private static let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ogg", "opus"
    ]
    private static let artworkExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif"]
    private static let lyricsExtensions: Set<String> = ["lrc", "txt"]

    static func managedRoot(fileManager: FileManager = .default) -> URL {
#if os(iOS)
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return documents.appendingPathComponent("LocalMusic", isDirectory: true)
#else
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return support.appendingPathComponent("Auralis/LocalMusic/Downloads", isDirectory: true)
#endif
    }

    static func importItems(_ urls: [URL], destinationRoot: URL? = nil) async -> ImportResult {
        let root = destinationRoot ?? managedRoot()
        var result = ImportResult()
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                if isDirectory(url) {
                    try await importFolder(url, destinationRoot: root)
                } else if supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                    try await importAudioFile(url, destinationRoot: root)
                } else {
                    throw PackageError.unsupportedSelection
                }
                result.imported += 1
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    /// Creates metadata/cover/lyrics first and returns the final audio destination. TrackCacheStore
    /// then moves the downloaded audio into that location, so there is only one audio copy on disk.
    static func prepareDownloadedPackage(
        track: Track,
        audioExtension: String,
        artworkData: Data?,
        lyrics: LyricsDocument?,
        destinationRoot: URL? = nil
    ) throws -> URL {
        let manager = FileManager.default
        let root = destinationRoot ?? managedRoot(fileManager: manager)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        let identity = "\(track.serverID.rawValue):\(track.id.rawValue)"
        let suffix = String(fnv64(identity).prefix(8))
        let readable = sanitizedFileName("\(track.artistName) - \(track.title)")
        let folder = root.appendingPathComponent("\(readable) [\(suffix)]", isDirectory: true)
        if manager.fileExists(atPath: folder.path) {
            try manager.removeItem(at: folder)
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        var coverFile: String?
        if let artworkData, !artworkData.isEmpty {
            let ext = artworkExtension(for: artworkData)
            let name = "cover.\(ext)"
            try artworkData.write(to: folder.appendingPathComponent(name), options: .atomic)
            coverFile = name
        }

        var lyricsFile: String?
        if let lyrics, !lyrics.lines.isEmpty {
            if lyrics.isSynced, lyrics.lines.contains(where: { $0.startTime != nil }) {
                let name = "lyrics.lrc"
                try lrcText(from: lyrics).write(
                    to: folder.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
                lyricsFile = name
            } else {
                let name = "lyrics.txt"
                try plainLyricsText(from: lyrics).write(
                    to: folder.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
                lyricsFile = name
            }
        }

        let metadata = PackageMetadata(
            title: track.title,
            artist: track.artistName,
            album: track.albumTitle,
            year: track.year,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            genres: track.genres.isEmpty ? nil : track.genres,
            genre: nil,
            language: track.language ?? lyrics?.language,
            coverFile: coverFile,
            lyricsFile: lyricsFile,
            managedByAuralisDownload: true,
            sourceServerID: track.serverID.rawValue,
            sourceTrackID: track.id.rawValue
        )
        try writeMetadata(metadata, to: folder)

        let ext = normalizedAudioExtension(audioExtension, fallbackCodec: track.sourceInfo.codec)
        return folder.appendingPathComponent("audio.\(ext)")
    }

    static func discardPreparedDownloadPackage(audioDestination: URL) {
        let folder = audioDestination.deletingLastPathComponent()
        guard readMetadata(in: folder)?.managedByAuralisDownload == true else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func importFolder(_ folder: URL, destinationRoot: URL) async throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let audioFiles = contents.filter { isRegularAudioFile($0) }
        guard audioFiles.count == 1, let audio = audioFiles.first else {
            throw PackageError.invalidAudioCount
        }
        try await copyAsManagedPackage(
            audio: audio,
            sourceFolder: folder,
            mayUseSharedSidecars: true,
            destinationRoot: destinationRoot
        )
    }

    private static func importAudioFile(_ audio: URL, destinationRoot: URL) async throws {
        let parent = audio.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let mayUseSharedSidecars = siblings.filter { isRegularAudioFile($0) }.count == 1
        try await copyAsManagedPackage(
            audio: audio,
            sourceFolder: parent,
            mayUseSharedSidecars: mayUseSharedSidecars,
            destinationRoot: destinationRoot
        )
    }

    private static func copyAsManagedPackage(
        audio: URL,
        sourceFolder: URL,
        mayUseSharedSidecars: Bool,
        destinationRoot: URL
    ) async throws {
        guard supportedAudioExtensions.contains(audio.pathExtension.lowercased()) else {
            throw PackageError.unsupportedSelection
        }

        let sourceMetadata = mayUseSharedSidecars ? readMetadata(in: sourceFolder) : nil
        let embedded = await readEmbeddedMetadata(audio)
        let title = sourceMetadata?.title?.packageTrimmedNonEmpty
            ?? embedded.title?.packageTrimmedNonEmpty
            ?? audio.deletingPathExtension().lastPathComponent
        let artist = sourceMetadata?.artist?.packageTrimmedNonEmpty
            ?? embedded.artist?.packageTrimmedNonEmpty
            ?? "未知艺术家"
        let album = sourceMetadata?.album?.packageTrimmedNonEmpty
            ?? embedded.album?.packageTrimmedNonEmpty
            ?? "未知专辑"

        var genres = sourceMetadata?.genres?.compactMap(\.packageTrimmedNonEmpty) ?? []
        if genres.isEmpty, let genre = sourceMetadata?.genre?.packageTrimmedNonEmpty {
            genres = splitGenres(genre)
        }
        if genres.isEmpty { genres = embedded.genres }
        genres = Array(Set(genres)).sorted()

        let manager = FileManager.default
        try manager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let folder = uniqueFolder(
            under: destinationRoot,
            baseName: sanitizedFileName("\(artist) - \(title)"),
            fileManager: manager
        )
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var shouldRemoveFolder = true
        defer {
            if shouldRemoveFolder { try? manager.removeItem(at: folder) }
        }

        let audioName = "audio.\(normalizedAudioExtension(audio.pathExtension, fallbackCodec: nil))"
        try manager.copyItem(at: audio, to: folder.appendingPathComponent(audioName))

        let sourceArtwork = preferredArtwork(
            in: sourceFolder,
            audioFile: audio,
            explicitFileName: mayUseSharedSidecars ? sourceMetadata?.coverFile : nil,
            allowGenericNames: mayUseSharedSidecars
        )
        var coverFile: String?
        if let sourceArtwork {
            let ext = sourceArtwork.pathExtension.lowercased()
            let name = "cover.\(ext)"
            try manager.copyItem(at: sourceArtwork, to: folder.appendingPathComponent(name))
            coverFile = name
        } else if let data = embedded.artworkData, !data.isEmpty {
            let ext = artworkExtension(for: data)
            let name = "cover.\(ext)"
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            coverFile = name
        }

        let sourceLyrics = preferredLyrics(
            in: sourceFolder,
            audioFile: audio,
            explicitFileName: mayUseSharedSidecars ? sourceMetadata?.lyricsFile : nil,
            allowGenericNames: mayUseSharedSidecars
        )
        var lyricsFile: String?
        if let sourceLyrics {
            let ext = sourceLyrics.pathExtension.lowercased()
            let name = "lyrics.\(ext)"
            try manager.copyItem(at: sourceLyrics, to: folder.appendingPathComponent(name))
            lyricsFile = name
        }

        let normalized = PackageMetadata(
            title: title,
            artist: artist,
            album: album,
            year: sourceMetadata?.year,
            trackNumber: sourceMetadata?.trackNumber,
            discNumber: sourceMetadata?.discNumber,
            genres: genres.isEmpty ? nil : genres,
            genre: nil,
            language: sourceMetadata?.language?.packageTrimmedNonEmpty,
            coverFile: coverFile,
            lyricsFile: lyricsFile,
            managedByAuralisDownload: nil,
            sourceServerID: nil,
            sourceTrackID: nil
        )
        try writeMetadata(normalized, to: folder)
        shouldRemoveFolder = false
    }

    private static func readEmbeddedMetadata(_ file: URL) async -> EmbeddedMetadata {
        let asset = AVURLAsset(url: file)
        let common = (try? await asset.load(.commonMetadata)) ?? []
        var result = EmbeddedMetadata()
        for item in common {
            let key = item.commonKey?.rawValue
            if key == "artwork" {
                if result.artworkData == nil {
                    result.artworkData = try? await item.load(.dataValue)
                }
                continue
            }
            let value = try? await item.load(.stringValue)
            switch key {
            case "title": result.title = value
            case "artist": result.artist = value
            case "albumName": result.album = value
            case "type", "genre":
                if let value { result.genres.append(contentsOf: splitGenres(value)) }
            default: break
            }
        }
        return result
    }

    private static func preferredArtwork(
        in folder: URL,
        audioFile: URL,
        explicitFileName: String?,
        allowGenericNames: Bool
    ) -> URL? {
        if let explicit = safeSidecarURL(fileName: explicitFileName, in: folder, allowedExtensions: artworkExtensions) {
            return explicit
        }
        let stem = audioFile.deletingPathExtension().lastPathComponent.lowercased()
        let stems = allowGenericNames ? ["cover", "folder", "front", "artwork", stem] : [stem]
        return preferredSidecar(in: folder, stems: stems, extensions: artworkExtensions)
    }

    private static func preferredLyrics(
        in folder: URL,
        audioFile: URL,
        explicitFileName: String?,
        allowGenericNames: Bool
    ) -> URL? {
        if let explicit = safeSidecarURL(fileName: explicitFileName, in: folder, allowedExtensions: lyricsExtensions) {
            return explicit
        }
        let stem = audioFile.deletingPathExtension().lastPathComponent.lowercased()
        let stems = allowGenericNames ? ["lyrics", stem] : [stem]
        return preferredSidecar(in: folder, stems: stems, extensions: lyricsExtensions)
    }

    private static func preferredSidecar(in folder: URL, stems: [String], extensions: Set<String>) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for stem in stems {
            if let match = files.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == stem.lowercased()
                    && extensions.contains($0.pathExtension.lowercased())
            }) {
                return match
            }
        }
        return nil
    }

    private static func safeSidecarURL(fileName: String?, in folder: URL, allowedExtensions: Set<String>) -> URL? {
        guard let fileName = fileName?.packageTrimmedNonEmpty,
              URL(fileURLWithPath: fileName).lastPathComponent == fileName
        else { return nil }
        let url = folder.appendingPathComponent(fileName)
        guard allowedExtensions.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    private static func readMetadata(in folder: URL) -> PackageMetadata? {
        let url = folder.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PackageMetadata.self, from: data)
    }

    private static func writeMetadata(_ metadata: PackageMetadata, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(metadata)
        try data.write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private static func lrcText(from document: LyricsDocument) -> String {
        document.lines.compactMap { line in
            guard let time = line.startTime else { return nil }
            let safe = max(0, time)
            let minutes = Int(safe / 60)
            let seconds = safe - Double(minutes * 60)
            return String(format: "[%02d:%05.2f]%@", minutes, seconds, line.text)
        }.joined(separator: "\n") + "\n"
    }

    private static func plainLyricsText(from document: LyricsDocument) -> String {
        document.lines.map(\.text).joined(separator: "\n") + "\n"
    }

    private static func artworkExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(16))
        if bytes.count >= 4, Array(bytes.prefix(4)) == [0x89, 0x50, 0x4E, 0x47] { return "png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpg" }
        if bytes.count >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return "webp" }
        if data.count >= 12 {
            let brand = String(data: data.subdata(in: 4..<min(data.count, 16)), encoding: .ascii)?.lowercased() ?? ""
            if brand.contains("heic") || brand.contains("heif") || brand.contains("mif1") { return "heic" }
        }
        return "jpg"
    }

    private static func normalizedAudioExtension(_ raw: String, fallbackCodec: String?) -> String {
        let ext = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if supportedAudioExtensions.contains(ext) { return ext }
        switch fallbackCodec?.lowercased() {
        case "flac": return "flac"
        case "aac", "m4a", "alac": return "m4a"
        case "ogg", "opus": return "ogg"
        case "wav": return "wav"
        case "aiff", "aif": return "aiff"
        default: return "mp3"
        }
    }

    private static func uniqueFolder(under root: URL, baseName: String, fileManager: FileManager) -> URL {
        var candidate = root.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(baseName) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\n\r\t").union(.controlCharacters)
        let mapped = raw.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
        let trimmed = mapped.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "未命名歌曲" : trimmed).prefix(120))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRegularAudioFile(_ url: URL) -> Bool {
        guard supportedAudioExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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

    private enum PackageError: Error {
        case unsupportedSelection
        case invalidAudioCount
    }
}

private extension String {
    var packageTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
