import Domain
import Foundation

public struct ArtworkRequest: Hashable, Sendable {
    public let serverID: ServerID
    public let key: String
    public let targetPixelSize: Int
    public init(serverID: ServerID, key: String, targetPixelSize: Int) {
        self.serverID = serverID
        self.key = key
        self.targetPixelSize = targetPixelSize
    }
}

public protocol ArtworkLoading: Sendable {
    func data(for request: ArtworkRequest) async throws -> Data
    func removeCachedData(for request: ArtworkRequest) async
}
