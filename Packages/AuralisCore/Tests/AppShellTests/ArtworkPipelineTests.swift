@testable import AppShell
import Application
import CoreGraphics
import Domain
import Foundation
import ImageIO
import ImagePipeline
import Testing

private actor ArtworkCountingConnector: ServerConnecting {
    private let data: Data
    private var artworkCalls = 0

    init(data: Data) {
        self.data = data
    }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw ServerConnectionError.serverUnavailable
    }

    func restoreLastConnection() async throws -> ServerConnectionResult? { nil }

    func artworkData(serverID: ServerID, key: String, targetPixelSize: Int) async -> Data? {
        artworkCalls += 1
        try? await Task.sleep(for: .milliseconds(40))
        return data
    }

    func callCount() -> Int { artworkCalls }
}

private func artworkTestData(
    width: Int = 1_024,
    height: Int = 640,
    red: CGFloat = 0.2,
    green: CGFloat = 0.45,
    blue: CGFloat = 0.8
) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw ArtworkTestError.cannotCreateImage
    }
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { throw ArtworkTestError.cannotCreateImage }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        "public.jpeg" as CFString,
        1,
        nil
    ) else {
        throw ArtworkTestError.cannotEncodeImage
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ArtworkTestError.cannotEncodeImage }
    return output as Data
}

private enum ArtworkTestError: Error {
    case cannotCreateImage
    case cannotEncodeImage
}

private func temporaryArtworkCache() -> ArtworkDiskCache {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-artwork-pipeline-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return ArtworkDiskCache(directory: directory, budget: 8 * 1024 * 1024)
}

@Test("ImageIO 直接把大封面下采样到目标像素以内")
func artworkDecoderDownsamplesWithoutFullSizeBitmap() async throws {
    let decoded = await ArtworkImageDecoder().decode(
        try artworkTestData(),
        maxPixelSize: 160
    )

    let image = try #require(decoded)
    #expect(max(image.pixelWidth, image.pixelHeight) <= 160)
    #expect(image.pixelWidth > image.pixelHeight)
    #expect(image.memoryCost == image.pixelWidth * image.pixelHeight * 4)
}

@Test("同一封面并发加载只回源一次，并写入磁盘缓存")
func artworkPipelineCoalescesConcurrentRequests() async throws {
    let data = try artworkTestData()
    let connector = ArtworkCountingConnector(data: data)
    let cache = temporaryArtworkCache()
    let pipeline = ArtworkPipeline(connector: connector, diskCache: cache)

    async let first = pipeline.load(
        serverID: "server",
        remoteKey: "cover-1",
        cacheKey: "server|cover-1@180",
        fallbackCacheKey: nil,
        targetPixelSize: 180
    )
    async let second = pipeline.load(
        serverID: "server",
        remoteKey: "cover-1",
        cacheKey: "server|cover-1@180",
        fallbackCacheKey: nil,
        targetPixelSize: 180
    )
    let (firstResult, secondResult) = await (first, second)

    #expect(firstResult?.decoded.pixelWidth == secondResult?.decoded.pixelWidth)
    #expect(await connector.callCount() == 1)

    // 落盘是异步的（utility 优先级，先显示后写盘），轮询等待写入完成再断言。
    var written = false
    for _ in 0..<100 {
        if await cache.data(for: "server|cover-1@180") != nil {
            written = true
            break
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(written)
}

@Test("内存告警清理解码位图，随后从磁盘恢复且不重复联网")
@MainActor
func artworkStoreHandlesMemoryPressureAndDiskRecovery() async throws {
    let connector = ArtworkCountingConnector(data: try artworkTestData())
    let store = ArtworkStore(
        connector: connector,
        diskCache: temporaryArtworkCache(),
        initialServerID: "server-a"
    )

    let loaded = await store.load(remoteKey: "cover-2", targetPixelSize: 200)
    #expect(loaded != nil)
    #expect(store.image(remoteKey: "cover-2", targetPixelSize: 200) != nil)
    #expect(await connector.callCount() == 1)

    store.handleMemoryPressure()
    #expect(store.image(remoteKey: "cover-2", targetPixelSize: 200) == nil)

    let restored = await store.load(remoteKey: "cover-2", targetPixelSize: 200)
    #expect(restored != nil)
    #expect(await connector.callCount() == 1)
}

@Test("封面缓存键随服务器切换并清空旧内存命名空间")
@MainActor
func artworkStoreSeparatesServers() async throws {
    let store = ArtworkStore(
        connector: ArtworkCountingConnector(data: try artworkTestData()),
        diskCache: temporaryArtworkCache(),
        initialServerID: "server-a"
    )
    let first = store.cacheKey("shared-cover", targetPixelSize: 128)

    store.setServerID("server-b")
    let second = store.cacheKey("shared-cover", targetPixelSize: 128)

    #expect(first == "server-a|shared-cover@128")
    #expect(second == "server-b|shared-cover@128")
    #expect(first != second)
}

// MARK: - R01 跨服务器封面路由

private actor ArtworkRoutingConnector: ServerConnecting {
    private let data: Data
    private var requestedServerIDs: [String] = []

    init(data: Data) {
        self.data = data
    }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw ServerConnectionError.serverUnavailable
    }

    func restoreLastConnection() async throws -> ServerConnectionResult? { nil }

    func artworkData(serverID: ServerID, key: String, targetPixelSize: Int) async -> Data? {
        requestedServerIDs.append(serverID.rawValue)
        try? await Task.sleep(for: .milliseconds(10))
        return data
    }

    func serverIDs() -> [String] { requestedServerIDs }
}

@Test("R01：显式 serverID 覆盖全局浏览服务器——播 A 浏览 B 时封面仍从 A 回源")
@MainActor
func artworkStoreRoutesExplicitServerID() async throws {
    let connector = ArtworkRoutingConnector(data: try artworkTestData())
    let store = ArtworkStore(
        connector: connector,
        diskCache: temporaryArtworkCache(),
        initialServerID: "server-b"
    )
    // 播放器封面显式传 server-a；当前浏览服务器是 server-b（initialServerID）。
    let image = await store.load(
        remoteKey: "cover",
        targetPixelSize: 128,
        serverID: ServerID(rawValue: "server-a")
    )
    #expect(image != nil)
    let routed = await connector.serverIDs()
    #expect(routed == ["server-a"], "网络回源必须走歌曲真实服务器，而不是浏览服务器")
}

@Test("R01：显式 serverID 的缓存键按请求服务器隔离，不落在浏览服务器命名空间")
@MainActor
func artworkStoreSeparatesExplicitServerIDCacheKeys() {
    let store = ArtworkStore(
        connector: ArtworkCountingConnector(data: try! artworkTestData()),
        diskCache: temporaryArtworkCache(),
        initialServerID: "server-b"
    )
    let keyA = store.requestIdentifier(
        remoteKey: "cover",
        targetPixelSize: 128,
        serverID: ServerID(rawValue: "server-a")
    )
    let keyB = store.requestIdentifier(
        remoteKey: "cover",
        targetPixelSize: 128,
        serverID: ServerID(rawValue: "server-b")
    )
    let keyBrowse = store.requestIdentifier(remoteKey: "cover", targetPixelSize: 128)
    #expect(keyA == "server-a|cover@128")
    #expect(keyB == "server-b|cover@128")
    #expect(keyBrowse == keyB, "浏览型封面兜底 = 当前浏览服务器")
    #expect(keyA != keyB, "播放 A 的封面缓存不得落在 B 的命名空间")
}

// MARK: - R01 Now Playing 跨服封面（播 A 浏览 B，同 coverKey 不同图片）

/// 按服务器返回不同图片的 connector：server-a 红色、server-b 蓝色。
private actor ArtworkServerSpecificConnector: ServerConnecting {
    private let dataByServer: [String: Data]
    private var requestedServerIDs: [String] = []

    init(dataByServer: [String: Data]) {
        self.dataByServer = dataByServer
    }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw ServerConnectionError.serverUnavailable
    }

    func restoreLastConnection() async throws -> ServerConnectionResult? { nil }

    func artworkData(serverID: ServerID, key: String, targetPixelSize: Int) async -> Data? {
        requestedServerIDs.append("\(serverID.rawValue)|\(key)")
        try? await Task.sleep(for: .milliseconds(10))
        return dataByServer[serverID.rawValue]
    }

    func serverIDs() -> [String] { requestedServerIDs }
}

/// 可控制回源时延的 connector：让测试能在请求在途时切换浏览服务器。
private actor ArtworkSlowConnector: ServerConnecting {
    private let data: Data
    private let delay: Duration

    init(data: Data, delay: Duration) {
        self.data = data
        self.delay = delay
    }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw ServerConnectionError.serverUnavailable
    }

    func restoreLastConnection() async throws -> ServerConnectionResult? { nil }

    func artworkData(serverID: ServerID, key: String, targetPixelSize: Int) async -> Data? {
        try? await Task.sleep(for: delay)
        return data
    }
}

@Test("R01：播 A 浏览 B、同 coverKey 不同图片——按 serverID 取回 A 图，不串用 B 的缓存")
@MainActor
func nowPlayingArtworkFollowsTrackServerNotBrowseServer() async throws {
    let redData = try artworkTestData(red: 0.85, green: 0.1, blue: 0.1)
    let blueData = try artworkTestData(red: 0.1, green: 0.2, blue: 0.85)
    let connector = ArtworkServerSpecificConnector(dataByServer: [
        "server-a": redData,
        "server-b": blueData,
    ])
    let cache = temporaryArtworkCache()
    // 当前浏览服务器是 B；播放的是 A 的歌曲。
    let store = ArtworkStore(
        connector: connector,
        diskCache: cache,
        initialServerID: "server-b"
    )

    // 1) 播放器封面（显式 server-a）：网络回源必须到 A，且写进 A 的缓存键。
    let aImage = await store.load(remoteKey: "same", targetPixelSize: 128, serverID: ServerID(rawValue: "server-a"))
    #expect(aImage != nil)
    let routed = await connector.serverIDs()
    #expect(routed == ["server-a|same"], "封面回源必须走歌曲真实服务器 A")

    let aDisk = await cache.data(for: "server-a|same@128")
    let bDiskBeforeA = await cache.data(for: "server-b|same@128")
    #expect(aDisk != nil)
    #expect(bDiskBeforeA == nil, "A 的封面不得写进 B 的缓存键")

    // 2) 浏览 B 时同 key 兜底加载 → 落在 B 键，且与 A 图片数据不同。
    _ = await store.load(remoteKey: "same", targetPixelSize: 128)
    let bDisk = await cache.data(for: "server-b|same@128")
    #expect(bDisk != nil)
    #expect(bDisk != aDisk, "A/B 同 coverKey 但图片不同，必须各自落键")

    // 3) Now Playing 场景：播 A 浏览 B，显式 serverID 必须命中 A 的图。
    let fetchedA = store.image(remoteKey: "same", targetPixelSize: 128, serverID: ServerID(rawValue: "server-a"))
    let fetchedBrowse = store.image(remoteKey: "same", targetPixelSize: 128)
    #expect(fetchedA != nil)
    #expect(fetchedBrowse != nil)
    // 两次 fetch 来自不同缓存键（不同图片），对象不同——不发生串用。
    #expect(!(fetchedA === fetchedBrowse))
}

@Test("R01 收尾：显式 A 封面加载在途时切到 B 浏览——A 请求不被取消、结果落 A 键、内存缓存保留")
@MainActor
func explicitArtworkLoadSurvivesBrowseServerSwitch() async throws {
    let data = try artworkTestData(red: 0.85, green: 0.1, blue: 0.1)
    let connector = ArtworkSlowConnector(data: data, delay: .milliseconds(200))
    let cache = temporaryArtworkCache()
    let store = ArtworkStore(
        connector: connector,
        diskCache: cache,
        initialServerID: "server-a"
    )

    // 启动显式 server-a 封面加载（在途 200ms）。
    let loadTask = Task { @MainActor in
        await store.load(remoteKey: "cover", targetPixelSize: 128, serverID: ServerID(rawValue: "server-a"))
    }
    // 请求尚未完成时切换浏览服务器到 B。
    try? await Task.sleep(for: .milliseconds(50))
    store.setServerID("server-b")

    // A 请求必须照常完成并返回图片——切浏览服务器不得取消显式播放器封面。
    let image = await loadTask.value
    #expect(image != nil, "显式 A 封面请求不得被 B 的浏览切换取消")

    // A 的内存缓存仍在（未被切服清空）。
    let cachedA = store.image(remoteKey: "cover", targetPixelSize: 128, serverID: ServerID(rawValue: "server-a"))
    #expect(cachedA != nil, "切浏览服务器不得清掉 A 的内存封面")

    // 结果落在 A 键，B 命名空间无内容。
    let aDisk = await cache.data(for: "server-a|cover@128")
    let bDisk = await cache.data(for: "server-b|cover@128")
    #expect(aDisk != nil)
    #expect(bDisk == nil, "A 的封面不得写进 B 的缓存键")
}
