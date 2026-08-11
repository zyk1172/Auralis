import AgentKit
import DesignSystem
import Domain
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
        Section("本地音乐目录") {
            phaseRow
            if let status = currentStatus {
                LabeledContent(
                    "上次同步",
                    value: status.lastCompletedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "从未同步"
                )
                if status.isStale {
                    Label("目录可能已过期，建议刷新", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.warning.color)
                }
                LabeledContent("上次处理", value: "\(status.lastProcessedCount) 条记录")
            }

            HStack {
                if isSyncing {
                    Button("取消同步") { coordinator.cancelSync() }
                        .buttonStyle(HapticBorderedButtonStyle())
                } else {
                    Button("立即刷新") { withServerID { coordinator.manualRefresh(serverID: $0) } }
                        .buttonStyle(HapticBorderedButtonStyle())
                    Button("完全重建") { isRebuilding = true }
                        .buttonStyle(HapticDestructiveButtonStyle())
                    if case .failed = coordinator.phase {
                        Button("重试") { withServerID { coordinator.retry(serverID: $0) } }
                            .buttonStyle(HapticBorderedButtonStyle())
                    }
                }
            }
            .disabled(!model.catalog.isConnected)

            Text("目录保存在本机 SQLite（含全文检索索引），按服务器隔离。助手只查询你需要的结果，绝不会把整个曲库发给大模型。")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
        }
        .task { await coordinator.refreshStatuses() }
        .alert("完全重建目录？", isPresented: $isRebuilding) {
            Button("重建", role: .destructive) {
                withServerID { coordinator.fullRebuild(serverID: $0) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空本机目录并从服务器重新拉取全部数据，耗时较长。服务器数据不受影响。")
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
            LabeledContent("状态", value: model.catalog.isConnected ? "空闲" : "未连接服务器")
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
                "同步完成 · \(tracks) 首 · \(at.formatted(date: .omitted, time: .shortened))",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(theme.colorTokens.success.color)
        case let .upToDate(tracks):
            Label("目录已是最新 · \(tracks) 首（已用本地缓存，无需拉取）", systemImage: "checkmark.circle")
                .foregroundStyle(theme.colorTokens.success.color)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 2) {
                Label("同步失败", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.colorTokens.error.color)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        case .cancelled:
            Label("已取消同步", systemImage: "xmark.circle")
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
        Section("本地缓存") {
            LabeledContent("临时音频缓存", value: "\(usage.audioCount) 首 · \(Self.format(usage.audioBytes))")
            LabeledContent("元数据目录", value: Self.format(usage.catalogBytes))
            Text("App 只在本机持久化音乐库元数据（歌曲、专辑、艺术家、流派、歌单、收藏与播放记录）。封面与歌词按需从服务器加载，不主动缓存；离线下载的歌曲仍会占用临时音频缓存。")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AuralisSpacing.small) {
                    cacheAction("清理历史封面", symbol: "photo.on.rectangle") { confirmClearArtwork = true }
                    cacheAction("清理历史歌词", symbol: "text.quote") { run { await model.clearLyricsCache() } }
                    cacheAction("清理临时音频", symbol: "waveform.slash") { confirmClearAudio = true }
                }
                VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                    HStack(spacing: AuralisSpacing.small) {
                        cacheAction("清理历史封面", symbol: "photo.on.rectangle") { confirmClearArtwork = true }
                        cacheAction("清理历史歌词", symbol: "text.quote") { run { await model.clearLyricsCache() } }
                    }
                    cacheAction("清理临时音频", symbol: "waveform.slash") { confirmClearAudio = true }
                }
            }
            .disabled(isWorking)
        }
        .task { await reload() }
        .alert("清理历史封面缓存？", isPresented: $confirmClearArtwork) {
            Button("清理", role: .destructive) { run { await model.clearArtworkCache() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机已缓存的全部封面图片。今后封面只按需从服务器加载，不再主动缓存。")
        }
        .alert("清理临时音频缓存？", isPresented: $confirmClearAudio) {
            Button("清理", role: .destructive) { run { await model.clearAudioCache() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机已下载的临时音频缓存文件；用户主动下载的离线音乐不会被删除。")
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

/// 设置页「小猫的记忆」区块：查看跨会话记忆与技能、清空记忆。
/// 记忆与技能由 AI 助手工具（memory_* / skill_*）读写，只存在本机 App Support。
struct AgentMemoryManagementSection: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    @State private var memories: [AgentMemoryEntry] = []
    @State private var skills: [AgentSkillEntry] = []
    @State private var confirmClear = false

    private var store: AgentMemoryStore { model.agentCoordinator.memoryStore }

    var body: some View {
        Section {
            if memories.isEmpty {
                Label("还没有记住关于主人的事情。跟小猫说「我叫XX」「我喜欢XX」，小猫就会记住喵", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            } else {
                ForEach(memories) { memory in
                    LabeledContent(memory.key, value: memory.value)
                }
            }
            if !skills.isEmpty {
                ForEach(skills) { skill in
                    LabeledContent("技能 · \(skill.name)", value: skill.summary)
                }
            }
            if !memories.isEmpty || !skills.isEmpty {
                Button("清空全部记忆", role: .destructive) { confirmClear = true }
            }
        } header: {
            Text("小猫的记忆（AI 助手）")
        } footer: {
            Text("记忆与技能只存在本机 App Support，不会上传；每次 AI 对话开始时自动注入给小猫，让它跨会话记得你。技能是一段可复用指令，可让小猫用「创建一个技能」存下来。")
        }
        .task { reload() }
        .confirmationDialog("清空小猫的全部记忆？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                _ = store.clearMemory()
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后小猫将不再记得这些信息。技能文件不会被删除。")
        }
    }

    private func reload() {
        memories = store.memories
        skills = store.skills
    }
}
