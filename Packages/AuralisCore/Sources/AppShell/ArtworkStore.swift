import Foundation
import Observation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// 封面缓存独立存储（Observation 框架）。
///
/// 封面是按需异步加载的：滚动时大量封面陆续到达。若把封面缓存放进
/// `@Published`，每次写回都会触发整个模型的所有观察者（包括首页）整体
/// 重算，滚动过程中形成「封面到达 → 全首页重绘 → 视图/手势重建」的刷新
/// 风暴，表现为首页上下滑动卡顿与控制台刷屏 `cannot add handler ... dropping`。
/// 这里用 `@Observable` 独立存储：只有真正读取封面图的视图（ArtworkView /
/// Now Playing 光效）会随封面到达而刷新，首页外壳与货架不再因此重建。
@MainActor
@Observable
final class ArtworkStore {
    /// 已加载封面，键为 `serverID|封面Key@像素尺寸`（由模型生成，按服务器隔离）。
    private(set) var images: [String: PlatformImage] = [:]
    /// 「无封面 / 拉取失败」负缓存键，避免反复请求同一张封面。
    private(set) var unavailable: Set<String> = []

    func image(forKey key: String) -> PlatformImage? {
        images[key]
    }

    func isUnavailable(_ key: String) -> Bool {
        unavailable.contains(key)
    }

    func setImage(_ image: PlatformImage, forKey key: String) {
        images[key] = image
    }

    func markUnavailable(_ key: String) {
        unavailable.insert(key)
    }

    /// 清空全部封面（切换服务器 / 手动清除封面缓存时调用）。
    func reset() {
        images = [:]
        unavailable = []
    }

    /// 只清空「无封面」负缓存（同一服务器增量刷新时保留已加载图片）。
    func clearUnavailable() {
        unavailable = []
    }
}
