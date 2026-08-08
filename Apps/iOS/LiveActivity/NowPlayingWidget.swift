import Domain
import SwiftUI
import WidgetKit

/// 「正在播放」桌面小组件：读取 App Group 共享容器中的播放快照。
/// 数据由主 App 在每次播放状态变化时写入（playback-snapshot.json）。
struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: PlaybackActivityAttributes.ContentState?
}

struct NowPlayingTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: .now, snapshot: Self.readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(
            entries: [NowPlayingEntry(date: .now, snapshot: Self.readSnapshot())],
            policy: .after(Date().addingTimeInterval(5 * 60))
        ))
    }

    /// 读取共享容器中的播放快照（失败返回 nil → 显示占位）。
    static func readSnapshot() -> PlaybackActivityAttributes.ContentState? {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.auralis.player"
        ) else { return nil }
        let url = group.appendingPathComponent("Auralis/playback-snapshot.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlaybackActivityAttributes.ContentState.self, from: data)
    }
}

struct NowPlayingWidgetView: View {
    let snapshot: PlaybackActivityAttributes.ContentState?

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 4) {
                Text("正在播放")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(snapshot.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(snapshot.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(
                    value: snapshot.duration > 0
                        ? min(max(snapshot.position / snapshot.duration, 0), 1)
                        : 0
                )
                .tint(.accentColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("暂无播放")
                    .font(.headline)
                Text("打开澜音开始播放后，这里会显示当前歌曲。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        }
    }
}

struct AuralisNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AuralisNowPlaying", provider: NowPlayingTimelineProvider()) { entry in
            NowPlayingWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("正在播放")
        .description("显示当前播放的歌曲、艺术家与进度")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
