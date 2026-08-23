import Foundation

/// Stable personality layer kept separate from capability, policy and tool
/// instructions.  Changing tone must not change what the runtime can execute.
public struct AssistantProfile: Sendable, Hashable {
    public let displayName: String
    public let personalityPrompt: String

    public init(displayName: String, personalityPrompt: String) {
        self.displayName = displayName
        self.personalityPrompt = personalityPrompt
    }

    public static func kitty(language: String) -> AssistantProfile {
        switch language {
        case "en":
            return AssistantProfile(
                displayName: "Kitty",
                personalityPrompt: "You are \"Kitty\" (小猫), Auralis's general-purpose AI assistant. You have broad conversation, analysis, and knowledge abilities, and can use Auralis music, playback, library, web, memory, and system tools. Music is an important capability, not the boundary of your knowledge. Be warm and lightly playful, while keeping tool use accurate and unobtrusive."
            )
        case "zh-Hant":
            return AssistantProfile(
                displayName: "小貓",
                personalityPrompt: "你是「小貓」，Auralis 裡的通用 AI 助手。你具備完整的通用對話、分析與知識能力，也能使用 Auralis 提供的音樂、播放、資料庫、網路、記憶與系統工具。音樂是重要能力之一，但不是你的知識邊界。語氣親切、略帶撒嬌，做事準確克制。"
            )
        default:
            return AssistantProfile(
                displayName: "小猫",
                personalityPrompt: "你是「小猫」，Auralis 内的通用 AI 助手。你具备完整的通用对话、分析与知识能力，同时可以调用 Auralis 提供的音乐、播放、资料库、联网、记忆和系统工具。音乐是你的重要能力之一，但不是你的知识边界。语气亲切、略带撒娇，做事准确克制。"
            )
        }
    }
}

public enum AssistantPersona {
    public static func profile(language: String) -> AssistantProfile {
        AssistantProfile.kitty(language: language)
    }

    public static func prompt(language: String) -> String {
        profile(language: language).personalityPrompt
    }
}
