// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Domain
import Foundation
#if os(iOS)
@preconcurrency import BackgroundTasks
import UIKit

@MainActor
private final class ClassificationProcessingCompletion {
    let task: BGProcessingTask
    private var completed = false
    init(_ task: BGProcessingTask) { self.task = task }
    func finish(success: Bool) {
        guard !completed else { return }
        completed = true
        task.setTaskCompleted(success: success)
    }
}
#endif

extension AuralisAppModel {
#if os(iOS)
    private static let classificationBackgroundIdentifier = "com.auralis.tag-classification"

    public static func registerTagClassificationBackgroundProcessing() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.classificationBackgroundIdentifier, using: .main) { task in
            guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                let completion = ClassificationProcessingCompletion(processing)
                let model = AuralisAppModel.shared
                guard UIApplication.shared.applicationState == .background else {
                    completion.finish(success: false); return
                }
                let leaseID = UUID()
                model.tagClassificationProcessingLeaseID = leaseID
                model.tagClassificationExecution.isForeground = false
                model.tagClassificationExecution.hasProcessingTime = true
                processing.expirationHandler = {
                    Task { @MainActor in
                        if model.tagClassificationProcessingLeaseID == leaseID {
                            model.tagClassificationProcessingLeaseID = nil
                            model.tagClassificationExecution.hasProcessingTime = false
                            model.pauseClassificationWithoutExecutionTime()
                        }
                        completion.finish(success: false)
                        model.scheduleTagClassificationBackgroundProcessing()
                    }
                }
                await model.restorePersistedLibrary()
                guard let requested = model.tagClassificationDefaults.string(forKey: Self.classificationRequestedServerKey),
                      model.catalog.activeServerID?.rawValue == requested,
                      model.tagClassificationProcessingLeaseID == leaseID,
                      UIApplication.shared.applicationState == .background else {
                    if model.tagClassificationProcessingLeaseID == leaseID {
                        model.tagClassificationProcessingLeaseID = nil
                        model.tagClassificationExecution.hasProcessingTime = false
                    }
                    completion.finish(success: false); return
                }
                model.startTagClassification()
                let ownedTask = model.tagClassificationTask
                await ownedTask?.value
                processing.expirationHandler = nil
                if model.tagClassificationProcessingLeaseID == leaseID {
                    model.tagClassificationProcessingLeaseID = nil
                    model.tagClassificationExecution.hasProcessingTime = false
                }
                completion.finish(success: model.tagClassification.status?.pendingTracks == 0)
                model.scheduleTagClassificationBackgroundProcessing()
            }
        }
    }

    func scheduleTagClassificationBackgroundProcessing() {
        guard tagClassificationDefaults.string(forKey: Self.classificationRequestedServerKey) != nil,
              tagClassificationDefaults.bool(forKey: Self.classificationConsentKey) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.classificationBackgroundIdentifier)
        request.requiresNetworkConnectivity = true
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            if tagClassification.isWaitingForSystem {
                setTagClassificationMessage("系统未接受本次后台调度：\(error.localizedDescription)。进度已保存，回到前台后自动继续。", showNotice: true)
            }
        }
    }

    func clearTagClassificationBackgroundRequest() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.classificationBackgroundIdentifier)
    }

    private func ensureClassificationShortExecutionTime() {
        guard tagClassification.isRunning, !tagClassificationExecution.isForeground,
              !tagClassificationExecution.isAudioPlaying, !tagClassificationExecution.hasProcessingTime,
              tagClassificationBackgroundTask == .invalid else { return }
        let runID = tagClassification.runID
        tagClassificationBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Tag classification") { [weak self] in
            Task { @MainActor in
                guard let self, self.tagClassification.runID == runID else { return }
                self.endTagClassificationBackgroundActivity()
                self.pauseClassificationWithoutExecutionTime()
            }
        }
        tagClassificationExecution.hasShortTaskTime = tagClassificationBackgroundTask != .invalid
        pauseClassificationWithoutExecutionTime()
    }

    private func pauseClassificationWithoutExecutionTime() {
        guard tagClassification.isRunning, !tagClassificationExecution.canContinue else { return }
        tagClassification.isWaitingForSystem = true
        setTagClassificationMessage("系统暂时没有提供后台运行时间，已保存分类进度；播放音频、回到前台或系统再次调度后自动继续。", showNotice: true)
        tagClassificationTask?.cancel()
        scheduleTagClassificationBackgroundProcessing()
    }
#endif

    func updateTagClassificationExecutionForPlayback() {
#if os(iOS)
        tagClassificationExecution.isAudioPlaying = playbackState == .playing
        ensureClassificationShortExecutionTime()
        if tagClassificationExecution.isAudioPlaying, tagClassification.isWaitingForSystem {
            resumeClassificationAfterCurrentAttempt()
        }
#endif
    }

    func tagClassificationDidEnterBackground() {
#if os(iOS)
        tagClassificationExecution.isForeground = false
        updateTagClassificationExecutionForPlayback()
#endif
    }

    func tagClassificationDidBecomeActive() {
#if os(iOS)
        tagClassificationExecution.isForeground = true
        endTagClassificationBackgroundActivity()
#endif
        resumeClassificationAfterCurrentAttempt()
    }

    private func resumeClassificationAfterCurrentAttempt() {
        guard tagClassificationTask == nil || tagClassification.isWaitingForSystem else { return }
        let previous = tagClassificationTask
        Task { @MainActor [weak self] in
            await previous?.value
            self?.resumeRequestedTagClassification()
        }
    }
}
