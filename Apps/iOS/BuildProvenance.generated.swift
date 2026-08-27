// Generated during the Auralis application build phase. Do not edit by hand.
import AppShell

enum BuildProvenanceGenerated {
    static let gitCommit = "unknown"
    static let gitBranch = "unknown"
    static let buildConfiguration = "unknown"
    static let appVersion = "unknown"
    static let buildNumber = "unknown"

    @MainActor
    static func install() {
        BuildProvenance.install(
            commit: gitCommit,
            branch: gitBranch,
            configuration: buildConfiguration,
            version: appVersion,
            buildNumber: buildNumber
        )
    }
}
