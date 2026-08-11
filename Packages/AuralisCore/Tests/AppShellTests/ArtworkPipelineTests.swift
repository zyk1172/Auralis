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

    func artworkData(key: String, targetPixelSize: Int) async -> Data? {
        artworkCalls += 1
        try? await Task.sleep(for: .milliseconds(40))
        return data
    }

    func callCount() -> Int { artworkCalls }
}

private func artworkTestData(width: Int = 1_024, height: Int = 640) throws -> Data {
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
    context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.8, alpha: 1))
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
        remoteKey: "cover-1",
        cacheKey: "server|cover-1@180",
        fallbackCacheKey: nil,
        targetPixelSize: 180
    )
    async let second = pipeline.load(
        remoteKey: "cover-1",
        cacheKey: "server|cover-1@180",
        fallbackCacheKey: nil,
        targetPixelSize: 180
    )
    let (firstResult, secondResult) = await (first, second)

    #expect(firstResult?.decoded.pixelWidth == secondResult?.decoded.pixelWidth)
    #expect(await connector.callCount() == 1)
    #expect(await cache.data(for: "server|cover-1@180") != nil)
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
