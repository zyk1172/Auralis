// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ThemeEngine
import UniformTypeIdentifiers

/// Local-library management intentionally lives only in Settings.
struct LocalMusicSettingsPage: View {
    let theme: BuiltInTheme
    @StateObject private var library = LocalMusicLibraryStore.shared
    @State private var isImporting = false

    var body: some View {
        Form {
            Section("本地音乐库") {
                LabeledContent("已扫描歌曲", value: "\(library.tracks.count)")
                if let scan = library.lastScan {
                    LabeledContent(
                        "最近扫描",
                        value: "\(scan.discoveredFiles) 个文件 · \(scan.failedFiles) 个失败"
                    )
                }
#if os(iOS)
                Text("Auralis 会自动建立可在“文件”App 中访问的本地音乐目录：我的 iPhone → Auralis → LocalMusic。直接把音乐文件复制进去即可，不需要先创建或选择文件夹。")
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
            }

            Section("来源") {
                if library.sources.isEmpty {
                    Text("尚未添加本地音乐文件夹。服务器下载的歌曲仍会由 Auralis 单独管理。")
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                ForEach(library.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.displayName)
                            Text(source.id == LocalMusicLibraryStore.managedSourceID ? "文件 App 可见目录" : "已持久授权")
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
                Text("服务器下载由 Auralis 下载管理器单独维护，并在完成后获得稳定的本地 canonical 身份；它们不要求用户预先选择文件夹，也不会与“文件”App 中的 LocalMusic 导入目录混为同一个来源。")
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
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            Task {
                for url in urls {
                    await library.addSource(url: url)
                }
            }
        }
    }
}
