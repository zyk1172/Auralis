// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observability
import Testing

@Suite("Playback termination diagnostics")
struct PlaybackTerminationDiagnosticsTests {
    @Test("Unmarked prior run is retained as evidence, not mislabeled as Jetsam")
    @MainActor
    func unmarkedPriorRunIsUnexpectedButNotAttributed() {
        let suiteName = "playback-termination-diagnostics-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PlaybackTerminationDiagnostics(defaults: defaults, now: .distantPast)
        #expect(first.beginLaunch(now: .distantPast) == .none)
        let context = PlaybackTerminationDiagnostics.Context(
            trackIdentity: "server:track",
            playbackState: "playing",
            audioSessionActive: true,
            musicHapticsEnabled: true,
            musicHapticsAnalysisMode: "remoteOriginal",
            musicHapticsAnalysisLeadSeconds: 12
        )
        first.recordBackground(context: context, now: Date(timeIntervalSince1970: 20))
        first.recordPlaybackStall(context: context, now: Date(timeIntervalSince1970: 21))
        first.recordMemoryWarning(context: context, now: Date(timeIntervalSince1970: 22))

        let next = PlaybackTerminationDiagnostics(defaults: defaults)
        let outcome = next.beginLaunch(now: Date(timeIntervalSince1970: 30))
        guard case let .endedUnexpectedly(snapshot) = outcome else {
            Issue.record("Expected an unexplained prior session")
            return
        }
        #expect(snapshot.context == context)
        #expect(snapshot.lastBackgroundDate == Date(timeIntervalSince1970: 20))
        #expect(snapshot.lastPlaybackStallDate == Date(timeIntervalSince1970: 21))
        #expect(snapshot.memoryWarningCount == 1)
        #expect(outcome.logMessage?.contains("不能仅据此认定为系统杀进程") == true)
    }

    @Test("Normal termination marker survives the next launch")
    @MainActor
    func normalTerminationIsNotReportedAsUnexpected() {
        let suiteName = "playback-termination-normal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PlaybackTerminationDiagnostics(defaults: defaults)
        _ = first.beginLaunch(now: .distantPast)
        first.markNormalTermination(now: Date(timeIntervalSince1970: 10))

        let next = PlaybackTerminationDiagnostics(defaults: defaults)
        let outcome = next.beginLaunch(now: Date(timeIntervalSince1970: 20))
        guard case let .endedNormally(snapshot) = outcome else {
            Issue.record("Expected a normally terminated prior session")
            return
        }
        #expect(snapshot.normalTerminationDate == Date(timeIntervalSince1970: 10))
    }
}
