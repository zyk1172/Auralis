import Domain
import Foundation
import SecurityKit

public final class OpenSubsonicClient: OpenSubsonicServing, Sendable {
    public typealias SaltGenerator = @Sendable () -> String
    public typealias Sleeper = @Sendable (UInt64) async throws -> Void

    public let configuration: OpenSubsonicConfiguration

    private let credentialVault: any CredentialVault
    private let session: URLSession
    private let retryPolicy: OpenSubsonicRetryPolicy
    private let saltGenerator: SaltGenerator
    private let sleeper: Sleeper
    private let mapper: OpenSubsonicDomainMapper

    public init(
        configuration: OpenSubsonicConfiguration,
        credentialVault: any CredentialVault,
        session: URLSession = .shared,
        retryPolicy: OpenSubsonicRetryPolicy = .standard,
        saltGenerator: @escaping SaltGenerator = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        },
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.configuration = configuration
        self.credentialVault = credentialVault
        self.session = session
        self.retryPolicy = retryPolicy
        self.saltGenerator = saltGenerator
        self.sleeper = sleeper
        self.mapper = OpenSubsonicDomainMapper(serverID: configuration.serverID)
    }

    public func ping() async throws {
        _ = try await serverInfo()
    }

    /// 构造带认证参数的 stream URL，供 AVPlayer 直接播放。
    /// - Parameters:
    ///   - maxBitRate: 可选码率上限（服务器转码）。nil 表示服务器原始质量。
    ///   - format: 可选转码格式（如 "mp3"）。仅当同时指定 maxBitRate 时生效。
    public func makeStreamURL(trackID: String, maxBitRate: Int? = nil, format: String? = nil) async throws -> URL {
        let auth = try await authenticationParameters()
        let endpointURL = try OpenSubsonicRequestFactory.endpointURL(
            baseURL: configuration.baseURL,
            endpoint: .stream
        )
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        var items = auth.map { URLQueryItem(name: $0.name, value: $0.value) }
        items.append(URLQueryItem(name: "id", value: trackID))
        if let maxBitRate { items.append(URLQueryItem(name: "maxBitRate", value: String(maxBitRate))) }
        if let format, maxBitRate != nil { items.append(URLQueryItem(name: "format", value: format)) }
        items.append(URLQueryItem(name: "v", value: configuration.protocolVersion))
        items.append(URLQueryItem(name: "c", value: configuration.clientName))
        components?.queryItems = items
        guard let url = components?.url else {
            throw OpenSubsonicClientError.invalidBaseURL
        }
        return url
    }

    public func serverInfo() async throws -> OpenSubsonicServerInfo {
        let response = try await response(for: OpenSubsonicRequestFactory.descriptor(.ping))
        return OpenSubsonicServerInfo(
            protocolVersion: response.version,
            serverType: response.type,
            serverVersion: response.serverVersion,
            isOpenSubsonic: response.openSubsonic ?? false
        )
    }

    public func extensions() async throws -> [OpenSubsonicExtension] {
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.getOpenSubsonicExtensions)
        )
        return response.openSubsonicExtensions ?? []
    }

    public func capabilities() async throws -> ServerCapabilities {
        CapabilityRegistry.capabilities(from: try await extensions())
    }

    public func musicFolders() async throws -> [OpenSubsonicMusicFolder] {
        let response = try await response(for: OpenSubsonicRequestFactory.descriptor(.getMusicFolders))
        guard let folders = response.musicFolders else {
            throw OpenSubsonicClientError.missingPayload("musicFolders")
        }
        return (folders.musicFolder ?? []).map { .init(id: $0.id.value, name: $0.name) }
    }

    public func artists(musicFolderID: String? = nil) async throws -> [Artist] {
        var parameters: [String: String] = [:]
        if let musicFolderID { parameters["musicFolderId"] = musicFolderID }
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.getArtists, parameters: parameters)
        )
        guard let artists = response.artists else {
            throw OpenSubsonicClientError.missingPayload("artists")
        }
        return (artists.index ?? [])
            .flatMap { $0.artist ?? [] }
            .map(mapper.artist)
    }

    public func artist(id: ArtistID) async throws -> OpenSubsonicArtistDetail {
        try await artist(id: id.rawValue)
    }

    public func artist(id: String) async throws -> OpenSubsonicArtistDetail {
        try requireNonEmpty(id, name: "id")
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.getArtist, parameters: ["id": id])
        )
        guard let value = response.artist else {
            throw OpenSubsonicClientError.missingPayload("artist")
        }
        return OpenSubsonicArtistDetail(
            artist: mapper.artist(value),
            albums: (value.album ?? []).map(mapper.album)
        )
    }

    public func album(id: AlbumID) async throws -> OpenSubsonicAlbumDetail {
        try await album(id: id.rawValue)
    }

    public func album(id: String) async throws -> OpenSubsonicAlbumDetail {
        try requireNonEmpty(id, name: "id")
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.getAlbum, parameters: ["id": id])
        )
        guard let value = response.album else {
            throw OpenSubsonicClientError.missingPayload("album")
        }
        return OpenSubsonicAlbumDetail(
            album: mapper.album(value),
            tracks: (value.song ?? []).map(mapper.track)
        )
    }

    public func song(id: TrackID) async throws -> Track {
        try await song(id: id.rawValue)
    }

    public func song(id: String) async throws -> Track {
        try requireNonEmpty(id, name: "id")
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.getSong, parameters: ["id": id])
        )
        guard let value = response.song else {
            throw OpenSubsonicClientError.missingPayload("song")
        }
        return mapper.track(value)
    }

    public func genres() async throws -> [Genre] {
        let response = try await response(for: OpenSubsonicRequestFactory.descriptor(.getGenres))
        guard let genres = response.genres else {
            throw OpenSubsonicClientError.missingPayload("genres")
        }
        return (genres.genre ?? []).map {
            Genre(name: $0.value, songCount: $0.songCount ?? 0)
        }
    }

    public func albums(
        type: OpenSubsonicAlbumListType,
        size: Int = 50,
        offset: Int = 0,
        fromYear: Int? = nil,
        toYear: Int? = nil,
        genre: String? = nil,
        musicFolderID: String? = nil
    ) async throws -> [Album] {
        try requireRange(size, 1...500, name: "size")
        try requireRange(offset, 0...Int.max, name: "offset")
        if type == .byYear, fromYear == nil || toYear == nil {
            throw OpenSubsonicClientError.invalidParameter("fromYear/toYear")
        }
        if type == .byGenre, genre?.isEmpty != false {
            throw OpenSubsonicClientError.invalidParameter("genre")
        }

        var parameters = [
            "type": type.rawValue,
            "size": String(size),
            "offset": String(offset),
        ]
        if let fromYear { parameters["fromYear"] = String(fromYear) }
        if let toYear { parameters["toYear"] = String(toYear) }
        if let genre { parameters["genre"] = genre }
        if let musicFolderID { parameters["musicFolderId"] = musicFolderID }

        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.getAlbumList2, parameters: parameters)
        )
        guard let albumList = response.albumList2 else {
            throw OpenSubsonicClientError.missingPayload("albumList2")
        }
        return (albumList.album ?? []).map(mapper.album)
    }

    public func randomSongs(
        size: Int = 50,
        genre: String? = nil,
        fromYear: Int? = nil,
        toYear: Int? = nil,
        musicFolderID: String? = nil
    ) async throws -> [Track] {
        try requireRange(size, 1...500, name: "size")
        var parameters = ["size": String(size)]
        if let genre { parameters["genre"] = genre }
        if let fromYear { parameters["fromYear"] = String(fromYear) }
        if let toYear { parameters["toYear"] = String(toYear) }
        if let musicFolderID { parameters["musicFolderId"] = musicFolderID }

        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.getRandomSongs, parameters: parameters)
        )
        guard let songs = response.randomSongs else {
            throw OpenSubsonicClientError.missingPayload("randomSongs")
        }
        return (songs.song ?? []).map(mapper.track)
    }

    public func starred(musicFolderID: String? = nil) async throws -> OpenSubsonicStarred {
        var parameters: [String: String] = [:]
        if let musicFolderID { parameters["musicFolderId"] = musicFolderID }
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.getStarred2, parameters: parameters)
        )
        guard let starred = response.starred2 else {
            throw OpenSubsonicClientError.missingPayload("starred2")
        }
        return OpenSubsonicStarred(
            artists: (starred.artist ?? []).map(mapper.artist),
            albums: (starred.album ?? []).map(mapper.album),
            tracks: (starred.song ?? []).map(mapper.track)
        )
    }

    public func search(
        query: String,
        artistCount: Int = 20,
        artistOffset: Int = 0,
        albumCount: Int = 20,
        albumOffset: Int = 0,
        songCount: Int = 100,
        songOffset: Int = 0,
        musicFolderID: String? = nil
    ) async throws -> OpenSubsonicSearchResult {
        for (name, value) in [
            ("artistCount", artistCount), ("albumCount", albumCount), ("songCount", songCount),
        ] {
            try requireRange(value, 0...500, name: name)
        }
        for (name, value) in [
            ("artistOffset", artistOffset), ("albumOffset", albumOffset), ("songOffset", songOffset),
        ] {
            try requireRange(value, 0...Int.max, name: name)
        }

        var parameters = [
            "query": query,
            "artistCount": String(artistCount),
            "artistOffset": String(artistOffset),
            "albumCount": String(albumCount),
            "albumOffset": String(albumOffset),
            "songCount": String(songCount),
            "songOffset": String(songOffset),
        ]
        if let musicFolderID { parameters["musicFolderId"] = musicFolderID }

        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.search3, parameters: parameters)
        )
        guard let result = response.searchResult3 else {
            throw OpenSubsonicClientError.missingPayload("searchResult3")
        }
        return OpenSubsonicSearchResult(
            artists: (result.artist ?? []).map(mapper.artist),
            albums: (result.album ?? []).map(mapper.album),
            tracks: (result.song ?? []).map(mapper.track)
        )
    }

    public func playlists(username: String? = nil) async throws -> [Playlist] {
        var parameters: [String: String] = [:]
        if let username { parameters["username"] = username }
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.getPlaylists, parameters: parameters)
        )
        guard let playlists = response.playlists else {
            throw OpenSubsonicClientError.missingPayload("playlists")
        }
        return (playlists.playlist ?? []).map(mapper.playlist)
    }

    public func playlist(id: PlaylistID) async throws -> OpenSubsonicPlaylistDetail {
        try await playlist(id: id.rawValue)
    }

    public func playlist(id: String) async throws -> OpenSubsonicPlaylistDetail {
        try requireNonEmpty(id, name: "id")
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.getPlaylist, parameters: ["id": id])
        )
        guard let value = response.playlist else {
            throw OpenSubsonicClientError.missingPayload("playlist")
        }
        return playlistDetail(value)
    }

    public func createPlaylist(name: String, trackIDs: [TrackID] = []) async throws -> OpenSubsonicPlaylistDetail {
        try requireNonEmpty(name, name: "name")
        var items = [OpenSubsonicParameter("name", name)]
        items.append(contentsOf: trackIDs.map { .init("songId", $0.rawValue) })
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(.createPlaylist, parameterItems: items)
        )
        guard let value = response.playlist else {
            throw OpenSubsonicClientError.missingPayload("playlist")
        }
        return playlistDetail(value)
    }

    public func updatePlaylist(
        id: PlaylistID,
        name: String? = nil,
        comment: String? = nil,
        isPublic: Bool? = nil,
        appendTrackIDs: [TrackID] = [],
        removeIndexes: [Int] = []
    ) async throws {
        if let name { try requireNonEmpty(name, name: "name") }
        guard removeIndexes.allSatisfy({ $0 >= 0 }) else {
            throw OpenSubsonicClientError.invalidParameter("songIndexToRemove")
        }

        var items = [OpenSubsonicParameter("playlistId", id.rawValue)]
        if let name { items.append(.init("name", name)) }
        if let comment { items.append(.init("comment", comment)) }
        if let isPublic { items.append(.init("public", String(isPublic))) }
        items.append(contentsOf: appendTrackIDs.map { .init("songIdToAdd", $0.rawValue) })
        items.append(contentsOf: removeIndexes.map { .init("songIndexToRemove", String($0)) })
        _ = try await execute(OpenSubsonicRequestFactory.descriptor(.updatePlaylist, parameterItems: items))
    }

    public func deletePlaylist(id: PlaylistID) async throws {
        _ = try await execute(
            OpenSubsonicRequestFactory.descriptor(.deletePlaylist, parameters: ["id": id.rawValue])
        )
    }

    public func star(_ target: OpenSubsonicFavoriteTarget) async throws {
        _ = try await execute(
            OpenSubsonicRequestFactory.descriptor(.star, parameterItems: [target.parameter])
        )
    }

    public func unstar(_ target: OpenSubsonicFavoriteTarget) async throws {
        _ = try await execute(
            OpenSubsonicRequestFactory.descriptor(.unstar, parameterItems: [target.parameter])
        )
    }

    public func setRating(_ rating: Int, trackID: TrackID) async throws {
        try requireRange(rating, 0...5, name: "rating")
        _ = try await execute(
            OpenSubsonicRequestFactory.descriptor(
                .setRating,
                parameters: ["id": trackID.rawValue, "rating": String(rating)]
            )
        )
    }

    public func coverArt(id: String, size: Int? = nil) async throws -> Data {
        try requireNonEmpty(id, name: "id")
        var parameters = ["id": id]
        if let size {
            try requireRange(size, 1...4096, name: "size")
            parameters["size"] = String(size)
        }
        return try await execute(
            OpenSubsonicRequestFactory.descriptor(.getCoverArt, parameters: parameters)
        )
    }

    public func stream(
        trackID: TrackID,
        maxBitRate: Int? = nil,
        format: String? = nil,
        estimateContentLength: Bool? = nil,
        timeOffset: Double? = nil
    ) async throws -> Data {
        var parameters = ["id": trackID.rawValue]
        if let maxBitRate { parameters["maxBitRate"] = String(maxBitRate) }
        if let format { parameters["format"] = format }
        if let estimateContentLength { parameters["estimateContentLength"] = String(estimateContentLength) }
        if let timeOffset { parameters["timeOffset"] = String(timeOffset) }
        return try await execute(OpenSubsonicRequestFactory.descriptor(.stream, parameters: parameters))
    }

    /// 构造带认证参数的 download URL（用于后台下载任务，可在系统挂起后继续）。
    public func makeDownloadURL(trackID: String) async throws -> URL {
        let auth = try await authenticationParameters()
        let endpointURL = try OpenSubsonicRequestFactory.endpointURL(
            baseURL: configuration.baseURL,
            endpoint: .download
        )
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        var items = auth.map { URLQueryItem(name: $0.name, value: $0.value) }
        items.append(URLQueryItem(name: "id", value: trackID))
        items.append(URLQueryItem(name: "v", value: configuration.protocolVersion))
        items.append(URLQueryItem(name: "c", value: configuration.clientName))
        components?.queryItems = items
        guard let url = components?.url else {
            throw OpenSubsonicClientError.invalidBaseURL
        }
        return url
    }

    public func download(trackID: TrackID) async throws -> Data {
        try await execute(
            OpenSubsonicRequestFactory.descriptor(.download, parameters: ["id": trackID.rawValue])
        )
    }

    public func structuredLyrics(trackID: TrackID, enhanced: Bool = false) async throws -> [LyricsDocument] {
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(
                .getLyricsBySongId,
                parameters: ["id": trackID.rawValue, "enhanced": String(enhanced)]
            )
        )
        guard let lyricsList = response.lyricsList else {
            throw OpenSubsonicClientError.missingPayload("lyricsList")
        }
        return (lyricsList.structuredLyrics ?? []).map { lyrics in
            LyricsDocument(
                trackID: trackID,
                language: lyrics.lang,
                lines: (lyrics.line ?? []).map { line in
                    TimedLyricLine(
                        startTime: line.start.map { TimeInterval($0) / 1_000 },
                        text: line.value
                    )
                },
                isSynced: lyrics.synced ?? false
            )
        }
    }

    /// 传统 getLyrics（按 artist + title）拉取纯文本歌词，兼容 Navidrome 等服务器
    /// 在 getLyricsBySongId 无结构化歌词但存在内嵌/外部纯文本歌词的场景。
    /// 服务器无歌词或 value 为空时返回 nil；请求失败时抛出错误。
    public func traditionalLyrics(artist: String, title: String, trackID: TrackID) async throws -> LyricsDocument? {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty, !trimmedTitle.isEmpty else { return nil }
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(
                .getLyrics,
                parameters: ["artist": trimmedArtist, "title": trimmedTitle]
            )
        )
        guard let value = response.lyrics?.value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let lines = value
            .components(separatedBy: .newlines)
            .map { TimedLyricLine(text: $0) }
        return LyricsDocument(trackID: trackID, language: nil, lines: lines, isSynced: false)
    }

    public func scrobble(
        trackIDs: [TrackID],
        times: [Date] = [],
        submission: Bool = true
    ) async throws {
        guard !trackIDs.isEmpty else { throw OpenSubsonicClientError.invalidParameter("id") }
        guard times.isEmpty || times.count == trackIDs.count else {
            throw OpenSubsonicClientError.invalidParameter("time")
        }
        var items = trackIDs.map { OpenSubsonicParameter("id", $0.rawValue) }
        items.append(contentsOf: times.map {
            .init("time", String(Int($0.timeIntervalSince1970 * 1_000)))
        })
        items.append(.init("submission", String(submission)))
        _ = try await execute(OpenSubsonicRequestFactory.descriptor(.scrobble, parameterItems: items))
    }

    public func playQueue() async throws -> OpenSubsonicPlayQueue {
        let response = try await response(for: OpenSubsonicRequestFactory.descriptor(.getPlayQueue))
        guard let queue = response.playQueue else {
            throw OpenSubsonicClientError.missingPayload("playQueue")
        }
        return OpenSubsonicPlayQueue(
            tracks: (queue.entry ?? []).map(mapper.track),
            currentTrackID: queue.current.map(TrackID.init(rawValue:)),
            positionMilliseconds: queue.position
        )
    }

    public func savePlayQueue(
        trackIDs: [TrackID],
        currentTrackID: TrackID? = nil,
        positionMilliseconds: Int? = nil
    ) async throws {
        guard positionMilliseconds.map({ $0 >= 0 }) ?? true else {
            throw OpenSubsonicClientError.invalidParameter("position")
        }
        var items = trackIDs.map { OpenSubsonicParameter("id", $0.rawValue) }
        if let currentTrackID { items.append(.init("current", currentTrackID.rawValue)) }
        if let positionMilliseconds { items.append(.init("position", String(positionMilliseconds))) }
        _ = try await execute(
            OpenSubsonicRequestFactory.descriptor(.savePlayQueue, parameterItems: items)
        )
    }

    public func similarSongs(
        trackID: TrackID,
        count: Int = 50
    ) async throws -> [Track] {
        try requireRange(count, 1...500, name: "count")
        let response = try await response(
            for: OpenSubsonicRequestFactory.descriptor(
                .getSimilarSongs2,
                parameters: ["id": trackID.rawValue, "count": String(count)]
            )
        )
        guard let songs = response.similarSongs2 else {
            throw OpenSubsonicClientError.missingPayload("similarSongs2")
        }
        return (songs.song ?? []).map(mapper.track)
    }

    /// 解析 Subsonic 错误响应中的 message（支持 {"subsonic-response":{"error":{"message":"..."}}} 与 {"error":{"message":"..."}}）。
    nonisolated private static func serverErrorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let nested = (obj["subsonic-response"] as? [String: Any]) ?? obj
        guard let error = nested["error"] as? [String: Any],
              let message = error["message"] as? String, !message.isEmpty
        else { return nil }
        return message
    }

    /// Builds a request containing derived authentication material. Callers must
    /// never log, persist, or surface its body or headers.
    public func makeURLRequest(for descriptor: OpenSubsonicRequestDescriptor) async throws -> URLRequest {
        guard descriptor.method.uppercased() == "POST" else {
            throw OpenSubsonicClientError.invalidConfiguration("Only form POST is supported")
        }
        guard !configuration.clientName.isEmpty else {
            throw OpenSubsonicClientError.invalidConfiguration("clientName is empty")
        }
        guard !configuration.protocolVersion.isEmpty else {
            throw OpenSubsonicClientError.invalidConfiguration("protocolVersion is empty")
        }
        guard configuration.requestTimeout > 0 else {
            throw OpenSubsonicClientError.invalidConfiguration("requestTimeout must be positive")
        }

        let reserved = Set(["u", "p", "t", "s", "apikey"])
        guard !descriptor.parameterItems.contains(where: { reserved.contains($0.name.lowercased()) }) else {
            throw OpenSubsonicClientError.invalidParameter("authentication")
        }

        let global = Set(["c", "v", "f"])
        var items = descriptor.parameterItems.filter { !global.contains($0.name.lowercased()) }
        items.append(.init("c", configuration.clientName))
        items.append(.init("v", configuration.protocolVersion))
        items.append(.init("f", "json"))
        items.append(contentsOf: try await authenticationParameters())

        var request = URLRequest(
            url: try OpenSubsonicRequestFactory.endpointURL(
                baseURL: configuration.baseURL,
                endpoint: descriptor.endpoint
            )
        )
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, application/octet-stream;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        request.httpBody = OpenSubsonicFormEncoder.encode(items)
        return request
    }

    public func execute(_ descriptor: OpenSubsonicRequestDescriptor) async throws -> Data {
        let canRetry = isRetryable(descriptor.endpoint)
        var attempt = 1

        while true {
            try Task.checkCancellation()
            let request = try await makeURLRequest(for: descriptor)

            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw OpenSubsonicClientError.malformedResponse("非 HTTP 响应")
                }

                guard (200...299).contains(http.statusCode) else {
                    if canRetry, attempt < retryPolicy.maximumAttempts, isTransient(statusCode: http.statusCode) {
                        try await waitBeforeRetry(attempt: attempt)
                        attempt += 1
                        continue
                    }
                    // 优先透出服务器返回的具体错误信息（如「name is required」），
                    // 否则退化为仅状态码，方便用户/助手定位创建歌单等写操作失败的原因。
                    if let message = Self.serverErrorMessage(from: data) {
                        throw OpenSubsonicClientError.serverFailure(
                            OpenSubsonicServerError(code: http.statusCode, message: message)
                        )
                    }
                    throw OpenSubsonicClientError.httpStatus(http.statusCode)
                }

                try validateEnvelopeIfPresent(data: data, response: http)
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled, Task.isCancelled {
                    throw CancellationError()
                }
                if canRetry, attempt < retryPolicy.maximumAttempts, isTransient(error.code) {
                    try await waitBeforeRetry(attempt: attempt)
                    attempt += 1
                    continue
                }
                throw OpenSubsonicClientError.transport(code: error.errorCode, host: error.failingURL?.host)
            } catch let error as OpenSubsonicClientError {
                throw error
            } catch {
                let nsError = error as NSError
                let failingHost = nsError.userInfo[NSURLErrorFailingURLErrorKey].flatMap { ($0 as? URL)?.host } ?? (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host
                throw OpenSubsonicClientError.transport(code: nsError.code, host: failingHost)
            }
        }
    }

    private func authenticationParameters() async throws -> [OpenSubsonicParameter] {
        switch configuration.authentication {
        case let .token(username, credentialID):
            guard !username.isEmpty else {
                throw OpenSubsonicClientError.invalidConfiguration("username is empty")
            }
            let password = try await credentialVault.retrieve(id: credentialID)
            let salt = saltGenerator()
            guard salt.count >= 6 else {
                throw OpenSubsonicClientError.invalidConfiguration("salt must have at least six characters")
            }
            return [
                .init("u", username),
                .init("t", OpenSubsonicTokenSigner.token(password: password, salt: salt)),
                .init("s", salt),
            ]
        case let .apiKey(credentialID):
            let apiKey = try await credentialVault.retrieve(id: credentialID)
            guard !apiKey.isEmpty else {
                throw OpenSubsonicClientError.invalidConfiguration("API key is empty")
            }
            return [.init("apiKey", apiKey)]
        }
    }

    private func response(for descriptor: OpenSubsonicRequestDescriptor) async throws -> OpenSubsonicResponseDTO {
        let data = try await execute(descriptor)
        do {
            let response = try JSONDecoder().decode(OpenSubsonicEnvelope.self, from: data).response
            try validate(response)
            return response
        } catch let error as OpenSubsonicClientError {
            throw error
        } catch {
            // 不把服务器可控的原始响应体写进日志或错误信息（可能回显用户名/凭据，
            // 也可能是 HTML 错误页），只保留结构化摘要。
            throw OpenSubsonicClientError.malformedResponse("解析失败 \(error)")
        }
    }

    private func validateEnvelopeIfPresent(data: Data, response: HTTPURLResponse) throws {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let firstByte = data.first { !$0.isASCIIWhitespace }
        let isAmbiguousContent = contentType.isEmpty || contentType.hasPrefix("text/")
        let appearsJSON = contentType.contains("json") || (isAmbiguousContent && firstByte == 0x7B)
        guard appearsJSON else { return }

        do {
            let envelope = try JSONDecoder().decode(OpenSubsonicEnvelope.self, from: data)
            try validate(envelope.response)
        } catch let error as OpenSubsonicClientError {
            throw error
        } catch {
            throw OpenSubsonicClientError.malformedResponse("响应体验证失败: \(error)")
        }
    }

    private func validate(_ response: OpenSubsonicResponseDTO) throws {
        if let error = response.error {
            throw OpenSubsonicClientError.serverFailure(error.domainValue)
        }
        guard response.status?.lowercased() == "ok" else {
            throw OpenSubsonicClientError.malformedResponse("响应状态不是 ok: \(response.status ?? "nil")")
        }
    }

    private func playlistDetail(_ value: PlaylistDTO) -> OpenSubsonicPlaylistDetail {
        OpenSubsonicPlaylistDetail(
            playlist: mapper.playlist(value),
            tracks: (value.entry ?? []).map(mapper.track)
        )
    }

    private func isRetryable(_ endpoint: OpenSubsonicEndpoint) -> Bool {
        switch endpoint {
        case .createPlaylist, .updatePlaylist, .deletePlaylist,
             .star, .unstar, .setRating, .scrobble,
             .savePlayQueue, .savePlayQueueByIndex, .reportPlayback:
            false
        default:
            true
        }
    }

    private func isTransient(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private func isTransient(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed, .resourceUnavailable:
            true
        default:
            false
        }
    }

    private func waitBeforeRetry(attempt: Int) async throws {
        guard retryPolicy.initialDelayNanoseconds > 0 else { return }
        let multiplier = pow(retryPolicy.multiplier, Double(max(0, attempt - 1)))
        let calculated = Double(retryPolicy.initialDelayNanoseconds) * multiplier
        let capped = min(calculated, 30_000_000_000)
        try await sleeper(UInt64(capped))
    }

    private func requireNonEmpty(_ value: String, name: String) throws {
        guard !value.isEmpty else { throw OpenSubsonicClientError.invalidParameter(name) }
    }

    private func requireRange(_ value: Int, _ range: ClosedRange<Int>, name: String) throws {
        guard range.contains(value) else { throw OpenSubsonicClientError.invalidParameter(name) }
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
