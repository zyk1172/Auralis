import DesignSystem
import Domain
import OfflineManager
import SwiftUI
import ThemeEngine

/// iPhone / iPad 下载管理页。它同时展示排队、传输、失败和已完成项目，失败不会再
/// 从界面消失；每一种状态都有明确的恢复动作。
struct DownloadManagementView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    @State private var confirmsRemoveAll = false

    private var activeTracks: [Track] { model.activeDownloadTracks }
    private var failedTracks: [Track] { model.failedDownloadTracks }
    private var downloadedTracks: [Track] {
        model.downloadedTracks.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        List {
            summarySection

            if let message = model.lastDownloadOperationError {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }

            if !activeTracks.isEmpty {
                Section("正在下载") {
                    ForEach(activeTracks) { track in
                        DownloadActivityRow(track: track, info: model.downloadInfo(for: track), theme: theme) {
                            model.cancelDownload(track)
                        }
                    }
                }
            }

            if !failedTracks.isEmpty {
                Section("需要处理") {
                    ForEach(failedTracks) { track in
                        DownloadActivityRow(track: track, info: model.downloadInfo(for: track), theme: theme) {
                            model.retryDownload(track)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("重试") { model.retryDownload(track) }
                                .tint(theme.colorTokens.accent.color)
                        }
                    }
                }
            }

            if !downloadedTracks.isEmpty {
                Section("已下载 · \(downloadedTracks.count) 首") {
                    ForEach(downloadedTracks) { track in
                        Button {
                            model.queue = model.uniquedTracks(downloadedTracks)
                            model.selectAndPlay(track)
                        } label: {
                            HStack(spacing: AuralisSpacing.medium) {
                                ArtworkView(
                                    title: track.title,
                                    artworkKey: track.artworkKey,
                                    colors: theme.colorTokens,
                                    size: 44
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title)
                                        .foregroundStyle(theme.colorTokens.primaryText.color)
                                        .lineLimit(1)
                                    Text(downloadedSubtitle(for: track))
                                        .font(.caption)
                                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(theme.colorTokens.accent.color)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HapticPlainButtonStyle())
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.removeDownload(track)
                            } label: {
                                Label("删除下载", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if activeTracks.isEmpty, failedTracks.isEmpty, downloadedTracks.isEmpty {
                Section {
                    ContentUnavailableView(
                        "暂无下载",
                        systemImage: "arrow.down.circle",
                        description: Text("在歌曲、专辑或歌单菜单中选择“下载到本地”，即可离线播放。")
                    )
                }
                .listRowBackground(Color.clear)
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
        .confirmationDialog(
            "删除全部本地音乐？",
            isPresented: $confirmsRemoveAll,
            titleVisibility: .visible
        ) {
            Button("删除全部下载", role: .destructive) {
                Task { await model.removeAllDownloads() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除这台设备上的离线文件，不会删除音乐服务器上的歌曲。")
        }
    }

    private var summarySection: some View {
        Section {
            HStack(spacing: AuralisSpacing.medium) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(theme.colorTokens.accent.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text("离线音乐")
                        .font(.headline)
                    Text("\(downloadedTracks.count) 首 · \(Self.byteText(model.downloadedAudioBytes))")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer()
                Menu {
                    if !activeTracks.isEmpty {
                        Button(role: .destructive) {
                            model.cancelAllDownloads()
                        } label: {
                            Label("取消全部下载", systemImage: "xmark.circle")
                        }
                    }
                    Button(role: .destructive) {
                        confirmsRemoveAll = true
                    } label: {
                        Label("删除全部本地音乐", systemImage: "trash")
                    }
                    .disabled(downloadedTracks.isEmpty && activeTracks.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .accessibilityLabel("下载管理")
            }
            .padding(.vertical, AuralisSpacing.xSmall)
        }
    }

    private func downloadedSubtitle(for track: Track) -> String {
        guard let entry = model.downloadedEntry(for: track) else { return track.artistName }
        return "\(track.artistName) · \(Self.byteText(entry.byteCount))"
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}

struct DownloadActivityRow: View {
    let track: Track
    let info: DownloadTaskInfo?
    let theme: BuiltInTheme
    let action: () -> Void

    private var isFailed: Bool { info?.status == .failed }
    private var isQueued: Bool { info?.status == .queued }

    var body: some View {
        HStack(spacing: AuralisSpacing.medium) {
            ArtworkView(title: track.title, artworkKey: track.artworkKey, colors: theme.colorTokens, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(statusText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isFailed ? .orange : theme.colorTokens.secondaryText.color)
                }
                Text(isFailed ? (info?.failure?.message ?? "下载失败，请重试") : track.artistName)
                    .font(.caption)
                    .foregroundStyle(isFailed ? .orange : theme.colorTokens.secondaryText.color)
                    .lineLimit(2)
                if !isFailed, !isQueued {
                    ProgressView(value: info?.progress ?? 0)
                        .tint(theme.colorTokens.accent.color)
                        .accessibilityLabel("《\(track.title)》下载进度")
                        .accessibilityValue(statusText)
                }
            }
            Button(action: action) {
                Image(systemName: isFailed ? "arrow.clockwise" : "xmark.circle.fill")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFailed ? theme.colorTokens.accent.color : .secondary)
            .help(isFailed ? "重试" : "取消下载")
            .accessibilityLabel(isFailed ? "重试下载《\(track.title)》" : "取消下载《\(track.title)》")
        }
        .padding(.vertical, 3)
    }

    private var statusText: String {
        guard let info else { return "准备中" }
        switch info.status {
        case .queued: return "排队中"
        case .downloading:
            let percent = Int((info.progress * 100).rounded())
            if info.byteCount > 0 {
                return "\(percent)% · \(DownloadManagementView.byteText(info.byteCount))"
            }
            return "\(percent)%"
        case .failed: return "下载失败"
        case .downloaded: return "已完成"
        case .notDownloaded: return "未下载"
        }
    }
}
