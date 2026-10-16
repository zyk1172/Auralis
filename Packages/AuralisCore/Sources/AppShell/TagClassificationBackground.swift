// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#if os(iOS)
@preconcurrency import BackgroundTasks
import Domain
import Foundation

extension AuralisAppModel {
    private static let classificationBackgroundIdentifier = "com.auralis.tag-classification"
    static let classificationRequestedServerKey = "auralis.classification.requestedServer"

    /// Registered during application launch. iOS controls when processing time is granted.
    public static func registerTagClassificationBackgroundProcessing() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.classificationBackgroundIdentifier, using: .main) { task in
            guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                let model = AuralisAppModel.shared
                await model.restorePersistedLibrary()
                guard let requested = UserDefaults.standard.string(forKey: Self.classificationRequestedServerKey),
                      model.catalog.activeServerID?.rawValue == requested else {
                    processing.setTaskCompleted(success: false); return
                }
                model.startTagClassification()
                let ownedTask = model.tagClassificationTask
                let runID = model.tagClassification.runID
                processing.expirationHandler = {
                    ownedTask?.cancel()
                    Task { @MainActor in
                        if model.tagClassification.runID == runID {
                            model.tagClassification.message = "系统暂停了后台分类，进度已保存，等待继续。"
                        }
                    }
                }
                await ownedTask?.value
                processing.expirationHandler = nil
                let finished = model.tagClassification.status?.pendingTracks == 0
                processing.setTaskCompleted(success: finished)
                if !finished { model.scheduleTagClassificationBackgroundProcessing() }
            }
        }
    }

    func scheduleTagClassificationBackgroundProcessing() {
        guard UserDefaults.standard.string(forKey: Self.classificationRequestedServerKey) != nil,
              UserDefaults.standard.bool(forKey: Self.classificationConsentKey) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.classificationBackgroundIdentifier)
        request.requiresNetworkConnectivity = true
        // Scheduling failure must not stop the independent in-app job.
        try? BGTaskScheduler.shared.submit(request)
    }

    func clearTagClassificationBackgroundRequest() {
        UserDefaults.standard.removeObject(forKey: Self.classificationRequestedServerKey)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.classificationBackgroundIdentifier)
    }
}
#endif
