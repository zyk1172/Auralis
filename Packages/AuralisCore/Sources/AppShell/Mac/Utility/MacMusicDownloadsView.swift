#if os(macOS)
import SwiftUI
import ThemeEngine
import Domain
import LocalCatalog

/// 下载中心：排队 / 传输 / 失败 / 已完成四态完整呈现，并提供重试、取消和清理闭环。
struct MacMusicDownloadsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }
    @State private var confirmsRemoveAll = false
    @State private var confirmsRemoveSelected = false

    private var tracks: [Track] {
        model.downloadedTracks.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var activeTracks: [Track] { model.activeDownloadTracks }
    private var failedTracks: [Track] { model.failedDownloadTracks }
    private var selectedDownloadedTracks: [Track] {
        selection.compactMap { model.track(for: $0) }.filter { model.isDownloaded($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(
                title: String(localized: "下载", bundle: .module),
                subtitle: String(localized: "\(tracks.count) 首离线音乐 · \(DownloadManagementView.byteText(model.downloadedAudioBytes))", bundle: .module)
            ) {
                if !tracks.isEmpty {
                    MacPrimaryButton(title: String(localized: "随机播放", bundle: .module), systemImage: "shuffle") {
                        model.playShuffledQueue(tracks)
                    }
                }
                Menu {
                    if !activeTracks.isEmpty {
                        Button(role: .destructive) {
                            model.cancelAllDownloads()
                        } label: {
                            Label(String(localized: "取消全部下载", bundle: .module), systemImage: "xmark.circle")
                        }
                    }
                    Button(role: .destructive) {
                        confirmsRemoveSelected = true
                    } label: {
                        Label(String(localized: "删除所选下载", bundle: .module), systemImage: "trash")
                    }
                    .disabled(selectedDownloadedTracks.isEmpty)
                    Button(role: .destructive) {
                        confirmsRemoveAll = true
                    } label: {
                        Label(String(localized: "删除全部本地音乐", bundle: .module), systemImage: "trash.slash")
                    }
                    .disabled(tracks.isEmpty && activeTracks.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(String(localized: "下载管理", bundle: .module))
            }

            if let error = model.lastDownloadOperationError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline)
                    Spacer()
                    Button {
                        model.clearDownloadOperationError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "关闭下载错误", bundle: .module))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.orange.opacity(0.10))
            }

            if !activeTracks.isEmpty || !failedTracks.isEmpty {
                downloadActivityPanel
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            if tracks.isEmpty, activeTracks.isEmpty, failedTracks.isEmpty {
                ContentUnavailableView(
                    String(localized: "暂无下载", bundle: .module),
                    systemImage: "arrow.down.circle",
                    description: Text(String(localized: "在歌曲、专辑或播放列表菜单中选择“下载”，即可离线播放。", bundle: .module))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                Spacer(minLength: 0)
            } else {
                MacSongTable(
                    tracks: tracks,
                    selection: $selection,
                    model: model,
                    theme: theme,
                    onNavigate: onNavigate,
                    contentRevision: model.downloadsRevision,
                    showGenreColumn: false
                )
            }
        }
        .navigationTitle(String(localized: "下载", bundle: .module))
        .confirmationDialog(
            String(localized: "删除全部本地音乐？", bundle: .module),
            isPresented: $confirmsRemoveAll,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除全部下载", bundle: .module), role: .destructive) {
                Task { await model.removeAllDownloads() }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "只删除这台 Mac 上的离线文件，不会删除音乐服务器上的歌曲。", bundle: .module))
        }
        .confirmationDialog(
            String(localized: "删除所选的 \(selectedDownloadedTracks.count) 首本地音乐？", bundle: .module),
            isPresented: $confirmsRemoveSelected,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除所选下载", bundle: .module), role: .destructive) {
                for track in selectedDownloadedTracks { model.removeDownload(track) }
                selection.removeAll()
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "这些歌曲仍保留在音乐服务器上。", bundle: .module))
        }
    }

    private var downloadActivityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !activeTracks.isEmpty {
                HStack {
                    Text(String(localized: "正在下载", bundle: .module))
                        .font(.headline)
                    Text("\(activeTracks.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "全部取消", bundle: .module), role: .destructive) { model.cancelAllDownloads() }
                        .buttonStyle(.plain)
                }
                ForEach(activeTracks) { track in
                    DownloadActivityRow(
                        track: track,
                        info: model.downloadInfo(for: track),
                        theme: theme
                    ) {
                        model.cancelDownload(track)
                    }
                }
            }

            if !failedTracks.isEmpty {
                Divider()
                HStack {
                    Text(String(localized: "需要处理", bundle: .module))
                        .font(.headline)
                    Text("\(failedTracks.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(String(localized: "全部重试", bundle: .module)) {
                        for track in failedTracks { model.retryDownload(track) }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(failedTracks) { track in
                    DownloadActivityRow(
                        track: track,
                        info: model.downloadInfo(for: track),
                        theme: theme
                    ) {
                        model.retryDownload(track)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}
#endif
