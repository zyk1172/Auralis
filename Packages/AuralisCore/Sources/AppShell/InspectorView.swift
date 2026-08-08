import AVFoundation
import DesignSystem
import Domain
import SwiftUI
import ThemeEngine

struct InspectorView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    var body: some View {
        VStack(spacing: 0) {
            Picker("检查器", selection: $model.inspector) {
                ForEach(InspectorSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.menu)
            .padding()
            Divider()
            Group {
                switch model.inspector {
                case .queue: queue
                case .lyrics: lyrics
                case .quality: quality
                case .metadata: metadata
                }
            }
        }
        .background(theme.colorTokens.elevated.color)
        .navigationTitle("检查器")
    }

    private var queue: some View {
        List {
            ForEach(model.queue) { track in
                TrackRow(track: track, isCurrent: track.id == model.currentTrack.id, theme: theme)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectAndPlay(track) }
                    .contextMenu {
                        Button(role: .destructive) { model.removeFromQueue(track) } label: {
                            Label("从队列移除", systemImage: "trash")
                        }
                    }
            }
            .onDelete { model.removeFromQueue(atOffsets: $0) }
        }
        .listStyle(.plain)
    }

    private var lyrics: some View {
        ScrollView {
            LazyVStack(alignment: .center, spacing: AuralisSpacing.large) {
                if let document = model.currentLyrics {
                    ForEach(document.lines) { line in
                        Text(line.text)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    AuralisEmptyState(icon: "quote.bubble", title: "暂无歌词", message: "此曲目暂无歌词数据。", colors: theme.colorTokens)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private var quality: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AuralisSpacing.large) {
                ArtworkView(title: model.currentTrack.albumTitle, artworkKey: model.currentTrack.artworkKey, colors: theme.colorTokens, size: 160)
                    .frame(maxWidth: .infinity)
                qualityRow("源文件", value: sourceDescription)
                qualityRow("服务器", value: serverDeliveryDescription)
                qualityRow("客户端解码", value: decodeDescription)
                qualityRow("输出路由", value: outputRouteDescription)
                qualityRow("ReplayGain", value: "未启用")
                Text("Auralis 不宣称 bit-perfect。无法从当前链路读取的参数明确显示为“未知”。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            .padding()
        }
    }

    private var metadata: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
                metadataField("标题", original: model.currentTrack.title, suggested: normalizedTitle)
                metadataField("艺术家", original: model.currentTrack.artistName, suggested: nil)
                metadataField("专辑", original: model.currentTrack.albumTitle, suggested: nil)
                metadataField("年份", original: model.currentTrack.year.map(String.init) ?? "未知", suggested: nil)
                Divider()
                Text("技术参数").font(.caption.weight(.semibold)).foregroundStyle(theme.colorTokens.secondaryText.color)
                metadataRow("音频格式", value: model.currentTrack.effectiveCodec?.uppercased() ?? "未知")
                metadataRow("码率", value: model.currentTrack.sourceInfo.bitRate.map { "\($0) kbps" } ?? "未知")
                metadataRow("采样率", value: model.currentTrack.sourceInfo.sampleRate.map { "\($0) Hz" } ?? "未知")
                metadataRow("位深", value: model.currentTrack.sourceInfo.bitDepth.map { "\($0) bit" } ?? "未知")
                metadataRow("声道", value: model.currentTrack.sourceInfo.channelCount.map { "\($0) 声道" } ?? "未知")
                metadataRow("曲目号", value: model.currentTrack.trackNumber.map(String.init) ?? "未知")
                metadataRow("光盘号", value: model.currentTrack.discNumber.map(String.init) ?? "未知")
                metadataRow("流派", value: model.currentTrack.genres.isEmpty ? "未知" : model.currentTrack.genres.joined(separator: "、"))
                Divider()
                Text("状态").font(.caption.weight(.semibold)).foregroundStyle(theme.colorTokens.secondaryText.color)
                metadataRow("评分", value: model.currentTrack.rating.map { "\($0)/5" } ?? "未评分")
                metadataRow("播放次数", value: "\(model.playCounts[model.currentTrack.id] ?? 0) 次")
                metadataRow("收藏", value: model.currentTrack.isFavorite ? "已收藏" : "未收藏")
                metadataRow("歌词", value: model.currentLyrics == nil ? "无" : "已获取")
                metadataRow("离线", value: model.isDownloaded(model.currentTrack) ? "已下载" : "未下载")
                HStack {
                    Button("接受建议") {}
                        .buttonStyle(HapticProminentButtonStyle())
                        .disabled(true)
                    Button("拒绝") {}
                        .buttonStyle(HapticBorderedButtonStyle())
                        .disabled(true)
                    Button("恢复原始值") {}
                        .buttonStyle(HapticBorderedButtonStyle())
                        .disabled(true)
                }
                Text("元数据写入需要预览、备份和回滚机制，将在后续阶段实现。当前仅展示原始值与 AI 建议。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            .padding()
        }
    }

    private func qualityRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(theme.colorTokens.secondaryText.color)
            Text(value).font(.body.monospaced()).foregroundStyle(theme.colorTokens.primaryText.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(theme.colorTokens.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium))
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(theme.colorTokens.secondaryText.color)
            Spacer()
            Text(value).font(.callout).foregroundStyle(theme.colorTokens.primaryText.color)
        }
        .padding(.horizontal, AuralisSpacing.medium)
    }

    private func metadataField(_ label: String, original: String, suggested: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(theme.colorTokens.secondaryText.color)
            Text(original).foregroundStyle(theme.colorTokens.primaryText.color)
            if let suggested, suggested != original {
                Label(suggested, systemImage: "sparkles")
                    .foregroundStyle(theme.colorTokens.accent.color)
                Text("来源：AI 规范化 · 需要用户审查")
                    .font(.caption2)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(theme.colorTokens.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium))
    }

    private var serverDeliveryDescription: String {
        if case .connected = model.serverConnectionState { return "Direct Play" }
        return "未连接服务器"
    }

    private var outputRouteDescription: String {
        #if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute
        if let output = route.outputs.first { return output.portName }
        return "系统默认"
        #else
        return "系统默认"
        #endif
    }

    private var sourceDescription: String {
        let info = model.currentTrack.sourceInfo
        return "\(info.normalizedCodec?.uppercased() ?? "未知") · \(info.bitDepth.map { "\($0)-bit" } ?? "未知") · \(info.sampleRate.map { "\($0 / 1_000) kHz" } ?? "未知") · \(info.bitRate.map { "\($0 / 1_000) kbps" } ?? "未知")"
    }

    private var decodeDescription: String {
        let info = model.currentTrack.sourceInfo
        return "PCM · \(info.bitDepth.map { "\($0)-bit" } ?? "未知") · \(info.sampleRate.map { "\($0 / 1_000) kHz" } ?? "未知")"
    }

    private var normalizedTitle: String? {
        model.currentTrack.title.replacingOccurrences(of: "  ", with: " ")
    }
}

struct ServerStatus: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    var body: some View {
        HStack(spacing: AuralisSpacing.small) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isConnected ? theme.colorTokens.success.color : theme.colorTokens.secondaryText.color)
            VStack(alignment: .leading) {
                Text(title).font(.caption.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Spacer()
        }
        .padding()
        .background(theme.colorTokens.surface.color)
    }

    private var isConnected: Bool {
        if case .connected = model.serverConnectionState { return true }
        return false
    }

    private var title: String {
        switch model.serverConnectionState {
        case let .connected(account, _, _, _): account.displayName
        case .connecting: "正在连接服务器"
        case .failed: "连接失败"
        case .idle: "未连接服务器"
        }
    }

    private var subtitle: String {
        switch model.serverConnectionState {
        case let .connected(_, serverType, _, trackCount):
            "\([serverType].compactMap { $0 }.joined(separator: " · ")) · \(trackCount) 首歌曲"
        case let .connecting(stage): stage.title
        case .failed: "请在设置中检查服务器配置"
        case .idle: "请在设置中添加 OpenSubsonic 服务器"
        }
    }
}
