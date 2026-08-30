import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Persists a compact, privacy-safe playback lifecycle breadcrumb across
/// launches. iOS does not grant an app access to system `.ips` / Jetsam
/// reports, so this deliberately records evidence instead of guessing a
/// termination cause. The next launch can then distinguish a clean shutdown
/// from an unexplained end that should be correlated with device diagnostics.
@MainActor
public final class PlaybackTerminationDiagnostics {
    public static let shared = PlaybackTerminationDiagnostics()

    public struct Context: Codable, Equatable, Sendable {
        public var trackIdentity: String?
        public var playbackState: String
        public var audioSessionActive: Bool
        public var musicHapticsEnabled: Bool
        public var musicHapticsAnalysisMode: String?
        public var musicHapticsAnalysisLeadSeconds: TimeInterval?

        public init(
            trackIdentity: String? = nil,
            playbackState: String,
            audioSessionActive: Bool,
            musicHapticsEnabled: Bool,
            musicHapticsAnalysisMode: String? = nil,
            musicHapticsAnalysisLeadSeconds: TimeInterval? = nil
        ) {
            self.trackIdentity = trackIdentity
            self.playbackState = playbackState
            self.audioSessionActive = audioSessionActive
            self.musicHapticsEnabled = musicHapticsEnabled
            self.musicHapticsAnalysisMode = musicHapticsAnalysisMode
            self.musicHapticsAnalysisLeadSeconds = musicHapticsAnalysisLeadSeconds
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var launchDate: Date
        public var lastUpdatedDate: Date
        public var lastBackgroundDate: Date?
        public var lastForegroundDate: Date?
        public var lastPlaybackStallDate: Date?
        public var lastAudioInterruptionDate: Date?
        public var normalTerminationDate: Date?
        public var memoryWarningCount: Int
        public var residentMemoryBytes: UInt64?
        public var context: Context?

        fileprivate init(launchDate: Date) {
            self.launchDate = launchDate
            self.lastUpdatedDate = launchDate
            self.lastBackgroundDate = nil
            self.lastForegroundDate = nil
            self.lastPlaybackStallDate = nil
            self.lastAudioInterruptionDate = nil
            self.normalTerminationDate = nil
            self.memoryWarningCount = 0
            self.residentMemoryBytes = Self.currentResidentMemoryBytes()
            self.context = nil
        }

        private static func currentResidentMemoryBytes() -> UInt64? {
            #if canImport(Darwin)
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(
                        mach_task_self_,
                        task_flavor_t(MACH_TASK_BASIC_INFO),
                        $0,
                        &count
                    )
                }
            }
            return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
            #else
            nil
            #endif
        }

        fileprivate mutating func refresh(
            context: Context?,
            now: Date
        ) {
            lastUpdatedDate = now
            residentMemoryBytes = Self.currentResidentMemoryBytes()
            if let context {
                self.context = context
            }
        }
    }

    public enum PreviousSession: Equatable, Sendable {
        case none
        case endedNormally(Snapshot)
        case endedUnexpectedly(Snapshot)

        public var logMessage: String? {
            switch self {
            case .none:
                return nil
            case let .endedNormally(snapshot):
                return "播放生命周期诊断：上一会话正常结束（最后状态：\(snapshot.context?.playbackState ?? "未知")）。"
            case let .endedUnexpectedly(snapshot):
                let backgroundHint = snapshot.lastBackgroundDate == nil
                    ? "未记录后台切换"
                    : "最后一次状态发生在后台后"
                return "播放生命周期诊断：上一会话未正常结束（\(backgroundHint)）；请结合设备的 .ips / Jetsam / watchdog 报告判断原因，不能仅据此认定为系统杀进程。"
            }
        }
    }

    private static let storageKey = "auralis.playbackTerminationDiagnostics.v1"
    private let defaults: UserDefaults
    private var snapshot: Snapshot

    public init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        self.snapshot = Self.load(from: defaults) ?? Snapshot(launchDate: now)
    }

    /// Starts a new process-lifetime marker and returns the outcome of the
    /// previous marker before replacing it.
    public func beginLaunch(now: Date = .now) -> PreviousSession {
        let previous = Self.load(from: defaults)
        let outcome: PreviousSession
        if let previous {
            outcome = previous.normalTerminationDate == nil
                ? .endedUnexpectedly(previous)
                : .endedNormally(previous)
        } else {
            outcome = .none
        }
        snapshot = Snapshot(launchDate: now)
        persist()
        return outcome
    }

    public func recordBackground(context: Context, now: Date = .now) {
        snapshot.lastBackgroundDate = now
        snapshot.refresh(context: context, now: now)
        persist()
    }

    public func recordForeground(context: Context, now: Date = .now) {
        snapshot.lastForegroundDate = now
        snapshot.refresh(context: context, now: now)
        persist()
    }

    public func recordPlaybackStall(context: Context, now: Date = .now) {
        snapshot.lastPlaybackStallDate = now
        snapshot.refresh(context: context, now: now)
        persist()
    }

    public func recordAudioInterruption(context: Context, now: Date = .now) {
        snapshot.lastAudioInterruptionDate = now
        snapshot.refresh(context: context, now: now)
        persist()
    }

    public func recordMemoryWarning(context: Context?, now: Date = .now) {
        snapshot.memoryWarningCount += 1
        snapshot.refresh(context: context, now: now)
        persist()
    }

    public func markNormalTermination(now: Date = .now) {
        snapshot.normalTerminationDate = now
        snapshot.refresh(context: nil, now: now)
        persist()
    }

    public func currentSnapshot() -> Snapshot { snapshot }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> Snapshot? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
