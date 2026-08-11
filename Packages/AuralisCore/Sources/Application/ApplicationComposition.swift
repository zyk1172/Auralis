import Domain
import Foundation
import LocalCatalog
import Persistence
import SecurityKit

public enum ApplicationComposition {
    /// The composition entry point is kept in the application layer so AppShell
    /// never constructs URLSession, Keychain, or persistence implementations.
    public static func makeServerConnector() -> any ServerConnecting {
        let catalogStore = makeCatalogStore()
        return ProductionServerConnector(
            credentialVault: KeychainCredentialVault(),
            persistence: makePersistence(),
            catalogStore: catalogStore,
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

    /// `library.json` now stores only accounts and lightweight migration state.
    /// Music entities live exclusively in LocalCatalog SQLite.
    private static func makePersistence() -> any AuralisPersisting {
        if let store = try? FileBackedPersistence(fileURL: libraryStoreURL()) {
            return store
        }
        return InMemoryPersistence()
    }

    private static func makeCatalogStore() -> LocalCatalogStore {
        if let store = try? LocalCatalogStore(url: LocalCatalogStore.defaultStoreURL()) {
            return store
        }
        return try! LocalCatalogStore(url: URL(fileURLWithPath: ":memory:"))
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
