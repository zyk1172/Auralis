import Foundation
import OSLog

public enum AuralisLog {
    public static let subsystem = "com.auralis.player"
    public static let playback = Logger(subsystem: subsystem, category: "Playback")
    public static let library = Logger(subsystem: subsystem, category: "Library")
    public static let network = Logger(subsystem: subsystem, category: "Network")
    public static let artificialIntelligence = Logger(subsystem: subsystem, category: "AI")
}
