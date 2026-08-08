import Domain
import Foundation
import Persistence
import SecurityKit

public enum ApplicationComposition {
    /// The composition entry point is kept in the application layer so AppShell
    /// never constructs URLSession, Keychain, or persistence implementations.
    public static func makeServerConnector() -> any ServerConnecting {
        ProductionServerConnector(
            credentialVault: KeychainCredentialVault(),
            persistence: makePersistence(),
            session: serverURLSession(),
            sourceFactory: { client in
                OpenSubsonicLibrarySyncSource(client: client)
            }
        )
    }

    /// 服务器连接使用的 URLSession：启用 `waitsForConnectivity`。
    ///
    /// 背景：macOS「本地网络」授权弹窗弹出期间，网络路径处于 unsatisfied（尚未被用户
    /// 允许）状态；若 `waitsForConnectivity = false`（`URLSession.shared` 的默认行为），
    /// 第一次请求会立刻以 NSURLError -1009 失败，而不是等用户处理授权。
    /// 这里开启等待 + 有界资源超时，避免无限挂起：
    /// - 用户允许授权后，同一请求自动继续（等效一次自动重试）；
    /// - 用户一直不处理，60 秒后按超时结束，不会无限等待。
    /// 仅改动传输层配置，不涉及 OpenSubsonic 请求/响应逻辑。
    public static func serverURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }

    /// 资料库存储在 Application Support/Auralis/library.json。
    /// 磁盘不可用（如沙箱限制）时退化为内存存储：连接流程仍然可用，
    /// 只是重启后需要重新同步资料库。
    private static func makePersistence() -> any AuralisPersisting {
        if let store = try? FileBackedPersistence(fileURL: libraryStoreURL()) {
            return store
        }
        return InMemoryPersistence()
    }

    private static func libraryStoreURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let directory = base.appendingPathComponent("Auralis", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library.json")
    }
}
