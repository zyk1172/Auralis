// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#if os(iOS)
@preconcurrency import BackgroundTasks
import Domain
import Foundation

extension AuralisAppModel {
    private static let classificationBackgroundIdentifier = "com.auralis.tag-classification"
    static let classificationRequestedServerKey = "auralis.classification.requestedServer"

    /// Registered during application launch. iOS controls when processing time is granted.
    public func registerTagClassificationBackgroundProcessing() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.classificationBackgroundIdentifier, using: .main) { task in
            guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                processing.expirationHandler = {
                    Task { @MainActor in
                        self.tagClassificationTask?.cancel()
                        self.tagClassification.message = "系统暂停了后台分类，进度已保存，等待继续。"
                    }
                }
                await self.restorePersistedLibrary()
                guard let requested = UserDefaults.standard.string(forKey: Self.classificationRequestedServerKey),
                      self.catalog.activeServerID?.rawValue == requested else {
                    processing.setTaskCompleted(success: false); return
                }
                self.startTagClassification()
                await self.tagClassificationTask?.value
                processing.expirationHandler = nil
                let finished = self.tagClassification.status?.pendingTracks == 0
                processing.setTaskCompleted(success: finished)
                if !finished { self.scheduleTagClassificationBackgroundProcessing() }
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
