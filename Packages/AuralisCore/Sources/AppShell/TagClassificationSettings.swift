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
    public var isWaitingForSystem = false
    public var notice: String?
    public var lastInterruptionReason: String?
}

extension AuralisAppModel {
    static let classificationConsentKey = "auralis.classification.metadataConsent"
    static let classificationRequestedServerKey = "auralis.classification.requestedServer"
    static let classificationLastMessageKey = "auralis.classification.lastMessage"
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
            clearTagClassificationRequest()
            setTagClassificationMessage(settings.completenessError ?? "请先在设置中配置大模型。", showNotice: true); return
        }
        tagClassification.isRunning = true
        let runID = UUID()
        tagClassification.runID = runID
        tagClassification.message = nil
        tagClassification.notice = nil
        tagClassification.isWaitingForSystem = false
        tagClassification.lastInterruptionReason = tagClassificationDefaults.string(forKey: Self.classificationLastMessageKey)
        tagClassification.batchNumber = 0
        tagClassification.progress = nil
        tagClassificationDefaults.set(server.rawValue, forKey: Self.classificationRequestedServerKey)
#if os(iOS)
        scheduleTagClassificationBackgroundProcessing()
#elseif os(macOS)
        tagClassificationActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Music tag classification")
#endif
        let job = TagClassificationJob(runner: TagClassificationRunner(catalog: catalogCoordinator.store, provider: provider,
            model: settings.model, maxOutputTokens: settings.maxOutputTokens, reasoning: settings.reasoning))
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
                try await job.run(serverID: server, authorize: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.authorizeTagClassification(server: server)
                }, onProgress: { [weak self] progress in
                    await self?.updateTagClassificationProgress(progress)
                })
                self.setTagClassificationMessage("标签分类已完成。")
                self.clearTagClassificationRequest()
            } catch is CancellationError {
                if self.tagClassification.message == nil { self.tagClassification.message = "已暂停，已完成批次已保存。" }
            } catch {
                self.setTagClassificationMessage("标签分类已停止：\(error.localizedDescription)", showNotice: true)
                self.clearTagClassificationRequest()
            }
            self.tagClassification.status = try? await self.catalogCoordinator.store.recommendationIndexStatus(serverID: server)
            self.tagClassification.unlabeledTracks = (try? await self.catalogCoordinator.store.emptyRecommendationClassificationCount(serverID: server)) ?? 0
            if self.tagClassification.unlabeledTracks > 0, self.tagClassification.message == "标签分类已完成。" {
                self.tagClassification.message = "本轮处理完成，部分曲目未获得标签，可单独重试。"
            }
        }
        updateTagClassificationExecutionForPlayback()
    }

    public func pauseTagClassification(message: String? = nil) {
        clearTagClassificationRequest()
        tagClassification.isWaitingForSystem = false
        setTagClassificationMessage(message ?? "已暂停，已完成批次已保存。")
        tagClassification.lastInterruptionReason = tagClassification.message
        tagClassificationDefaults.set(tagClassification.message, forKey: Self.classificationLastMessageKey)
        tagClassificationTask?.cancel()
    }

    private func updateTagClassificationProgress(_ progress: TagClassificationProgress) {
        tagClassification.status = progress.status
        // The browser refresh key advances only after a committed batch, never when a request starts.
        if case .preparing = progress.phase { tagClassification.batchNumber = progress.batchNumber }
        tagClassification.progress = progress
        if progress.phase == .retrying {
            setTagClassificationMessage("分类请求暂时未完成：\(progress.retryReason ?? "网络或模型服务暂时不可用")。任务会自动重试，已保存进度不受影响。", showNotice: true)
        } else {
            tagClassification.message = nil
            tagClassification.notice = nil
        }
    }

    func setTagClassificationMessage(_ message: String, showNotice: Bool = false) {
        tagClassification.message = message
        tagClassification.notice = showNotice ? message : nil
        if showNotice {
            tagClassification.lastInterruptionReason = message
            tagClassificationDefaults.set(message, forKey: Self.classificationLastMessageKey)
        }
    }

    func clearTagClassificationRequest() {
        tagClassificationDefaults.removeObject(forKey: Self.classificationRequestedServerKey)
#if os(iOS)
        clearTagClassificationBackgroundRequest()
#endif
    }

    func resumeRequestedTagClassification() {
        guard tagClassificationTask == nil else { return }
        if tagClassification.message == nil, let message = tagClassificationDefaults.string(forKey: Self.classificationLastMessageKey) {
            tagClassification.message = message
            tagClassification.lastInterruptionReason = message
        }
        guard let requested = tagClassificationDefaults.string(forKey: Self.classificationRequestedServerKey),
              catalog.activeServerID?.rawValue == requested else { return }
        startTagClassification()
    }

    private func authorizeTagClassification(server: ServerID) throws {
        guard catalog.activeServerID == server else { throw TagClassificationFailure("音乐库已切换，分类已停止。") }
        guard UserDefaults.standard.object(forKey: "auralis.ai.enabled") as? Bool != false,
              AIPrivacyPermissions.current().allowsMetadata,
              UserDefaults.standard.bool(forKey: Self.classificationConsentKey) else {
            throw TagClassificationFailure("请启用 AI、允许歌曲元数据，并在标签分类设置中确认外发授权。")
        }
    }

    func endTagClassificationBackgroundActivity() {
#if os(iOS)
        if tagClassificationBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(tagClassificationBackgroundTask)
            tagClassificationBackgroundTask = .invalid
        }
        tagClassificationExecution.hasShortTaskTime = false
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
            Text(String(localized: "默认每批 8 首；容量不足或结果不完整时自动缩小批量。逐首校验，整批通过后保存。", bundle: .module))
                .font(.caption).foregroundStyle(.secondary)
            if let status = model.tagClassification.status {
                LabeledContent(String(localized: "已处理", bundle: .module), value: "\(status.indexedTracks) / \(status.totalTracks)")
                LabeledContent(String(localized: "待处理", bundle: .module), value: "\(status.pendingTracks)")
                ProgressView(value: Double(status.indexedTracks), total: Double(max(1, status.totalTracks)))
            }
            if model.tagClassification.isRunning {
                Label(model.tagClassification.progress?.phase == .retrying
                    ? String(localized: "等待自动重试", bundle: .module) : String(localized: "正在后台分类", bundle: .module),
                    systemImage: "arrow.triangle.2.circlepath")
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
                if model.tagClassification.isWaitingForSystem {
                    Label(String(localized: "等待系统后台运行时间，回到前台后自动继续", bundle: .module), systemImage: "clock")
                    Button(String(localized: "停止自动继续", bundle: .module)) { model.pauseTagClassification() }
                }
                Button(String(localized: "开始/继续分类", bundle: .module)) { model.startTagClassification() }
                    .disabled(!allowsClassification || model.catalog.activeServerID == nil)
                Button(String(localized: "刷新状态", bundle: .module)) { Task { await model.refreshTagClassificationStatus() } }
            }
            if let message = model.tagClassification.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let reason = model.tagClassification.lastInterruptionReason, reason != model.tagClassification.message {
                LabeledContent(String(localized: "最近中断原因", bundle: .module)) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
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
            return String(localized: "正在请求模型：第 \(progress.batchNumber) 批，\(progress.batchSize) 首；标签组 \(progress.partNumber)/\(progress.partCount)，已等待 \(seconds) 秒（单次上限 \(progress.requestTimeoutSeconds) 秒）。", bundle: .module)
        case .validating:
            return String(localized: "已收到模型结果，正在校验标签…", bundle: .module)
        case .committing:
            return String(localized: "标签已校验，正在保存分类结果…", bundle: .module)
        case .retrying:
            let seconds = max(0, Int((progress.retryAt ?? now).timeIntervalSince(now).rounded(.up)))
            return String(localized: "\(seconds) 秒后自动重试，下一批最多 \(progress.batchSize) 首；可暂停任务。", bundle: .module)
        }
    }
}

struct TagClassificationNotice: View {
    @ObservedObject var model: AuralisAppModel
    var body: some View {
        if let notice = model.tagClassification.notice {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "标签分类", bundle: .module)).font(.headline)
                    Text(notice).font(.caption).lineLimit(4)
                    Text(String(localized: "详情与进度可在设置中的标签分类查看。", bundle: .module)).font(.caption2)
                }
                Spacer(minLength: 0)
                Button { model.tagClassification.notice = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "关闭", bundle: .module))
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16).padding(.top, 12)
            .accessibilityIdentifier("auralis.classification.notice")
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
