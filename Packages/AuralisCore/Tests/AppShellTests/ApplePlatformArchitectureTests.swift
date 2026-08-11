import Domain
import LocalCatalog
import Testing
@testable import AppShell

struct ApplePlatformArchitectureTests {
    @Test func browseDestinationsHaveStableDistinctNavigationIdentity() {
        let album = Album(
            id: "album-1",
            serverID: "server-1",
            artistID: "artist-1",
            title: "Album",
            artistName: "Artist",
            year: 2026,
            genre: nil,
            artworkKey: nil,
            songCount: 1
        )
        let artist = Artist(
            id: "artist-1",
            serverID: "server-1",
            name: "Artist",
            albumCount: 1,
            artworkKey: nil
        )

        let destinations: Set<BrowseDestination> = [
            .album(album),
            .artist(artist),
            .favorites,
            .downloads,
        ]

        #expect(destinations.count == 4)
        #expect(BrowseDestination.album(album).id == "album.album-1")
        #expect(BrowseDestination.artist(artist).id == "artist.artist-1")
    }

    @Test func compactDockContainsOnlyTheThreePrimarySections() {
        #expect(AppSection.compactDockSections == [.home, .library, .assistant])
        #expect(!AppSection.compactDockSections.contains(.search))
        #expect(!AppSection.compactDockSections.contains(.settings))
    }

    @Test func dockRequiresAtLeastAStandardTouchTargetSwipe() {
        #expect(BottomDockProgressReducer.minimumVerticalSwipeDistance >= 44)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 1, height: -43)) == nil)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 1, height: -44)) == 1)
    }
}
