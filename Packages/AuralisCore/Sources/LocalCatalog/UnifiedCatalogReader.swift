// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Foundation

extension LocalCatalogStore {
    /// Read boundary used by user-facing Search/Agent. A nil active server means "local only";
    /// a real active server means "that server + true local files". It never widens into other
    /// saved servers, preserving multi-server isolation.
    public func unifiedSearchAll(
        query: String,
        activeServerID: ServerID?
    ) throws -> LocalCatalogSearchResults {
        let all = try searchAll(query: query, serverID: nil)
        return LocalCatalogSearchResults(
            tracks: all.tracks.filter { unifiedSourceAllows($0.globalID, activeServerID: activeServerID) },
            albums: all.albums.filter { unifiedSourceAllows($0.globalID, activeServerID: activeServerID) },
            artists: all.artists.filter { unifiedSourceAllows($0.globalID, activeServerID: activeServerID) }
        )
    }

    public func unifiedSearchTracks(
        query: String,
        activeServerID: ServerID?
    ) throws -> [CatalogTrackSummary] {
        try searchTracks(query: query, serverID: nil)
            .filter { unifiedSourceAllows($0.globalID, activeServerID: activeServerID) }
    }

    public func unifiedSearchAlbums(
        query: String,
        activeServerID: ServerID?
    ) throws -> [CatalogAlbumSummary] {
        try searchAlbums(query: query, serverID: nil)
            .filter { unifiedSourceAllows($0.globalID, activeServerID: activeServerID) }
    }

    public func unifiedSearchArtists(
        query: String,
        activeServerID: ServerID?
    ) throws -> [CatalogArtistSummary] {
        try searchArtists(query: query, serverID: nil)
            .filter { unifiedSourceAllows($0.globalID, activeServerID: activeServerID) }
    }

    public func unifiedTracks(activeServerID: ServerID?) throws -> [Track] {
        let local = try allTracks(serverID: LocalCatalogOverlay.localServerID)
        guard let activeServerID, activeServerID != LocalCatalogOverlay.localServerID else {
            return local
        }
        let remote = try allTracks(serverID: activeServerID)
        return TrackQuality.deduplicatedPreferringQuality(remote + local)
    }

    public func unifiedAlbums(activeServerID: ServerID?) throws -> [Album] {
        let local = try allAlbums(serverID: LocalCatalogOverlay.localServerID)
        guard let activeServerID, activeServerID != LocalCatalogOverlay.localServerID else {
            return local
        }
        return try allAlbums(serverID: activeServerID) + local
    }

    public func unifiedArtists(activeServerID: ServerID?) throws -> [Artist] {
        let local = try allArtists(serverID: LocalCatalogOverlay.localServerID)
        guard let activeServerID, activeServerID != LocalCatalogOverlay.localServerID else {
            return local
        }
        return try allArtists(serverID: activeServerID) + local
    }

    public func unifiedFavorites(activeServerID: ServerID?) throws -> [CatalogTrackSummary] {
        try getFavorites(serverID: nil)
            .filter { unifiedSourceAllows($0.globalID, activeServerID: activeServerID) }
    }

    private func unifiedSourceAllows(_ globalID: GlobalID, activeServerID: ServerID?) -> Bool {
        if globalID.serverID == LocalCatalogOverlay.localServerID { return true }
        guard let activeServerID else { return false }
        return globalID.serverID == activeServerID
    }
}
