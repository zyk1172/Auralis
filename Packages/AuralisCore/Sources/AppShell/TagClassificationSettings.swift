// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import AIKit
import AgentKit
import Domain
import Foundation
import LocalCatalog
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct TagClassificationState {
    var runID: UUID?
    public var status: RecommendationIndexStatus?
    public var isRunning = false
    public var message: String?
    public var batchNumber = 0
    public var unlabeledTracks = 0
    public var progress: TagClassificationProgress?
}

extension AuralisAppModel {
    static let classificationConsentKey = "auralis.classification.metadataConsent"
    var tagClassificationRefreshID: String {
        "\(catalog.activeServerID?.rawValue ?? "")|\(tagClassification.runID?.uuidString ?? "")|\(tagClassification.batchNumber)|\(tagClassification.isRunning)"
    }

    public func refreshTagClassificationStatus() async {
        guard !tagClassification.isRunning else { return }
        guard let server = catalog.activeServerID else {
            tagClassification.status = nil; tagClassification.unlabeledTracks = 0; return
        }
        do {
            tagClassification.status = try await catalogCoordinator.store.recommendationIndexStatus(serverID: server)
            tagClassification.unlabeledTracks = try await catalogCoordinator.store.emptyRecommendationClassificationCount(serverID: server)
        }
        catch { tagClassification.message = error.localizedDescription }
    }

    public func startTagClassification(retryUnlabeled: Bool = false) {
        guard tagClassificationTask == nil else { return }
        guard let server = catalog.activeServerID else {
            tagClassification.message = "请先选择并同步音乐库。"; return
        }
        let settings = AIConnectionSettings()
        guard let provider = settings.makeProvider() else {
#if os(iOS)
            clearTagClassificationBackgroundRequest()
#endif
            tagClassification.message = settings.completenessError ?? "请先在设置中配置大模型。"; return
        }
        tagClassification.isRunning = true
        let runID = UUID()
        tagClassification.runID = runID
        tagClassification.message = nil
        tagClassification.batchNumber = 0
        tagClassification.progress = nil
#if os(iOS)
        UserDefaults.standard.set(server.rawValue, forKey: Self.classificationRequestedServerKey)
        scheduleTagClassificationBackgroundProcessing()
        tagClassificationBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Tag classification") { [weak self] in
            Task { @MainActor in
                guard self?.tagClassification.runID == runID, self?.tagClassification.isRunning == true else { return }
                self?.tagClassification.message = "系统暂停了后台运行，已完成批次已保存，等待继续。"
                self?.tagClassificationTask?.cancel()
                self?.endTagClassificationBackgroundActivity()
            }
        }
#elseif os(macOS)
        tagClassificationActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Music tag classification")
#endif
        let runner = TagClassificationRunner(catalog: catalogCoordinator.store, provider: provider,
            model: settings.model, maxOutputTokens: settings.maxOutputTokens, reasoning: settings.reasoning)
        tagClassificationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.tagClassification.isRunning = false
                self.tagClassificationTask = nil
                self.endTagClassificationBackgroundActivity()
            }
            do {
                try self.authorizeTagClassification(server: server)
                if retryUnlabeled {
                    try await self.catalogCoordinator.store.requeueEmptyRecommendationClassifications(serverID: server)
                }
                try await runner.run(serverID: server, authorize: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.authorizeTagClassification(server: server)
                }, onProgress: { [weak self] progress in
                    await self?.updateTagClassificationProgress(progress)
                })
                self.tagClassification.message = "标签分类已完成。"
#if os(iOS)
                self.clearTagClassificationBackgroundRequest()
#endif
            } catch is CancellationError {
                if self.tagClassification.message == nil { self.tagClassification.message = "已暂停，已完成批次已保存。" }
            } catch {
                self.tagClassification.message = error.localizedDescription
#if os(iOS)
                self.clearTagClassificationBackgroundRequest()
#endif
            }
            self.tagClassification.status = try? await self.catalogCoordinator.store.recommendationIndexStatus(serverID: server)
            self.tagClassification.unlabeledTracks = (try? await self.catalogCoordinator.store.emptyRecommendationClassificationCount(serverID: server)) ?? 0
            if self.tagClassification.unlabeledTracks > 0, self.tagClassification.message == "标签分类已完成。" {
                self.tagClassification.message = "本轮处理完成，部分曲目未获得标签，可单独重试。"
            }
        }
    }

    public func pauseTagClassification(message: String? = nil) {
#if os(iOS)
        clearTagClassificationBackgroundRequest()
#endif
        guard tagClassificationTask != nil else { return }
        tagClassification.message = message ?? "已暂停，已完成批次已保存。"
        tagClassificationTask?.cancel()
    }

    private func updateTagClassificationProgress(_ progress: TagClassificationProgress) {
        tagClassification.status = progress.status
        // The browser refresh key advances only after a committed batch, never when a request starts.
        if case .preparing = progress.phase { tagClassification.batchNumber = progress.batchNumber }
        tagClassification.progress = progress
    }

    private func authorizeTagClassification(server: ServerID) throws {
        guard catalog.activeServerID == server else { throw TagClassificationFailure("音乐库已切换，分类已停止。") }
        guard UserDefaults.standard.object(forKey: "auralis.ai.enabled") as? Bool != false,
              AIPrivacyPermissions.current().allowsMetadata,
              UserDefaults.standard.bool(forKey: Self.classificationConsentKey) else {
            throw TagClassificationFailure("请启用 AI、允许歌曲元数据，并在标签分类设置中确认外发授权。")
        }
    }

    private func endTagClassificationBackgroundActivity() {
#if os(iOS)
        if tagClassificationBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(tagClassificationBackgroundTask)
            tagClassificationBackgroundTask = .invalid
        }
#elseif os(macOS)
        if let activity = tagClassificationActivity {
            ProcessInfo.processInfo.endActivity(activity)
            tagClassificationActivity = nil
        }
#endif
    }
}

struct TagClassificationControls: View {
    @ObservedObject var model: AuralisAppModel
    @AppStorage(AuralisAppModel.classificationConsentKey) private var allowsClassification = false
    var body: some View {
        Section(String(localized: "标签分类", bundle: .module)) {
            Toggle(String(localized: "允许发送歌曲元数据进行分类", bundle: .module), isOn: $allowsClassification)
            Text(String(localized: "只向已配置模型发送歌名、艺术家、专辑等歌曲元数据，不发送播放历史、收藏、评分、文件路径或凭据。", bundle: .module))
                .font(.caption).foregroundStyle(.secondary)
            if let status = model.tagClassification.status {
                LabeledContent(String(localized: "已处理", bundle: .module), value: "\(status.indexedTracks) / \(status.totalTracks)")
                LabeledContent(String(localized: "待处理", bundle: .module), value: "\(status.pendingTracks)")
                ProgressView(value: Double(status.indexedTracks), total: Double(max(1, status.totalTracks)))
            }
            if model.tagClassification.isRunning {
                Label(String(localized: "正在后台分类", bundle: .module), systemImage: "arrow.triangle.2.circlepath")
                if let progress = model.tagClassification.progress {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(classificationDetail(progress, now: timeline.date))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(String(localized: "正在读取待分类歌曲…", bundle: .module)).font(.caption).foregroundStyle(.secondary)
                }
                Button(String(localized: "暂停分类", bundle: .module)) { model.pauseTagClassification() }
            } else {
                Button(String(localized: "开始/继续分类", bundle: .module)) { model.startTagClassification() }
                    .disabled(!allowsClassification || model.catalog.activeServerID == nil)
                Button(String(localized: "刷新状态", bundle: .module)) { Task { await model.refreshTagClassificationStatus() } }
            }
            if let message = model.tagClassification.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if model.tagClassification.unlabeledTracks > 0 {
                LabeledContent(String(localized: "未获得标签", bundle: .module), value: "\(model.tagClassification.unlabeledTracks)")
                Button(String(localized: "重试无标签曲目", bundle: .module)) { model.startTagClassification(retryUnlabeled: true) }
                    .disabled(!allowsClassification || model.tagClassification.isRunning)
            }
            Text(String(localized: "离开此页面后继续分类。暂停、失败或系统中断后可从已保存进度继续；系统可能限制后台运行时间。", bundle: .module))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.refreshTagClassificationStatus() }
        .onChange(of: allowsClassification) { _, allowed in
            if !allowed { model.pauseTagClassification() }
        }
    }

    private func classificationDetail(_ progress: TagClassificationProgress, now: Date) -> String {
        switch progress.phase {
        case .preparing:
            return String(localized: "正在读取待分类歌曲…", bundle: .module)
        case .requesting:
            let seconds = max(0, Int(now.timeIntervalSince(progress.requestStartedAt ?? now)))
            return String(localized: "正在请求模型：第 \(progress.batchNumber) 批，\(progress.batchSize) 首；标签组 \(progress.partNumber)/\(progress.partCount)，已等待 \(seconds) 秒（最多 60 秒）。", bundle: .module)
        case .validating:
            return String(localized: "已收到模型结果，正在校验标签…", bundle: .module)
        case .committing:
            return String(localized: "标签已校验，正在保存分类结果…", bundle: .module)
        }
    }
}

struct TagClassificationSettingsPage: View {
    @ObservedObject var model: AuralisAppModel
    var body: some View {
        Form { TagClassificationControls(model: model) }
            .navigationTitle(String(localized: "标签分类", bundle: .module))
    }
}
