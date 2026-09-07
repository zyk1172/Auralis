// Generated during the Auralis application build phase. Do not edit by hand.
import AppShell

enum BuildProvenanceGenerated {
    static let gitCommit = "96f53841"
    static let gitBranch = "main"
    static let buildConfiguration = "Release"
    static let appVersion = "1.1.0"
    static let buildNumber = "4"

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
