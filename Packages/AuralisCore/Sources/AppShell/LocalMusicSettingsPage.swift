// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ThemeEngine
import UniformTypeIdentifiers

/// Local-library management intentionally lives only in Settings.
struct LocalMusicSettingsPage: View {
    let theme: BuiltInTheme
    @StateObject private var library = LocalMusicLibraryStore.shared
    @State private var isImporting = false
    @State private var importMessage: String?

    var body: some View {
        Form {
            Section("本地音乐库") {
                LabeledContent("已扫描歌曲", value: "\(library.tracks.count)")
                if let scan = library.lastScan {
                    LabeledContent(
                        "最近扫描",
                        value: "\(scan.discoveredFiles) 个项目 · \(scan.failedFiles) 个失败"
                    )
                }
#if os(iOS)
                Button {
                    isImporting = true
                } label: {
                    Label("导入歌曲", systemImage: "square.and.arrow.down")
                }

                Text("可选择歌曲文件或已经整理好的单曲文件夹。Auralis 会识别音频标签、同目录封面、LRC/TXT 歌词与 metadata.json，并复制整理为“我的 iPhone/iPad → Auralis → LocalMusic”中的一歌一文件夹标准结构。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
#else
                Button {
                    isImporting = true
                } label: {
                    Label("添加音乐文件夹", systemImage: "folder.badge.plus")
                }
#endif
                Button {
                    Task { _ = await library.scanAll() }
                } label: {
                    Label(library.isScanning ? "正在扫描…" : "重新扫描全部", systemImage: "arrow.clockwise")
                }
                .disabled(library.isScanning || library.sources.isEmpty)

                if let importMessage {
                    Text(importMessage)
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            }

            Section("来源") {
                if library.sources.isEmpty {
                    Text("尚未添加本地音乐来源。")
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                ForEach(library.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.displayName)
                            Text(source.id == LocalMusicLibraryStore.managedSourceID ? "文件 App 可见目录 · 一歌一文件夹" : "已持久授权")
                                .font(.caption)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                        Spacer()
                        if source.id != LocalMusicLibraryStore.managedSourceID {
                            Button(role: .destructive) {
                                library.removeSource(source)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("下载") {
#if os(iOS)
                Text("从服务器音乐库下载完成后，Auralis 会把音频移动到同一个 Files 可见的 LocalMusic 目录，并自动建立标准单曲文件夹；可获取时同时写入 cover、LRC/TXT 歌词和 metadata.json。下载仍由 Auralis 下载管理器维护，不会被本地扫描重复导入。")
#else
                Text("服务器下载继续由 Auralis 下载管理器维护，并保持稳定的本地 canonical 身份。")
#endif
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }

            if let error = library.lastError {
                Section("错误") {
                    Text(error)
                }
            }
        }
        .navigationTitle("本地音乐")
        .scrollContentBackground(.hidden)
        .background(theme.colorTokens.background.color)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task { @MainActor in
#if os(iOS)
                    importMessage = "正在导入…"
                    let summary = await LocalMusicPackageManager.importItems(urls)
                    if summary.imported > 0 {
                        _ = await library.scanAll()
                    }
                    if summary.failed == 0 {
                        importMessage = "已导入 \(summary.imported) 首歌曲"
                    } else {
                        importMessage = "已导入 \(summary.imported) 首，\(summary.failed) 个项目未能识别或整理"
                    }
#else
                    for url in urls {
                        await library.addSource(url: url)
                    }
#endif
                }
            case .failure(_):
                importMessage = "未能读取所选项目"
            }
        }
    }

    private var importContentTypes: [UTType] {
#if os(iOS)
        [.audio, .folder]
#else
        [.folder]
#endif
    }
}
