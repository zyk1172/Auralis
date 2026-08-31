import Foundation

/// One canonical planning hint. Composition examples never define a tool,
/// grant authorization, or replace ToolSelector / ToolRuntime. They only show
/// common ways model-visible tools are used together.
public struct ToolCompositionExample: Sendable, Hashable {
    public let id: String
    public let goal: String
    public let userExamples: [String]
    public let steps: [ToolCompositionStep]
    public let note: String?
    /// True when every referenced tool is read-only; used by evidence phases.
    public let readOnly: Bool

    public init(
        id: String,
        goal: String,
        userExamples: [String],
        steps: [ToolCompositionStep],
        note: String? = nil,
        readOnly: Bool
    ) {
        self.id = id
        self.goal = goal
        self.userExamples = userExamples
        self.steps = steps
        self.note = note
        self.readOnly = readOnly
    }

    public var referencedToolNames: [String] {
        var result: [String] = []
        var seen = Set<String>()
        for step in steps {
            let names: [String]
            switch step {
            case let .tool(name):
                names = [name]
            case let .oneOf(options):
                names = options
            case let .optional(name):
                names = [name]
            }
            for name in names where seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }
}

public enum ToolCompositionStep: Sendable, Hashable {
    case tool(String)
    case oneOf([String])
    case optional(String)
}

/// Canonical, registry-checked planning references for ordinary model use.
/// Tests verify every referenced name still exists as a model-visible tool.
public enum ToolCompositionExamples {
    public static let all: [ToolCompositionExample] = [
        ToolCompositionExample(
            id: "play_specific_song",
            goal: "找指定歌曲并播放",
            userExamples: ["播放稻香", "来一首周杰伦的七里香"],
            steps: [
                .oneOf(["library_search", "library_resolve_entity"]),
                .tool("playback_play_song"),
            ],
            note: "已有精确 TrackID 时直接播放，不重复搜索。",
            readOnly: false
        ),
        ToolCompositionExample(
            id: "appreciate_current_song",
            goal: "鉴赏当前歌曲",
            userExamples: ["鉴赏这首歌", "赏析这首歌"],
            steps: [
                .tool("music_appreciate"),
                .optional("lyrics_get"),
                .optional("music_get_public_evidence"),
            ],
            note: "music_appreciate 已有充分证据时，不强制调用其它工具。",
            readOnly: true
        ),
        ToolCompositionExample(
            id: "appreciate_specific_song",
            goal: "鉴赏指定歌曲",
            userExamples: ["鉴赏周杰伦的稻香", "分析这首歌的编曲"],
            steps: [
                .oneOf(["library_search", "library_resolve_entity"]),
                .tool("music_appreciate"),
                .optional("lyrics_get"),
                .optional("music_get_public_evidence"),
            ],
            note: "先获得真实 TrackID，再鉴赏。",
            readOnly: true
        ),
        ToolCompositionExample(
            id: "add_song_to_playlist",
            goal: "把歌曲加入已有歌单",
            userExamples: ["把稻香加到通勤歌单", "把这首歌加入跑步歌单"],
            steps: [
                .oneOf(["library_search", "library_resolve_entity"]),
                .oneOf(["playlist_list", "library_resolve_entity"]),
                .tool("playlist_add_songs"),
            ],
            note: "TrackID / PlaylistID 已知则跳过对应解析。",
            readOnly: false
        ),
        ToolCompositionExample(
            id: "create_playlist_from_selection",
            goal: "根据需求创建歌单",
            userExamples: ["给我建一个适合通勤的 20 首歌单"],
            steps: [
                .oneOf(["recommend_by_mood", "recommend_by_constraints", "library_select_tracks", "library_search"]),
                .tool("result_present_tracks"),
                .tool("playlist_create"),
                .tool("playlist_add_songs"),
            ],
            note: "最终曲目必须来自真实候选；不得编造 TrackID。",
            readOnly: false
        ),
        ToolCompositionExample(
            id: "recommend_and_play",
            goal: "推荐并立即播放",
            userExamples: ["找十首适合深夜听的然后播放"],
            steps: [
                .oneOf(["recommend_by_mood", "recommend_by_constraints", "library_select_tracks"]),
                .tool("result_present_tracks"),
                .tool("queue_replace"),
            ],
            note: "先得到真实 final selection，再修改队列。",
            readOnly: false
        ),
        ToolCompositionExample(
            id: "similar_from_current_song",
            goal: "从当前歌曲找相似歌曲",
            userExamples: ["找一些和这首歌类似的"],
            steps: [
                .oneOf(["playback_get_state", "app_get_context"]),
                .optional("library_get_song"),
                .tool("library_get_similar_songs"),
                .tool("result_present_tracks"),
            ],
            note: "需要当前歌曲 GlobalTrackID 时先读取真实上下文。",
            readOnly: true
        ),
        ToolCompositionExample(
            id: "favorite_or_rate_track",
            goal: "收藏或评分指定歌曲",
            userExamples: ["收藏稻香", "给稻香打 5 分"],
            steps: [
                .oneOf(["library_search", "library_resolve_entity"]),
                .oneOf(["favorite_set", "rating_set"]),
            ],
            note: "读取收藏/评分状态不调用修改工具；用户明确修改时直接调用相应工具。",
            readOnly: false
        ),
        ToolCompositionExample(
            id: "delete_playlist",
            goal: "删除歌单",
            userExamples: ["删除通勤歌单"],
            steps: [
                .oneOf(["playlist_list", "library_resolve_entity"]),
                .tool("playlist_delete"),
            ],
            note: "删除由 Runtime 做 destructive confirmation；模型不得自行确认或宣称删除成功。",
            readOnly: false
        ),
        ToolCompositionExample(
            id: "discover_unknown_capability",
            goal: "不知道工具名称时发现能力",
            userExamples: ["有没有办法做特殊音乐分析"],
            steps: [
                .tool("tool_search"),
            ],
            note: "Tool Directory 是认知地图；tool_search 是动态装载完整 schema 的正常机制。",
            readOnly: true
        ),
        ToolCompositionExample(
            id: "append_to_queue",
            goal: "把歌曲加入播放队列",
            userExamples: ["把稻香加入队列", "把这几首追加到播放列表后面"],
            steps: [
                .oneOf(["library_search", "library_resolve_entity"]),
                .oneOf(["queue_append", "queue_append_many"]),
            ],
            note: "多首任务优先使用 batch 版本。",
            readOnly: false
        ),
        ToolCompositionExample(
            id: "save_queue_as_playlist",
            goal: "把当前队列保存为歌单",
            userExamples: ["把当前队列保存成歌单", "把现在排队里的歌存成歌单"],
            steps: [
                .optional("queue_get"),
                .tool("queue_save_as_playlist"),
            ],
            note: "确认当前队列后再保存。",
            readOnly: false
        ),
        ToolCompositionExample(
            id: "download_track_or_album",
            goal: "搜索并下载音乐资源",
            userExamples: ["下载这张专辑", "帮我找无损资源下载"],
            steps: [
                .oneOf(["library_search", "library_resolve_entity"]),
                .tool("music_download_search"),
                .tool("music_download_submit"),
            ],
            note: "下载候选必须先来自 music_download_search，提交必须传回真实 ref/site_id/index。",
            readOnly: false
        ),
        ToolCompositionExample(
            id: "generate_smart_queue",
            goal: "生成智能队列预览",
            userExamples: ["给我生成一版智能队列"],
            steps: [
                .tool("smart_queue_generate"),
                .tool("result_present_tracks"),
                .tool("queue_replace"),
            ],
            note: "确认最终歌曲后再替换队列。",
            readOnly: false
        ),
    ]

    public static var readOnlyExamples: [ToolCompositionExample] {
        all.filter(\.readOnly)
    }

    public static func promptSection(examples: [ToolCompositionExample] = all) -> String {
        let intro = """
        ## 常见工具组合（规划参考）
        以下组合是典型规划参考，不是固定流程。已有必要事实/ID 时可以跳过解析步骤；
        也可以根据任务增加其他只读工具。不要为了匹配示例机械执行每一步。
        普通可逆操作按用户请求直接调用；只有工具 Registry 明确要求确认的操作才经过 Runtime 的可见确认。
        """
        let lines = examples.map { example -> String in
            var line = "- \(example.goal)：\(Self.render(steps: example.steps))"
            if let note = example.note {
                line += "。\(note)"
            }
            return line
        }
        return ([intro] + lines).joined(separator: "\n")
    }

    private static func render(steps: [ToolCompositionStep]) -> String {
        steps.map { step -> String in
            switch step {
            case let .tool(name):
                return name
            case let .oneOf(names):
                return names.joined(separator: " / ")
            case let .optional(name):
                return "必要时 \(name)"
            }
        }.joined(separator: " → ")
    }
}
