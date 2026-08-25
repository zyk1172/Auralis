import Foundation

/// 在普通 Agent 进入模型规划前，确定性地判断「当前注册表里是否真的存在
/// 支持该请求的 canonical capability」。
///
/// 目标：不支持的能力必须 fail-fast。“删除曲婉婷的所有歌曲”在没有「删除服务器
/// 曲库音乐文件」工具时，不能诱导模型无限 tool_search / 长期停留在“正在回复…”，
/// 而应明确返回“当前 Auralis 没有删除音乐服务器曲库文件的受支持工具”。
///
/// 判定完全基于注册表描述符与语义请求，不依赖模型输出、网页内容或授权猜测。
public enum AgentCapabilityCoverage {
    /// 返回 nil 表示支持；返回非 nil 时是面向用户的 fail-fast 说明。
    ///
    /// 判定顺序：semantics-first，keyword-second。
    /// 1) 语义已明确属于 queue / playlist 域且有对应 canonical operation →
    ///    supported（“清空队列里的所有歌曲 / 从播放队列移除所有歌曲 /
    ///    删除这个歌单里的所有歌曲”绝不能被误判成服务器曲库文件删除）；
    /// 2) 只有请求明确指向服务器曲库 / 音乐库实体文件 / 歌曲文件 / 音频文件 /
    ///    MP3/FLAC 文件，且注册表没有 canonical track-file delete capability 时
    ///    才 fail-fast；
    /// 3) 其它情况下，若语义请求的 canonical operation 在注册表里一个
    ///    descriptor 都没有 → 视为不存在的能力。
    public static func unsupportedReason(
        text: String,
        semantics: AgentRequestSemantics,
        descriptors: [ToolDescriptor]
    ) -> String? {
        // 1) semantics-first：queue / playlist 域有明确 mutation operation → supported。
        let queueOperations: Set<ToolAuthorizationOperation> = [
            .queueClear, .queueRemove, .queueReplace, .queueAppend,
            .queuePlayNext, .queueMove, .queueShuffle,
        ]
        let playlistOperations: Set<ToolAuthorizationOperation> = [
            .playlistRemove, .playlistDelete, .playlistAdd, .playlistCreate,
            .playlistMove, .playlistRename, .playlistDuplicate, .playlistMerge, .playlistSaveQueue,
        ]
        if semantics.domain == .queue,
           !semantics.requestedOperations.isDisjoint(with: queueOperations) {
            return nil
        }
        if semantics.domain == .playlist,
           !semantics.requestedOperations.isDisjoint(with: playlistOperations) {
            return nil
        }

        // 2) 明确的「删除服务器曲库音乐文件」类请求：当前没有任何 canonical
        //    operation 覆盖服务器曲目删除，模型找不到就是找不到。
        if isMusicTrackFileDeletion(text) {
            return "当前 Auralis 没有删除音乐服务器曲库文件的受支持工具；可以删除歌单、下载历史、记忆或服务器账户，但不能直接删除服务器上的歌曲文件。"
        }

        // 3) 语义已经明确请求了某个 canonical operation，但注册表里一个
        //    descriptor 都没有 → 说明请求的是一种不存在的能力。
        for operation in semantics.requestedOperations {
            let exists = descriptors.contains { descriptor in
                descriptor.authorizationOperation == operation
            }
            if !exists {
                return "当前 Auralis 没有支持此操作的受支持工具（\(operation.rawValue) 没有可用实现）。"
            }
        }

        return nil
    }

    /// 是否为「删除音乐文件」类请求（区别于删除歌单/下载历史/记忆/技能/服务器，
    /// 也区别于「移除歌曲」（队列/歌单有 canonical 工具））。
    ///
    /// 注意：这里只保留「文件/曲库/服务器实体」级别的强证据；“所有歌曲”本身
    /// 不是服务器文件删除证据（可能是队列清空 / 歌单移除，由 semantics-first 分支负责）。
    private static func isMusicTrackFileDeletion(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let hasDeleteVerb = ["删除", "删掉", "移除", "清除", "清理", "抹除", "删去", "delete", "remove", "erase"]
            .contains(where: normalized.contains)
        guard hasDeleteVerb else { return false }
        let fileLevelTargets = ["歌曲文件", "音乐文件", "音频文件", "曲库", "音乐库",
                                "服务器曲库", "服务器上的歌", "mp3", "flac"]
        if fileLevelTargets.contains(where: normalized.contains) {
            // 这些目标的删除有 canonical 能力，不算 unsupported。
            let supportedTargets = ["歌单", "下载历史", "记忆", "技能", "服务器账户", "服务器列表",
                                    "playlist", "download history", "memory", "skill"]
            let hitsSupportedTarget = supportedTargets.contains(where: normalized.contains)
            return !hitsSupportedTarget
        }
        // 「删除<艺人>的所有歌曲」：明确的整库文件删除意图（歌手维度删除整个曲库）。
        if normalized.range(of: #"删除.{0,12}?(?:所有|全部)(?:的)?(?:歌曲|歌|音乐|曲目)"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
