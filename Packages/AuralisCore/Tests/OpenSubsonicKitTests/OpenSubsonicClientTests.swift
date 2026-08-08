import Domain
import Foundation
import OpenSubsonicKit
import SecurityKit
import Testing

@Suite("OpenSubsonic URLSession client", .serialized)
struct OpenSubsonicClientTests {
    @Test("Server errors preserve code, message, and help URL")
    func serverErrorMapping() async throws {
        MockURLProtocol.reset(stubs: [
            .response(data: jsonData(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":42,"message":"Use an API key","helpUrl":"https://music.example.test/settings"}}}"#)),
        ])
        let client = try await makeClient()

        do {
            try await client.ping()
            Issue.record("Expected a server failure")
        } catch let OpenSubsonicClientError.serverFailure(error) {
            #expect(error.code == 42)
            #expect(error.message == "Use an API key")
            #expect(error.helpURL?.absoluteString == "https://music.example.test/settings")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Search maps server DTOs to server-scoped Domain models")
    func searchMapping() async throws {
        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""searchResult3":{"artist":[{"id":"artist-1","name":"Night Artist","albumCount":2}],"album":[{"id":"album-1","name":"Blue Hour","artist":"Night Artist","artistId":"artist-1","year":2024,"genre":"Ambient"}],"song":[{"id":"track-1","title":"Rain Signal","artist":"Night Artist","artistId":"artist-1","album":"Blue Hour","albumId":"album-1","duration":241.5,"track":3,"discNumber":1,"year":2024,"genres":[{"name":"Ambient"},{"name":"Electronic"}],"coverArt":"cover-1","suffix":"flac","bitRate":2854,"bitDepth":24,"samplingRate":96000,"channelCount":2,"starred":"2026-01-01T00:00:00Z","userRating":5}]}"#)),
        ])
        let client = try await makeClient()

        let result = try await client.search(
            query: "rain & night",
            artistCount: 3,
            albumCount: 4,
            songCount: 5
        )

        #expect(result.artists.first?.serverID == ServerID(rawValue: "server-a"))
        #expect(result.albums.first?.id == AlbumID(rawValue: "album-1"))
        let track = try #require(result.tracks.first)
        #expect(track.id == TrackID(rawValue: "track-1"))
        #expect(track.serverID == ServerID(rawValue: "server-a"))
        #expect(track.genres == ["Ambient", "Electronic"])
        #expect(track.isFavorite)
        #expect(track.rating == 5)
        #expect(track.sourceInfo.codec == "flac")
        #expect(track.sourceInfo.bitDepth == 24)
        #expect(track.sourceInfo.sampleRate == 96_000)

        let request = try #require(MockURLProtocol.requests.last)
        #expect(request.url?.lastPathComponent == "search3.view")
        let form = formValues(from: request)
        #expect(form["query"] == ["rain & night"])
        #expect(form["artistCount"] == ["3"])
        #expect(form["albumCount"] == ["4"])
        #expect(form["songCount"] == ["5"])
    }

    @Test("Phase 1 browsing endpoints decode empty and populated collections")
    func phaseOneEndpointMapping() async throws {
        let client = try await makeClient()

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""musicFolders":{"musicFolder":[{"id":"folder-1","name":"Main Library"}]}"#)),
        ])
        #expect(try await client.musicFolders() == [.init(id: "folder-1", name: "Main Library")])

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""artists":{"ignoredArticles":"The","index":[{"name":"N","artist":[{"id":"artist-1","name":"Night Artist","albumCount":1,"coverArt":"artist-cover"}]}]}"#)),
        ])
        let artists = try await client.artists(musicFolderID: "folder-1")
        #expect(artists.map(\.id) == [ArtistID(rawValue: "artist-1")])
        #expect(formValues(from: try #require(MockURLProtocol.requests.last))["musicFolderId"] == ["folder-1"])

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""artist":{"id":"artist-1","name":"Night Artist","albumCount":1,"album":[{"id":"album-1","name":"Blue Hour","artist":"Night Artist","artistId":"artist-1"}]}"#)),
        ])
        let artist = try await client.artist(id: "artist-1")
        #expect(artist.artist.id == ArtistID(rawValue: "artist-1"))
        #expect(artist.albums.map(\.id) == [AlbumID(rawValue: "album-1")])

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""album":{"id":"album-1","name":"Blue Hour","artist":"Night Artist","artistId":"artist-1","song":[{"id":"track-1","title":"Rain Signal","artist":"Night Artist","artistId":"artist-1","album":"Blue Hour","albumId":"album-1","duration":241}]}"#)),
        ])
        let album = try await client.album(id: "album-1")
        #expect(album.album.id == AlbumID(rawValue: "album-1"))
        #expect(album.tracks.map(\.id) == [TrackID(rawValue: "track-1")])

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""song":{"id":"track-1","title":"Rain Signal","artist":"Night Artist","artistId":"artist-1","album":"Blue Hour","albumId":"album-1","duration":241}"#)),
        ])
        #expect(try await client.song(id: "track-1").id == TrackID(rawValue: "track-1"))

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""genres":{"genre":[{"songCount":12,"albumCount":3,"value":"Ambient"}]}"#)),
        ])
        #expect(try await client.genres() == [Genre(name: "Ambient", songCount: 12)])

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""albumList2":{"album":[{"id":"album-1","name":"Blue Hour","artist":"Night Artist","artistId":"artist-1"}]}"#)),
        ])
        #expect(try await client.albums(type: .newest, size: 25).map(\.id) == [AlbumID(rawValue: "album-1")])

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""randomSongs":{"song":[{"id":"track-1","title":"Rain Signal","artist":"Night Artist","artistId":"artist-1","album":"Blue Hour","albumId":"album-1"}]}"#)),
        ])
        #expect(try await client.randomSongs(size: 1).map(\.id) == [TrackID(rawValue: "track-1")])

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""starred2":{"artist":[{"id":"artist-1","name":"Night Artist"}],"album":[],"song":[{"id":"track-1","title":"Rain Signal","starred":"2026-01-01"}]}"#)),
        ])
        let starred = try await client.starred()
        #expect(starred.artists.count == 1)
        #expect(starred.tracks.first?.isFavorite == true)

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""playlists":{"playlist":[{"id":"playlist-1","name":"Night Drive","comment":"Quiet"}]}"#)),
        ])
        #expect(try await client.playlists().map(\.id) == [PlaylistID(rawValue: "playlist-1")])

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""playlist":{"id":"playlist-1","name":"Night Drive","entry":[{"id":"track-1","title":"Rain Signal"}]}"#)),
        ])
        let playlist = try await client.playlist(id: "playlist-1")
        #expect(playlist.playlist.trackIDs == [TrackID(rawValue: "track-1")])
        #expect(playlist.tracks.map(\.id) == [TrackID(rawValue: "track-1")])
    }

    @Test("getPlaylists filters folder/group pseudo-playlists but keeps real empty playlists")
    func playlistFolderFiltering() async throws {
        let client = try await makeClient()

        // 1) 结构规则：服务器给真实歌单带必填元数据时，只有 id/name 的「分组」被过滤；
        //    真实空歌单（songCount=0 + created/changed）与带曲目的歌单均保留。
        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""playlists":{"playlist":[{"id":"folder-1","name":"我的分组"},{"id":"pl-1","name":"AuditForm2","songCount":0,"duration":0,"created":"2026-01-01T00:00:00Z","changed":"2026-01-02T00:00:00Z"},{"id":"pl-2","name":"Night Drive","songCount":12,"duration":3600,"created":"2026-01-01T00:00:00Z","changed":"2026-01-02T00:00:00Z"}]}"#)),
        ])
        #expect(try await client.playlists().map(\.id) == [
            PlaylistID(rawValue: "pl-1"), PlaylistID(rawValue: "pl-2")
        ])

        // 2) 命名规则：带歌单元数据但无曲目且名称像文件夹 → 过滤；
        //    带曲目的 "Group Therapy"（整词 group 命中但 songCount>0）与
        //    名称不含特征词的真实空歌单 "Chill" 保留。
        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""playlists":{"playlist":[{"id":"folder-2","name":"Work Folder","songCount":0,"duration":0,"created":"2026-01-01T00:00:00Z","changed":"2026-01-02T00:00:00Z"},{"id":"pl-3","name":"Group Therapy","songCount":2,"duration":600,"created":"2026-01-01T00:00:00Z","changed":"2026-01-02T00:00:00Z"},{"id":"pl-4","name":"Chill","songCount":0,"duration":0,"created":"2026-01-01T00:00:00Z","changed":"2026-01-02T00:00:00Z"}]}"#)),
        ])
        #expect(try await client.playlists().map(\.id) == [
            PlaylistID(rawValue: "pl-3"), PlaylistID(rawValue: "pl-4")
        ])

        // 3) 极小众服务器只返回 id/name/comment：不适用结构规则，全部保留，
        //    仅名称命中文件夹特征词的条目被命名规则过滤。
        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""playlists":{"playlist":[{"id":"min-1","name":"Minimal","comment":"c"},{"id":"min-2","name":"分组","comment":"folder"}]}"#)),
        ])
        #expect(try await client.playlists().map(\.id) == [PlaylistID(rawValue: "min-1")])

        // 4) 名称像文件夹但确实带曲目 → 视为真实歌单，保留（命名规则不误伤）。
        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""playlists":{"playlist":[{"id":"pl-5","name":"分组","songCount":3,"duration":900,"created":"2026-01-01T00:00:00Z","changed":"2026-01-02T00:00:00Z"}]}"#)),
        ])
        #expect(try await client.playlists().map(\.id) == [PlaylistID(rawValue: "pl-5")])
    }

    @Test("Playlist creation preserves repeated song IDs and their order")
    func repeatedPlaylistParameters() async throws {
        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""playlist":{"id":"playlist-1","name":"Ordered","entry":[{"id":"track-2","title":"Second"},{"id":"track-1","title":"First"}]}"#)),
        ])
        let client = try await makeClient()

        let result = try await client.createPlaylist(
            name: "Ordered & Calm",
            trackIDs: ["track-2", "track-1"]
        )

        #expect(result.playlist.id == PlaylistID(rawValue: "playlist-1"))
        let form = formValues(from: try #require(MockURLProtocol.requests.last))
        #expect(form["name"] == ["Ordered & Calm"])
        #expect(form["songId"] == ["track-2", "track-1"])
    }

    @Test("Read-only requests retry transient HTTP and URL failures")
    func retriesIdempotentRequests() async throws {
        MockURLProtocol.reset(stubs: [
            .error(.timedOut),
            .response(statusCode: 503, data: Data()),
            .response(data: ok()),
        ])
        let client = try await makeClient(
            retryPolicy: .init(maximumAttempts: 3, initialDelayNanoseconds: 0)
        )

        try await client.ping()
        #expect(MockURLProtocol.requests.count == 3)
    }

    @Test("Mutation requests are never blindly retried")
    func mutationsAreNotRetried() async throws {
        MockURLProtocol.reset(stubs: [
            .response(statusCode: 503, data: Data()),
            .response(data: ok()),
        ])
        let client = try await makeClient(
            retryPolicy: .init(maximumAttempts: 3, initialDelayNanoseconds: 0)
        )

        await #expect(throws: OpenSubsonicClientError.httpStatus(503)) {
            try await client.star(.track("track-1"))
        }
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test("Cancellation propagates while waiting for a retry")
    func cancellation() async throws {
        MockURLProtocol.reset(stubs: [
            .response(statusCode: 503, data: Data()),
            .response(data: ok()),
        ])
        let client = try await makeClient(
            retryPolicy: .init(maximumAttempts: 2, initialDelayNanoseconds: 1),
            sleeper: { _ in try await Task.sleep(nanoseconds: 30_000_000_000) }
        )
        let task = Task { try await client.ping() }
        while MockURLProtocol.requests.isEmpty { await Task.yield() }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test("Binary media is returned unchanged while JSON errors are still decoded")
    func binaryResponse() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0x00])
        MockURLProtocol.reset(stubs: [
            .response(statusCode: 200, headers: ["Content-Type": "image/jpeg"], data: bytes),
        ])
        let client = try await makeClient()
        #expect(try await client.coverArt(id: "cover-1", size: 512) == bytes)
    }

    @Test("Malformed JSON is not accepted as a successful API response")
    func malformedJSON() async throws {
        MockURLProtocol.reset(stubs: [
            .response(data: jsonData("{not-json")),
        ])
        let client = try await makeClient()
        await #expect {
            try await client.ping()
        } throws: { error in
            guard case OpenSubsonicClientError.malformedResponse = error else { return false }
            return true
        }
    }

    @Test("Extensions, structured lyrics, queue, and similarity responses decode")
    func extensionEndpointMapping() async throws {
        let client = try await makeClient()

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""openSubsonicExtensions":[{"name":"songLyrics","versions":[1,2]},{"name":"indexBasedQueue","versions":[1]}]"#)),
        ])
        let capabilities = try await client.capabilities()
        #expect(capabilities.supportsStructuredLyrics)
        #expect(capabilities.supportsIndexedQueue)
        #expect(!capabilities.supportsSonicSimilarity)

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""lyricsList":{"structuredLyrics":[{"displayArtist":"Artist","displayTitle":"Song","lang":"zh","synced":true,"line":[{"start":1500,"value":"First line"},{"start":3000,"value":"Second line"}]}]}"#)),
        ])
        let lyrics = try await client.structuredLyrics(trackID: "track-1")
        #expect(lyrics.first?.isSynced == true)
        #expect(lyrics.first?.lines.first?.startTime == 1.5)

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""playQueue":{"current":"track-1","position":42000,"entry":[{"id":"track-1","title":"Song"}]}"#)),
        ])
        let queue = try await client.playQueue()
        #expect(queue.currentTrackID == TrackID(rawValue: "track-1"))
        #expect(queue.positionMilliseconds == 42_000)

        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""similarSongs2":{"song":[{"id":"track-2","title":"Similar"}]}"#)),
        ])
        #expect(try await client.similarSongs(trackID: "track-1", count: 1).map(\.id) == ["track-2"])
    }

    @Test("Invalid endpoint parameters fail before network I/O")
    func parameterValidation() async throws {
        MockURLProtocol.reset(stubs: [])
        let client = try await makeClient()

        await #expect(throws: OpenSubsonicClientError.invalidParameter("fromYear/toYear")) {
            _ = try await client.albums(type: .byYear)
        }
        await #expect(throws: OpenSubsonicClientError.invalidParameter("rating")) {
            try await client.setRating(6, trackID: "track-1")
        }
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test("Traditional getLyrics maps plain-text value into unsynced document")
    func traditionalLyricsMapping() async throws {
        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""lyrics":{"artist":"Echo Quartet","title":"Velvet Steps","value":"Velvet steps on marble floors\nSoftly knocking at the doors"}"#)),
        ])
        let client = try await makeClient()

        let document = try await client.traditionalLyrics(
            artist: "Echo Quartet",
            title: "Velvet Steps",
            trackID: TrackID(rawValue: "track-1")
        )

        let lyrics = try #require(document)
        #expect(!lyrics.isSynced)
        #expect(lyrics.lines.count == 2)
        #expect(lyrics.lines.first?.text == "Velvet steps on marble floors")

        let request = try #require(MockURLProtocol.requests.last)
        #expect(request.url?.lastPathComponent == "getLyrics.view")
        let form = formValues(from: request)
        #expect(form["artist"] == ["Echo Quartet"])
        #expect(form["title"] == ["Velvet Steps"])
    }

    @Test("Traditional getLyrics returns nil when server has no value")
    func traditionalLyricsEmpty() async throws {
        MockURLProtocol.reset(stubs: [
            .response(data: ok(#""lyrics":{"value":""}"#)),
        ])
        let client = try await makeClient()

        let document = try await client.traditionalLyrics(
            artist: "Echo Quartet",
            title: "No Lyrics",
            trackID: TrackID(rawValue: "track-1")
        )

        #expect(document == nil)
    }

    @Test("Empty artist or title skips traditional lyrics without network I/O")
    func traditionalLyricsSkipsEmptyIdentity() async throws {
        MockURLProtocol.reset(stubs: [])
        let client = try await makeClient()

        let blank = try await client.traditionalLyrics(
            artist: "  ",
            title: "Song",
            trackID: TrackID(rawValue: "track-1")
        )
        #expect(blank == nil)
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test("Scrobble sends submission=true for completed playback")
    func scrobbleSubmissionTrue() async throws {
        MockURLProtocol.reset(stubs: [
            .response(data: ok()),
        ])
        let client = try await makeClient()

        try await client.scrobble(trackIDs: [TrackID(rawValue: "track-1")], submission: true)

        let request = try #require(MockURLProtocol.requests.last)
        #expect(request.url?.lastPathComponent == "scrobble.view")
        let form = formValues(from: request)
        #expect(form["id"] == ["track-1"])
        #expect(form["submission"] == ["true"])
    }

    private func makeClient(
        retryPolicy: OpenSubsonicRetryPolicy = .disabled,
        sleeper: @escaping OpenSubsonicClient.Sleeper = { _ in }
    ) async throws -> OpenSubsonicClient {
        let vault = InMemoryCredentialVault()
        let credentialID = CredentialID(rawValue: "test-password")
        try await vault.store("fixture-password", for: credentialID)
        return OpenSubsonicClient(
            configuration: OpenSubsonicConfiguration(
                serverID: "server-a",
                baseURL: try #require(URL(string: "https://music.example.test/base")),
                authentication: .token(username: "fixture-user", credentialID: credentialID)
            ),
            credentialVault: vault,
            session: makeMockSession(),
            retryPolicy: retryPolicy,
            saltGenerator: { "abcdef" },
            sleeper: sleeper
        )
    }

    private func ok(_ payload: String? = nil) -> Data {
        let suffix = payload.map { ",\($0)" } ?? ""
        return jsonData(#"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"FixtureServer","serverVersion":"1.0","openSubsonic":true"# + suffix + "}}")
    }
}
