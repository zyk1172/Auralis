import Domain
import Foundation
import Observability
import MediaPlayer
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// 提交给系统 Now Playing 中心的快照。
public struct NowPlayingSnapshot: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var elapsed: TimeInterval
    public var rate: Float
    /// 封面 PNG/JPEG 数据；没有封面时为 nil。
    public var artworkData: Data?
    /// 队列中的当前位置与总数（控制中心 / 锁屏显示）。
    public var queueIndex: Int?
    public var queueCount: Int?

    public init(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        rate: Float,
        artworkData: Data? = nil,
        queueIndex: Int? = nil,
        queueCount: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.rate = rate
        self.artworkData = artworkData
        self.queueIndex = queueIndex
        self.queueCount = queueCount
    }
}

/// 负责把播放状态同步到 MPNowPlayingInfoCenter（锁屏 / 控制中心 / macOS 菜单栏）。
@MainActor
public final class NowPlayingCoordinator {
    public private(set) var current: NowPlayingSnapshot?

    public init() {}

    /// 构造 Now Playing 信息字典。提取为纯函数便于测试。
    public static func infoDictionary(for snapshot: NowPlayingSnapshot) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPMediaItemPropertyAlbumTitle: snapshot.album,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.rate,
            // 默认播放速率：部分系统版本依赖它才能在控制中心正确显示进度与速率。
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPMediaItemPropertyMediaType: NSNumber(value: MPMediaType.music.rawValue),
        ]
        if let queueIndex = snapshot.queueIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = NSNumber(value: queueIndex)
        }
        if let queueCount = snapshot.queueCount {
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = NSNumber(value: queueCount)
        }
        if let data = snapshot.artworkData, let image = platformImage(from: data),
           image.size.width > 0, image.size.height > 0 {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(for: image)
        }
        return info
    }

    /// 关键修复（iOS 26 beta 后台崩溃）：系统 MediaRemote 会在它私有的
    /// `com.apple.MediaPlayer.MPNowPlayingInfoCenter/accessQueue` 上调用 artwork 的
    /// requestHandler 闭包（非主线程）。如果该闭包创建于 @MainActor 方法内部，
    /// 会继承主线程隔离，回调时触发 `_dispatch_assert_queue_fail` → 播放结束/后台
    /// 刷新 NowPlaying 时直接崩溃（表现为「播放完就卡死、后台播放被杀」）。
    /// 因此把 artwork 创建移到 `nonisolated` 上下文，闭包不再要求主线程。
    nonisolated private static func makeArtwork(for image: MediaPlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// 切歌 / 播放 / 暂停 / 拖动 / 封面加载完成时调用。
    public func update(_ snapshot: NowPlayingSnapshot) {
        current = snapshot
        let info = Self.infoDictionary(for: snapshot)
        CrashLog.shared.log("NowPlayingCoordinator.update: \(snapshot.title)")
        // MPNowPlayingInfoCenter 在 iOS 上必须从主线程访问；
        // 非主线程调用会触发 FIG/MediaRemote 内部 _dispatch_assert_queue_fail。
        // 用 DispatchQueue.main.async 确保即使调用方在 eventdispatch 等非主线程队列上也能安全执行。
        #if os(iOS)
        DispatchQueue.main.async {
            CrashLog.shared.log("设置 MPNowPlayingInfoCenter.nowPlayingInfo (主线程)")
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        #else
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    /// 仅刷新进度与速率（拖动、播放/暂停切换的高频路径）。
    public func updateProgress(elapsed: TimeInterval, rate: Float) {
        guard var snapshot = current else { return }
        snapshot.elapsed = elapsed
        snapshot.rate = rate
        current = snapshot
        #if os(iOS)
        // MPNowPlayingInfoCenter 在 iOS 上必须从主线程访问；
        // 先读取当前信息，再在主线程上更新，避免 _dispatch_assert_queue_fail。
        let currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        DispatchQueue.main.async {
            var base = currentInfo
            base[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            base[MPNowPlayingInfoPropertyPlaybackRate] = rate
            MPNowPlayingInfoCenter.default().nowPlayingInfo = base
        }
        #else
        var base = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        base[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        base[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = base
        #endif
    }

    /// 播放停止或退出服务器时清理。
    public func clear() {
        current = nil
        #if os(iOS)
        DispatchQueue.main.async { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        #else
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    nonisolated private static func platformImage(from data: Data) -> MediaPlatformImage? {
        MediaPlatformImage(data: data)
    }
}

#if os(macOS)
public typealias MediaPlatformImage = NSImage
#elseif os(iOS)
public typealias MediaPlatformImage = UIImage
#endif
