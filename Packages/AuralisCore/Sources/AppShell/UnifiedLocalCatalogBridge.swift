// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Foundation
import MusicLibrary

/// Promotes the AppShell scanner snapshot into both Apple catalog read surfaces:
/// 1. the ordinary in-memory LibraryCatalog used by iPhone/iPad/macOS Library and Search;
/// 2. the existing SQLite LocalCatalogStore used by Agent entity resolution/FTS.
///
/// `auralis-local` is an entity namespace only. No ServerAccount or credential is created.
@MainActor
enum UnifiedLocalCatalogBridge {
    static func publish(
        tracks: [Track],
        lyrics: [TrackID: LyricsDocument] = [:]
    ) async {
        let previous = LocalCatalogOverlay.snapshot()
        let snapshot = makeSnapshot(tracks: tracks, lyrics: lyrics)
        let model = AuralisAppModel.shared

        // Genre has no source identity in the Swift domain model. Remove the previous local
        // contribution before replacing the overlay so repeated rescans cannot accumulate counts.
        let current = model.libraryStore.catalog
        let remoteGenres = LocalCatalogOverlay.removingLocalGenreContribution(
            from: current.genres,
            previousLocal: previous
        )
        let remoteArtists = current.artists.filter { $0.serverID != LocalCatalogOverlay.localServerID }
        let remoteAlbums = current.albums.filter { $0.serverID != LocalCatalogOverlay.localServerID }
        let remoteTracks = current.tracks.filter { $0.serverID != LocalCatalogOverlay.localServerID }

        // Lyrics use TrackID as the key and do not carry a source namespace themselves. Remove the
        // previous local-track contribution explicitly before the replacement snapshot is merged.
        let previousLocalTrackIDs = Set(previous.tracks.map(\.id))
        var remoteLyrics = current.lyrics
        for trackID in previousLocalTrackIDs {
            remoteLyrics[trackID] = nil
        }

        LocalCatalogOverlay.replace(with: snapshot)
        model.libraryStore.catalog = LibraryCatalog(
            account: current.account,
            artists: remoteArtists,
            albums: remoteAlbums,
            tracks: remoteTracks,
            genres: remoteGenres,
            playlists: current.playlists,
            history: current.history,
            downloads: current.downloads,
            lyrics: remoteLyrics,
            recommendations: current.recommendations
        )

        // The Agent catalog is transactional. A failed local reindex leaves the previous local
        // snapshot intact in SQLite; the UI overlay above still remains immediately usable.
        do {
            let store = model.catalogCoordinator.store
            let session = try await store.beginSync(
                serverID: LocalCatalogOverlay.localServerID,
                mode: .full
            )
            do {
                try await store.stageArtists(snapshot.artists, session: session)
                try await store.stageAlbums(snapshot.albums, session: session)
                try await store.stageTracks(snapshot.tracks, session: session)
                try await store.completeSync(session, completedAt: .now)
            } catch {
                await store.discardSync(session)
                throw error
            }
        } catch {
            // Local scanning/playback must remain available even if the auxiliary Agent index
            // cannot be refreshed. The next scan retries a full transactional replacement.
        }
    }

    static func makeSnapshot(
        tracks: [Track],
        lyrics: [TrackID: LyricsDocument] = [:]
    ) -> LocalCatalogOverlaySnapshot {
        let localTracks = tracks.filter { $0.serverID == LocalCatalogOverlay.localServerID }
        let localTrackIDs = Set(localTracks.map(\.id))
        let localLyrics = lyrics.filter { localTrackIDs.contains($0.key) }

        let artistGroups = Dictionary(grouping: localTracks, by: \.artistID)
        let artists = artistGroups.map { artistID, group in
            Artist(
                id: artistID,
                serverID: LocalCatalogOverlay.localServerID,
                name: group.first?.artistName ?? String(localized: "未知艺术家", bundle: .module),
                albumCount: Set(group.map(\.albumID)).count,
                artworkKey: group.compactMap(\.artworkKey).first
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let albumGroups = Dictionary(grouping: localTracks, by: \.albumID)
        let albums = albumGroups.compactMap { albumID, group -> Album? in
            guard let first = group.first else { return nil }
            return Album(
                id: albumID,
                serverID: LocalCatalogOverlay.localServerID,
                artistID: first.artistID,
                title: first.albumTitle,
                artistName: first.artistName,
                year: group.compactMap(\.year).first,
                genre: group.flatMap(\.genres).first,
                artworkKey: group.compactMap(\.artworkKey).first,
                songCount: group.count
            )
        }
        .sorted {
            if $0.artistName != $1.artistName {
                return $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        var genreDisplayName: [String: String] = [:]
        var genreCounts: [String: Int] = [:]
        for genre in localTracks.flatMap(\.genres) {
            let display = genre.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty else { continue }
            let key = display.lowercased()
            genreDisplayName[key] = genreDisplayName[key] ?? display
            genreCounts[key, default: 0] += 1
        }
        let genres = genreCounts.map { key, count in
            Genre(name: genreDisplayName[key] ?? key, songCount: count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return LocalCatalogOverlaySnapshot(
            artists: artists,
            albums: albums,
            tracks: localTracks,
            genres: genres,
            lyrics: localLyrics
        )
    }
}
