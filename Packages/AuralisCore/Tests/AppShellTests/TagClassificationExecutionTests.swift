// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
@testable import AppShell
import Foundation
import Testing

@Suite("Classification execution grants and visible stop reasons")
struct TagClassificationExecutionTests {
    @Test("Short execution expiration does not revoke foreground, real audio, or BGProcessing execution", arguments: [0, 1, 2])
    func independentGrants(grant: Int) {
        var state = TagClassificationExecutionState(isForeground: grant == 0, isAudioPlaying: grant == 1,
            hasShortTaskTime: true, hasProcessingTime: grant == 2)
        state.hasShortTaskTime = false
        #expect(state.canContinue)
    }

    @Test("After audio and all system grants end the job must checkpoint and wait")
    func exhaustedGrants() {
        var state = TagClassificationExecutionState(isForeground: false, isAudioPlaying: true, hasShortTaskTime: true)
        state.isAudioPlaying = false
        #expect(state.canContinue)
        state.hasShortTaskTime = false
        #expect(!state.canContinue)
        state.isForeground = true
        #expect(state.canContinue)
    }

    @MainActor @Test("Manual pause removes durable continuation intent even while the system has suspended the worker")
    func manualPauseWhileWaiting() throws {
        let name = "classification-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AuralisAppModel(defaults: defaults, storeURL: directory.appendingPathComponent("catalog.sqlite"))
        defaults.set("server", forKey: AuralisAppModel.classificationRequestedServerKey)
        model.tagClassification.isWaitingForSystem = true
        model.pauseTagClassification()
        #expect(defaults.string(forKey: AuralisAppModel.classificationRequestedServerKey) == nil)
        #expect(!model.tagClassification.isWaitingForSystem)
        #expect(model.tagClassification.message != nil)
        model.setTagClassificationMessage("Visible failure reason", showNotice: true)
        #expect(model.tagClassification.notice == "Visible failure reason")
        #expect(defaults.string(forKey: AuralisAppModel.classificationLastMessageKey) == "Visible failure reason")
    }
}
