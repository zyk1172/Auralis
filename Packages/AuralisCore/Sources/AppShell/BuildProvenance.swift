import Foundation

/// Build metadata supplied by the iOS application's build phase.
///
/// The AppShell package deliberately has a safe fallback so that package tests
/// and the macOS product can compile without an iOS application target.  The
/// iOS target calls `install` from its generated source before the first view
/// is created; no runtime git invocation is involved.
@MainActor
public enum BuildProvenance {
    public private(set) static var gitCommit = "unknown"
    public private(set) static var gitBranch = "unknown"
    public private(set) static var buildConfiguration = "unknown"
    public private(set) static var appVersion = "unknown"
    public private(set) static var buildNumber = "unknown"

    public static func install(
        commit: String,
        branch: String,
        configuration: String,
        version: String,
        buildNumber: String
    ) {
        gitCommit = commit
        gitBranch = branch
        buildConfiguration = configuration
        appVersion = version
        self.buildNumber = buildNumber
    }
}
