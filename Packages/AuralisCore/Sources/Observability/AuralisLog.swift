import Foundation
import OSLog

public enum AuralisLog {
    public static let subsystem = "com.auralis.player"
    public static let playback = Logger(subsystem: subsystem, category: "Playback")
    public static let library = Logger(subsystem: subsystem, category: "Library")
    public static let network = Logger(subsystem: subsystem, category: "Network")
    public static let artificialIntelligence = Logger(subsystem: subsystem, category: "AI")

    public static func measure<T: Sendable>(
        _ name: StaticString,
        category: OSSignpostID = .exclusive,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        _ = name
        _ = category
        return try await operation()
    }
}
