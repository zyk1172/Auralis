import AgentKit
import DesignSystem
import Domain
import Foundation
import LocalCatalog
import SwiftUI
import ThemeEngine

// MARK: - 本地目录同步

/// 设置页里的「本地音乐目录」区块：展示同步进度、过期提示，支持刷新 / 取消 / 重试 / 全量重建。
struct CatalogSyncSection: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @ObservedObject private var coordinator: CatalogCoordinator
    @State private var isRebuilding = false

    init(model: AuralisAppModel, theme: BuiltInTheme) {
        self.model = model
        self.theme = theme
        self.coordinator = model.catalogCoordinator
    }

    var body: some View {
        Section(String(localized: "本地音乐目录", bundle: .module)) {
            phaseRow
            if let status = currentStatus {
                LabeledContent(
                    String(localized: "上次同步", bundle: .module),
                    value: status.lastCompletedAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
                        ?? String(localized: "从未同步", bundle: .module)
                )
                if status.isStale {
                    Label(String(localized: "目录可能已过期，建议刷新", bundle: .module), systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.warning.color)
                }
                LabeledContent(
                    String(localized: "上次处理", bundle: .module),
                    value: String(localized: "\(status.lastProcessedCount) 条记录", bundle: .module)
                )
            }

            HStack {
                if isSyncing {
                    Button(String(localized: "取消同步", bundle: .module)) { coordinator.cancelSync() }
                        .buttonStyle(HapticBorderedButtonStyle())
                } else {
                    Button(String(localized: "立即刷新", bundle: .module)) { withServerID { coordinator.manualRefresh(serverID: $0) } }
                        .buttonStyle(HapticBorderedButtonStyle())
                    Button(String(localized: "完全重建", bundle: .module)) { isRebuilding = true }
                        .buttonStyle(HapticDestructiveButtonStyle())
                    if case .failed = coordinator.phase {
                        Button(String(localized: "重试", bundle: .module)) { withServerID { coordinator.retry(serverID: $0) } }
                            .buttonStyle(HapticBorderedButtonStyle())
                    }
                }
            }
            .disabled(!model.catalog.isConnected)

            Text(String(localized: "目录保存在本机 SQLite（含全文检索索引），按服务器隔离。助手只查询你需要的结果，绝不会把整个曲库发给大模型。", bundle: .module))
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
        }
        .task { await coordinator.refreshStatuses() }
        .alert(String(localized: "完全重建目录？", bundle: .module), isPresented: $isRebuilding) {
            Button(String(localized: "重建", bundle: .module), role: .destructive) {
                withServerID { coordinator.fullRebuild(serverID: $0) }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "将清空本机目录并从服务器重新拉取全部数据，耗时较长。服务器数据不受影响。", bundle: .module))
        }
    }

    private var currentStatus: CatalogSyncStatus? {
        guard let serverID = model.catalog.activeServerID else { return nil }
        return coordinator.statuses.first { $0.serverID == serverID }
    }

    private var isSyncing: Bool {
        if case .running = coordinator.phase { return true }
        return false
    }

    @ViewBuilder
    private var phaseRow: some View {
        switch coordinator.phase {
        case .idle:
            LabeledContent(
                String(localized: "状态", bundle: .module),
                value: model.catalog.isConnected
                    ? String(localized: "空闲", bundle: .module)
                    : String(localized: "未连接服务器", bundle: .module)
            )
        case let .running(stage, processed):
            HStack {
                ProgressView().controlSize(.small)
                Text(stage)
                Spacer()
                Text("\(processed)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        case let .succeeded(tracks, at):
            Label(
                String(localized: "同步完成 · \(tracks) 首 · \(at.formatted(date: .omitted, time: .shortened))", bundle: .module),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(theme.colorTokens.success.color)
        case let .upToDate(tracks):
            Label(
                String(localized: "目录已是最新 · \(tracks) 首（已用本地缓存，无需拉取）", bundle: .module),
                systemImage: "checkmark.circle"
            )
                .foregroundStyle(theme.colorTokens.success.color)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 2) {
                Label(String(localized: "同步失败", bundle: .module), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.colorTokens.error.color)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        case .cancelled:
            Label(String(localized: "已取消同步", bundle: .module), systemImage: "xmark.circle")
                .foregroundStyle(theme.colorTokens.secondaryText.color)
        }
    }

    private func withServerID(_ action: (ServerID) -> Void) {
        guard let serverID = model.catalog.activeServerID else { return }
        action(serverID)
    }
}

// MARK: - 本地缓存管理

/// 设置页里的「本地缓存」区块：只统计并清理临时音频缓存与历史封面/歌词文件，元数据目录保留。
/// 按产品要求：不再主动缓存海报与歌词，仅持久化元数据（歌曲/专辑/艺术家/流派/歌单等）。
struct CacheManagementSection: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    @State private var usage = AuralisAppModel.CacheUsage()
    @State private var isWorking = false
    @State private var confirmClearArtwork = false
    @State private var confirmClearAudio = false

    var body: some View {
        Section(String(localized: "本地缓存", bundle: .module)) {
            LabeledContent(
                String(localized: "临时音频缓存", bundle: .module),
                value: String(localized: "\(usage.audioCount) 首 · \(Self.format(usage.audioBytes))", bundle: .module)
            )
            LabeledContent(String(localized: "元数据目录", bundle: .module), value: Self.format(usage.catalogBytes))
            Text(String(localized: "App 只在本机持久化音乐库元数据（歌曲、专辑、艺术家、流派、歌单、收藏与播放记录）。封面与歌词按需从服务器加载，不主动缓存；离线下载的歌曲仍会占用临时音频缓存。", bundle: .module))
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AuralisSpacing.small) {
                    cacheAction(String(localized: "清理历史封面", bundle: .module), symbol: "photo.on.rectangle") { confirmClearArtwork = true }
                    cacheAction(String(localized: "清理历史歌词", bundle: .module), symbol: "text.quote") { run { await model.clearLyricsCache() } }
                    cacheAction(String(localized: "清理临时音频", bundle: .module), symbol: "waveform.slash") { confirmClearAudio = true }
                }
                VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                    HStack(spacing: AuralisSpacing.small) {
                        cacheAction(String(localized: "清理历史封面", bundle: .module), symbol: "photo.on.rectangle") { confirmClearArtwork = true }
                        cacheAction(String(localized: "清理历史歌词", bundle: .module), symbol: "text.quote") { run { await model.clearLyricsCache() } }
                    }
                    cacheAction(String(localized: "清理临时音频", bundle: .module), symbol: "waveform.slash") { confirmClearAudio = true }
                }
            }
            .disabled(isWorking)
        }
        .task { await reload() }
        .alert(String(localized: "清理历史封面缓存？", bundle: .module), isPresented: $confirmClearArtwork) {
            Button(String(localized: "清理", bundle: .module), role: .destructive) { run { await model.clearArtworkCache() } }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "将删除本机已缓存的全部封面图片。今后封面只按需从服务器加载，不再主动缓存。", bundle: .module))
        }
        .alert(String(localized: "清理临时音频缓存？", bundle: .module), isPresented: $confirmClearAudio) {
            Button(String(localized: "清理", bundle: .module), role: .destructive) { run { await model.clearAudioCache() } }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "将删除本机已下载的临时音频缓存文件；用户主动下载的离线音乐不会被删除。", bundle: .module))
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        isWorking = true
        Task {
            await action()
            await reload()
            isWorking = false
        }
    }

    private func cacheAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(HapticBorderedButtonStyle())
        .tint(theme.colorTokens.secondaryText.color)
    }

    private func reload() async {
        usage = await model.cacheUsage()
    }

    private static func format(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 助手偏好与反馈

/// 结构化偏好设置：场景、重复容忍度、歌单时长，以及推荐反馈的查看与撤销。

// MARK: - 小猫的记忆（AI 助手记忆管理）

/// 设置页折叠摘要使用的纯数据快照，避免内容数量一多就把整个 Form 拉长。
struct AgentMemorySettingsSnapshot: Equatable {
    let memoryCount: Int
    let skillCount: Int
    let memoryCharacterCount: Int
    let skillCharacterCount: Int

    init(memories: [AgentMemoryEntry], skills: [AgentSkillEntry]) {
        memoryCount = memories.count
        skillCount = skills.count
        memoryCharacterCount = memories.reduce(0) { $0 + $1.value.count }
        skillCharacterCount = skills.reduce(0) { $0 + $1.instructions.count }
    }

    var memorySummary: String {
            memoryCount == 0 ? String(localized: "空", bundle: .module) : String(localized: "\(memoryCount) 条 · \(memoryCharacterCount) 字符", bundle: .module)
    }

    var skillSummary: String {
            skillCount == 0 ? String(localized: "空", bundle: .module) : String(localized: "\(skillCount) 个文件 · \(skillCharacterCount) 字符", bundle: .module)
    }

    static func preview(_ value: String, limit: Int = 52) -> String {
        let flattened = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }
}

/// 设置页「小猫的记忆」区块：以“长期记忆文件 / 技能文件”分区，默认收起。
/// 用户展开分区后仍可逐条查看完整内容、删除单项或清空全部记忆。
struct AgentMemoryManagementSection: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    @State private var memories: [AgentMemoryEntry] = []
    @State private var skills: [AgentSkillEntry] = []
    @State private var isMemoryFileExpanded = false
    @State private var isSkillsDirectoryExpanded = false
    @State private var expandedMemoryIDs: Set<String> = []
    @State private var expandedSkillIDs: Set<String> = []
    @State private var confirmClear = false
    @State private var removalTarget: RemovalTarget?

    private var store: AgentMemoryStore { model.agentCoordinator.memoryStore }
    private var snapshot: AgentMemorySettingsSnapshot {
        AgentMemorySettingsSnapshot(memories: memories, skills: skills)
    }

    private enum RemovalTarget: Identifiable {
        case memory(String)
        case skill(String)

        var id: String {
            switch self {
            case let .memory(key): "memory:\(key)"
            case let .skill(name): "skill:\(name)"
            }
        }

        var title: String {
            switch self {
        case let .memory(key): String(localized: "删除记忆“\(key)”？", bundle: .module)
        case let .skill(name): String(localized: "删除技能“\(name)”？", bundle: .module)
            }
        }
    }

    var body: some View {
        Section {
            memoryFileDisclosure
            skillsDirectoryDisclosure
        } header: {
            Text(String(localized: "小猫的记忆（AI 助手）", bundle: .module))
        } footer: {
            Text(String(localized: "默认只显示数量摘要，具体信息需手动展开。记忆与技能只存在本机 App Support，不会上传；每次 AI 对话开始时会按需注入相关记忆。", bundle: .module))
        }
        .task { reload() }
        .alert(String(localized: "清空小猫的全部记忆？", bundle: .module), isPresented: $confirmClear) {
            Button(String(localized: "清空", bundle: .module), role: .destructive) {
                _ = store.clearMemory()
                reload()
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "清空后小猫将不再记得这些信息。技能文件不会被删除。", bundle: .module))
        }
        .confirmationDialog(
        removalTarget?.title ?? String(localized: "删除这项内容？", bundle: .module),
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除", bundle: .module), role: .destructive) { performPendingRemoval() }
            Button(String(localized: "取消", bundle: .module), role: .cancel) { removalTarget = nil }
        } message: {
            Text(String(localized: "此操作只删除本机对应内容，无法撤销。", bundle: .module))
        }
    }

    private var memoryFileDisclosure: some View {
        DisclosureGroup(isExpanded: $isMemoryFileExpanded) {
            if memories.isEmpty {
                Label(String(localized: "还没有长期记忆。跟小猫说“我叫…”或“我喜欢…”，它就会记住。", bundle: .module), systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            } else {
                ForEach(memories) { memory in
                    DisclosureGroup(isExpanded: memoryExpansionBinding(for: memory.id)) {
                        Text(memory.value)
                            .font(.body)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Text(String(localized: "更新于 \(memory.updatedAt.formatted(date: .abbreviated, time: .shortened))", bundle: .module))
                                .font(.caption2)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                            Spacer()
                            Button(String(localized: "删除", bundle: .module), role: .destructive) {
                                removalTarget = .memory(memory.key)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memory.key)
                                .font(.body.weight(.medium))
                            Text(AgentMemorySettingsSnapshot.preview(memory.value))
                                .font(.caption)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                                .lineLimit(1)
                        }
                    }
                }

                Button(String(localized: "清空全部长期记忆", bundle: .module), role: .destructive) { confirmClear = true }
            }
        } label: {
            collectionLabel(
                title: String(localized: "长期记忆文件", bundle: .module),
                systemImage: "brain.head.profile",
                summary: snapshot.memorySummary
            )
        }
    }

    private var skillsDirectoryDisclosure: some View {
        DisclosureGroup(isExpanded: $isSkillsDirectoryExpanded) {
            if skills.isEmpty {
                Label(String(localized: "还没有技能文件。可让小猫用“创建一个技能”保存可复用指令。", bundle: .module), systemImage: "doc.badge.plus")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            } else {
                ForEach(skills) { skill in
                    DisclosureGroup(isExpanded: skillExpansionBinding(for: skill.id)) {
                        Text(skill.instructions)
                            .font(.body)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Text(String(localized: "修改于 \(skill.createdAt.formatted(date: .abbreviated, time: .shortened))", bundle: .module))
                                .font(.caption2)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                            Spacer()
                            Button(String(localized: "删除技能", bundle: .module), role: .destructive) {
                                removalTarget = .skill(skill.name)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                                .font(.body.weight(.medium))
                            Text(AgentMemorySettingsSnapshot.preview(skill.summary))
                                .font(.caption)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } label: {
            collectionLabel(
                title: String(localized: "技能文件", bundle: .module),
                systemImage: "folder",
                summary: snapshot.skillSummary
            )
        }
    }

    private func collectionLabel(title: String, systemImage: String, summary: String) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(theme.colorTokens.accent.color)
        }
    }

    private func memoryExpansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedMemoryIDs.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedMemoryIDs.insert(id) }
                else { expandedMemoryIDs.remove(id) }
            }
        )
    }

    private func skillExpansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedSkillIDs.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedSkillIDs.insert(id) }
                else { expandedSkillIDs.remove(id) }
            }
        )
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { removalTarget != nil },
            set: { if !$0 { removalTarget = nil } }
        )
    }

    private func performPendingRemoval() {
        guard let removalTarget else { return }
        switch removalTarget {
        case let .memory(key):
            _ = store.deleteMemory(key: key)
        case let .skill(name):
            _ = store.deleteSkill(name: name)
        }
        self.removalTarget = nil
        reload()
    }

    private func reload() {
        memories = store.memories
        skills = store.skills
        expandedMemoryIDs.formIntersection(memories.map(\.id))
        expandedSkillIDs.formIntersection(skills.map(\.id))
    }
}
