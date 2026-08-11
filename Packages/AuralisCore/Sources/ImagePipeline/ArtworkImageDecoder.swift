import CoreGraphics
import Foundation
import ImageIO

/// ImageIO 解码后的封面。
///
/// `CGImage` 是不可变的 Core Foundation 对象；包装器只跨并发域传递只读引用，
/// 真正的 UIKit / AppKit 图片对象仍由主线程创建。
public struct DecodedArtwork: @unchecked Sendable {
    public let image: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int

    public var memoryCost: Int {
        let (pixels, pixelOverflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return pixelOverflow || byteOverflow ? Int.max : bytes
    }

    public init(image: CGImage) {
        self.image = image
        self.pixelWidth = image.width
        self.pixelHeight = image.height
    }
}

/// 专用封面解码器。
///
/// actor 不绑定 MainActor，调用者 `await` 后，ImageIO 建图与像素解码在独立执行器上完成；
/// 避免先把原图完整解成 UIImage / NSImage，再在主线程二次缩放。
public actor ArtworkImageDecoder {
    public init() {}

    public func decode(_ data: Data, maxPixelSize: Int) -> DecodedArtwork? {
        Self.downsample(data, maxPixelSize: maxPixelSize)
    }

    /// 直接从压缩数据创建目标尺寸缩略图。保留方向信息，且不会解码一张额外的全尺寸位图。
    public nonisolated static func downsample(
        _ data: Data,
        maxPixelSize: Int
    ) -> DecodedArtwork? {
        guard !data.isEmpty else { return nil }
        let target = max(1, maxPixelSize)

        return autoreleasepool {
            let sourceOptions = [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                return nil
            }

            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
                return nil
            }
            return DecodedArtwork(image: image)
        }
    }
}
