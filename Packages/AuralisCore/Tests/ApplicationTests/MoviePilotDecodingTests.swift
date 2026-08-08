import Application
import Foundation
import Testing

// MARK: - Stub URLProtocol（测试用，串行执行）

/// 可脚本化响应的 URLProtocol：按 URL 注册 handler，并用锁保护静态字典。
/// Swift Testing 默认并行执行测试，共享可变状态必须串行化，否则测试间会互相覆盖响应。
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers:
        [String: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func register(
        url: URL,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.lock(); defer { lock.unlock() }
        handlers[url.absoluteString] = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        let handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        Self.lock.lock(); handler = Self.handlers[key]; Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeStubbedSession(
    url: URL,
    _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    StubURLProtocol.register(url: url, handler: handler)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - 宽松解码

@Suite("MoviePilot 插件响应宽松解码")
struct MoviePilotLooseDecodingTests {
    @Test("搜索候选：字符串数字/字符串布尔也能宽松解码（站点透传字段类型不稳定）")
    func decodeSearchWithLooseValues() throws {
        let json = """
        {
          "success": true,
          "message": null,
          "data": {
            "keyword": "周杰伦",
            "searched_sites": ["馒头", "PTzone"],
            "total": "2",
            "album_matched_any": "true",
            "dropped_video": "3",
            "dropped_uncertain": 1,
            "fallback_tried": false,
            "fallback_resolved": null,
            "fallback_album": "Capricorn",
            "kind": "album",
            "size_limit_gb": 8.0,
            "size_limit_applied": true,
            "results": [
              {
                "index": 1, "ref": "abc123:1", "site_id": "4", "site_name": "馒头",
                "title": "周杰伦 - 魔杰座 FLAC 分轨", "category": "未知",
                "music": "true", "confidence": "high", "audio_format": "FLAC",
                "quality": "90", "quality_label": "无损", "relevance": 70,
                "album_matched": "true",
                "size": "317860175", "size_text": "303.2 MB",
                "seeders": "34", "grabs": 12, "pubdate": "2021-08-05 20:24:32",
                "enclosure": "https://example.com/x.torrent"
              }
            ]
          }
        }
        """
        let envelope = try JSONDecoder().decode(
            MoviePilotEnvelope<MoviePilotSearchData>.self,
            from: Data(json.utf8)
        )
        #expect(envelope.success)
        let data = try #require(envelope.data)
        #expect(data.total == 2)
        #expect(data.albumMatchedAny == true)
        #expect(data.droppedVideo == 3)
        #expect(data.droppedUncertain == 1)
        #expect(data.fallbackTried == false)
        #expect(data.fallbackResolved == nil)
        #expect(data.fallbackAlbum == "Capricorn")
        #expect(data.kind == "album")
        #expect(data.sizeLimitGB == 8.0)
        #expect(data.sizeLimitApplied == true)
        #expect(data.searchedSites == ["馒头", "PTzone"])

        let first = try #require(data.results?.first)
        #expect(first.index == 1)
        #expect(first.ref == "abc123:1")
        #expect(first.siteId == 4)
        #expect(first.siteName == "馒头")
        #expect(first.music == true)
        #expect(first.confidence == "high")
        #expect(first.audioFormat == "FLAC")
        #expect(first.quality == 90)
        #expect(first.qualityLabel == "无损")
        #expect(first.relevance == 70)
        #expect(first.albumMatched == true)
        #expect(first.size == "317860175")
        #expect(first.sizeText == "303.2 MB")
        #expect(first.seeders == 34)
        #expect(first.grabs == 12)
        #expect(first.pubdate == "2021-08-05 20:24:32")
        #expect(first.enclosure == "https://example.com/x.torrent")
    }

    @Test("候选缺失字段保持可选容错，不整体抛解析失败")
    func decodeCandidateWithMissingFields() throws {
        let json = """
        {
          "success": true,
          "data": {
            "keyword": "Adele",
            "total": 1,
            "album_matched_any": false,
            "results": [
              { "index": 1, "ref": "x:1", "site_name": "PTzone", "title": "Adele - 25" }
            ]
          }
        }
        """
        let envelope = try JSONDecoder().decode(
            MoviePilotEnvelope<MoviePilotSearchData>.self,
            from: Data(json.utf8)
        )
        let data = try #require(envelope.data)
        let first = try #require(data.results?.first)
        #expect(first.title == "Adele - 25")
        #expect(first.quality == nil)
        #expect(first.seeders == nil)
        #expect(first.grabs == nil)
        #expect(first.music == nil)
        #expect(first.sizeText == nil)
    }

    @Test("下载成功响应含 content_verified / size_text 可解析")
    func decodeDownloadData() throws {
        let json = """
        {
          "success": true,
          "data": {
            "hash": "9f121b25",
            "save_path": "/media/音乐",
            "label": "音乐,musicdownloader",
            "status": "downloading",
            "content_verified": true,
            "matched_files": ["01 晴天.flac"],
            "size_text": "303.2 MB"
          }
        }
        """
        let envelope = try JSONDecoder().decode(
            MoviePilotEnvelope<MoviePilotDownloadData>.self,
            from: Data(json.utf8)
        )
        let data = try #require(envelope.data)
        #expect(data.hash == "9f121b25")
        #expect(data.savePath == "/media/音乐")
        #expect(data.contentVerified == true)
        #expect(data.matchedFiles == ["01 晴天.flac"])
        #expect(data.sizeText == "303.2 MB")
    }

    @Test("2xx 搜索经客户端完整链路宽松解码成功")
    func searchSucceedsThroughClient() async throws {
        let session = makeStubbedSession(url: URL(string: "http://mp-200.test/api/v1/plugin/MusicDownloader/search")!) { request in
            let body = """
            {"success": true, "data": { "keyword": "Adele 25", "total": "1", "album_matched_any": "true",
              "dropped_video": "0", "kind": "album", "size_limit_gb": 8.0,
              "results": [ { "index": "1", "ref": "x:1", "site_id": "4", "site_name": "馒头",
                "title": "Adele - 25 (2015) FLAC", "music": "true", "confidence": "high",
                "audio_format": "FLAC", "quality": "90", "quality_label": "无损", "relevance": "90",
                "album_matched": "true", "size": "123456", "size_text": "117.7 MB",
                "seeders": "12", "grabs": "3" } ] } }
            """
            let response = HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let client = MoviePilotClient(session: session)
        let connection = MoviePilotConnection(baseURL: URL(string: "http://mp-200.test")!, token: "token")
        let data = try await client.search(
            connection, artist: "Adele", album: "25", albumAliases: [],
            keyword: nil, year: 2015, limit: 10, preferLossless: true, minSeeders: 1
        )
        #expect(data.total == 1)
        #expect(data.albumMatchedAny == true)
        #expect(data.sizeLimitGB == 8.0)
        let first = try #require(data.results?.first)
        #expect(first.quality == 90)
        #expect(first.seeders == 12)
        #expect(first.grabs == 3)
        #expect(first.music == true)
    }
}

// MARK: - 错误 envelope

@Suite("MoviePilot 非 2xx 错误透传")
struct MoviePilotErrorEnvelopeTests {
    @Test("401 时解析插件错误 envelope，用户能看到「apikey 校验不通过」而非笼统 HTTP 401")
    func non2xxParsesPluginErrorEnvelope() async throws {
        let session = makeStubbedSession(url: URL(string: "http://mp-401.test/api/v1/plugin/MusicDownloader/test")!) { request in
            let body = #"{"success": false, "message": "apikey 校验不通过", "data": {}}"#
            let response = HTTPURLResponse(url: try #require(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let client = MoviePilotClient(session: session)
        let connection = MoviePilotConnection(baseURL: URL(string: "http://mp-401.test")!, token: "bad-token")
        do {
            _ = try await client.test(connection)
            Issue.record("应当抛出 MoviePilotError")
        } catch let error as MoviePilotError {
            #expect(error == .pluginFailed("apikey 校验不通过"))
            let text = error.localizedDescription ?? ""
            #expect(text.contains("apikey 校验不通过"))
            #expect(text.contains("Token"))
        } catch {
            Issue.record("抛出错误类型不对：\(error)")
        }
    }

    @Test("非 2xx 且响应不是插件 envelope 时回退到 transport(HTTP status)")
    func non2xxFallsBackToTransportWhenNotEnvelope() async throws {
        let session = makeStubbedSession(url: URL(string: "http://mp-502.test/api/v1/plugin/MusicDownloader/test")!) { request in
            let body = "<html>Bad Gateway</html>"
            let response = HTTPURLResponse(url: try #require(request.url), statusCode: 502, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let client = MoviePilotClient(session: session)
        let connection = MoviePilotConnection(baseURL: URL(string: "http://mp-502.test")!, token: "token")
        do {
            _ = try await client.test(connection)
            Issue.record("应当抛出 MoviePilotError")
        } catch let error as MoviePilotError {
            #expect(error == .transport("HTTP 502"))
            #expect((error.localizedDescription ?? "").contains("502"))
        } catch {
            Issue.record("抛出错误类型不对：\(error)")
        }
    }

    @Test("2xx 业务失败（success=false）抛出插件业务错误")
    func twoHundredBusinessFailure() async throws {
        let session = makeStubbedSession(url: URL(string: "http://mp-biz.test/api/v1/plugin/MusicDownloader/test")!) { request in
            let body = #"{"success": false, "message": "音乐下载目录未通过校验: /bad", "data": {}}"#
            let response = HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let client = MoviePilotClient(session: session)
        let connection = MoviePilotConnection(baseURL: URL(string: "http://mp-biz.test")!, token: "token")
        do {
            _ = try await client.test(connection)
            Issue.record("应当抛出 MoviePilotError")
        } catch let error as MoviePilotError {
            #expect(error == .pluginFailed("音乐下载目录未通过校验: /bad"))
        } catch {
            Issue.record("抛出错误类型不对：\(error)")
        }
    }
}
