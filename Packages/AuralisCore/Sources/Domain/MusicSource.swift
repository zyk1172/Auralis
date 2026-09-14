// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A stable identifier for a user-managed local music root. The location itself is
/// deliberately stored outside the domain model because Apple security-scoped bookmarks
/// and Android persisted document URIs are platform-specific capabilities.
public struct LocalLibraryID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral {
    public let rawValue: String
    public var id: String { rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct LocalMusicSource: Codable, Hashable, Sendable, Identifiable {
    public let id: LocalLibraryID
    public var displayName: String
    /// Opaque platform-owned token. Apple stores a bookmark key; Android stores a persisted URI string.
    /// Consumers must never assume this is a filesystem path.
    public var locationToken: String
    public var isEnabled: Bool
    public var addedAt: Date

    public init(
        id: LocalLibraryID,
        displayName: String,
        locationToken: String,
        isEnabled: Bool = true,
        addedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.locationToken = locationToken
        self.isEnabled = isEnabled
        self.addedAt = addedAt
    }
}

/// Source identity is separate from ServerID. Existing remote models continue to carry
/// ServerID for wire/storage compatibility while local-library code uses this type at
/// boundaries so a local source is never sent through a server connector by accident.
public enum MusicSource: Codable, Hashable, Sendable {
    case server(ServerID)
    case local(LocalLibraryID)
}

public struct LocalTrackReference: Codable, Hashable, Sendable {
    public let libraryID: LocalLibraryID
    /// Stable scanner identity, independent of a temporary playback URL.
    public let stableFileID: String
    /// Opaque platform token that can be resolved into file:// or content:// only at playback time.
    public let locationToken: String

    public init(libraryID: LocalLibraryID, stableFileID: String, locationToken: String) {
        self.libraryID = libraryID
        self.stableFileID = stableFileID
        self.locationToken = locationToken
    }
}

public enum PlaybackSourceReference: Codable, Hashable, Sendable {
    case remote(serverID: ServerID, trackID: TrackID)
    case local(LocalTrackReference)
}

/// Records the one-way canonicalisation performed when a server download is promoted
/// into the user's local music library. Old remote IDs remain valid aliases so queues,
/// history and playlists created before the download do not break.
public struct TrackIdentityTransition: Codable, Hashable, Sendable {
    public let remoteServerID: ServerID
    public let remoteTrackID: TrackID
    public let localLibraryID: LocalLibraryID
    public let localTrackID: TrackID
    public let promotedAt: Date

    public init(
        remoteServerID: ServerID,
        remoteTrackID: TrackID,
        localLibraryID: LocalLibraryID,
        localTrackID: TrackID,
        promotedAt: Date = .now
    ) {
        self.remoteServerID = remoteServerID
        self.remoteTrackID = remoteTrackID
        self.localLibraryID = localLibraryID
        self.localTrackID = localTrackID
        self.promotedAt = promotedAt
    }
}

public struct LocalLibraryScanSnapshot: Codable, Hashable, Sendable {
    public var discoveredFiles: Int
    public var importedTracks: Int
    public var updatedTracks: Int
    public var removedTracks: Int
    public var failedFiles: Int
    public var completedAt: Date

    public init(
        discoveredFiles: Int = 0,
        importedTracks: Int = 0,
        updatedTracks: Int = 0,
        removedTracks: Int = 0,
        failedFiles: Int = 0,
        completedAt: Date = .now
    ) {
        self.discoveredFiles = discoveredFiles
        self.importedTracks = importedTracks
        self.updatedTracks = updatedTracks
        self.removedTracks = removedTracks
        self.failedFiles = failedFiles
        self.completedAt = completedAt
    }
}

public protocol LocalMusicSourceStore: Sendable {
    func sources() async throws -> [LocalMusicSource]
    func saveSource(_ source: LocalMusicSource) async throws
    func removeSource(id: LocalLibraryID) async throws
}

public protocol LocalMusicScanning: Sendable {
    func scan(source: LocalMusicSource) async throws -> LocalLibraryScanSnapshot
}

public protocol PlaybackSourceResolving: Sendable {
    func resolve(_ source: PlaybackSourceReference) async throws -> URL
}
