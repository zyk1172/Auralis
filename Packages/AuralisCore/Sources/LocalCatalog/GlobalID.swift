import Domain
import Foundation

/// 所有远程对象的本地组合标识：serverID + remoteID。
/// 字符串形式 "serverID:remoteID"，保证多服务器数据互不串扰。
public struct GlobalID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let serverID: ServerID
    public let remoteID: String

    public init(serverID: ServerID, remoteID: String) {
        self.serverID = serverID
        self.remoteID = remoteID
    }

    /// 从字符串形式解析；格式非法时返回 nil。
    public init?(_ string: String) {
        guard let separator = string.firstIndex(of: ":") else { return nil }
        let server = String(string[string.startIndex..<separator])
        let remote = String(string[string.index(after: separator)...])
        guard !server.isEmpty, !remote.isEmpty else { return nil }
        self.serverID = ServerID(rawValue: server)
        self.remoteID = remote
    }

    public var description: String { "\(serverID.rawValue):\(remoteID)" }
}

public enum LocalCatalogError: Error, Equatable, Sendable {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
}
