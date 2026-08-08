import Domain
import Foundation

public struct PlaybackChainSnapshot: Hashable, Sendable {
    public var sourceFile: String
    public var server: String
    public var clientDecode: String
    public var outputRoute: String
    public var replayGain: String

    public init(sourceFile: String? = nil, server: String? = nil, clientDecode: String? = nil, outputRoute: String? = nil, replayGain: String? = nil) {
        self.sourceFile = sourceFile ?? "未知"
        self.server = server ?? "未知"
        self.clientDecode = clientDecode ?? "未知"
        self.outputRoute = outputRoute ?? "未知"
        self.replayGain = replayGain ?? "未知"
    }
}
