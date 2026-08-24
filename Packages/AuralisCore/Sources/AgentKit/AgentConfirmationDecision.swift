import Foundation

/// A deliberately small language boundary for Runtime confirmations.
///
/// This is only used when a Runtime descriptor has explicitly requested a
/// confirmation.  It must never be used to turn an arbitrary model sentence
/// into authorization for a side effect.
public enum AgentConfirmationDecision: String, Codable, Sendable, Equatable {
    case confirm
    case reject
    case unknown

    public static func parse(_ text: String) -> Self {
        let normalized = normalize(text)
        if confirmPhrases.contains(normalized) { return .confirm }
        if rejectPhrases.contains(normalized) { return .reject }
        return .unknown
    }

    public static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？!?、；;：: \t\n\"'“”‘’"))
    }

    private static let confirmPhrases: Set<String> = [
        "确认", "确定", "可以", "执行", "继续", "好", "好的", "是",
        "yes", "ok", "okay", "approve", "approved",
    ]

    private static let rejectPhrases: Set<String> = [
        "取消", "拒绝", "不", "不要", "算了", "否",
        "no", "cancel", "reject", "rejected",
    ]
}
