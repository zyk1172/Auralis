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
    public static func unsupportedReason(
        text: String,
        semantics: AgentRequestSemantics,
        descriptors: [ToolDescriptor]
    ) -> String? {
        // 1) 明确的「删除服务器曲库音乐文件」类请求：当前没有任何 canonical
        //    operation 覆盖服务器曲目删除，模型找不到就是找不到。
        if isMusicTrackFileDeletion(text) {
            let hasTrackDeleteCapability = descriptors.contains { descriptor in
                descriptor.permission != .readOnly
                    && descriptor.authorizationOperation.map {
                        $0 == .downloadHistoryRemove
                            || $0 == .downloadHistoryClean
                            || $0 == .serverRemove
                    } ?? false
            }
            // downloadHistoryRemove/serverRemove 是「下载历史/服务器账户」删除，
            // 不是曲库文件删除；因此这里恒不支持，直接 fail-fast。
            _ = hasTrackDeleteCapability
            return "当前 Auralis 没有删除音乐服务器曲库文件的受支持工具；可以删除歌单、下载历史、记忆或服务器账户，但不能直接删除服务器上的歌曲文件。"
        }

        // 2) 语义已经明确请求了某个 canonical operation，但注册表里一个
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
    private static func isMusicTrackFileDeletion(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let hasDeleteVerb = ["删除", "删掉", "移除", "清除", "清理", "抹除", "删去", "delete", "remove", "erase"]
            .contains(where: normalized.contains)
        guard hasDeleteVerb else { return false }
        // 只有明确的「文件/曲库/整库」级别目标才算 unsupported：
        // 裸「歌曲/歌」可能是队列/歌单操作（queue_remove / playlist_remove 存在）。
        let fileLevelTargets = ["歌曲文件", "音乐文件", "音频文件", "歌曲文件", "曲库", "音乐库",
                                "mp3", "flac", "所有歌曲", "全部歌曲", "全部的歌", "所有的歌",
                                "所有音乐", "全部音乐", "服务器上的歌"]
        if fileLevelTargets.contains(where: normalized.contains) {
            // 这些目标的删除有 canonical 能力，不算 unsupported。
            let supportedTargets = ["歌单", "下载历史", "记忆", "技能", "服务器账户", "服务器列表",
                                    "playlist", "download history", "memory", "skill"]
            let hitsSupportedTarget = supportedTargets.contains(where: normalized.contains)
            return !hitsSupportedTarget
        }
        // 「删除<艺人>的所有歌曲」：明确的整库文件删除意图。
        if normalized.range(of: #"删除.{0,12}?(?:所有|全部)(?:的)?(?:歌曲|歌|音乐)"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
