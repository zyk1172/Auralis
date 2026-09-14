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
                Button {
                    isImporting = true
                } label: {
                    Label("添加音乐文件夹", systemImage: "folder.badge.plus")
                }
                Button {
                    Task { _ = await library.scanAll() }
                } label: {
                    Label(library.isScanning ? "正在扫描…" : "重新扫描全部", systemImage: "arrow.clockwise")
                }
                .disabled(library.isScanning || library.sources.isEmpty)
            }

            Section("来源") {
                if library.sources.isEmpty {
                    Text("尚未添加本地音乐文件夹。服务器下载的歌曲会自动进入 Auralis 管理的本地音乐库。")
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                ForEach(library.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.displayName)
                            Text("已持久授权")
                                .font(.caption)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            library.removeSource(source)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("下载") {
                Text("服务器下载保存到 Auralis/LocalMusic/Downloads。下载完成后建立本地 canonical 身份，同时保留服务器身份作为兼容别名，现有队列、历史和歌单不会因身份切换失效。")
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
