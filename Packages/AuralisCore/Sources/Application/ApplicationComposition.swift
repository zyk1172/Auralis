import Domain
import Foundation
import LocalCatalog
import Observability
import Persistence
import SecurityKit

/// 生产运行时的唯一目录依赖。Connector、CatalogCoordinator、Agent、搜索与补全服务
/// 都从这里拿同一个 actor，避免同一进程重复打开 catalog.sqlite 或 fallback split-brain。
public struct ApplicationRuntimeDependencies: Sendable {
    public let catalogStore: LocalCatalogStore
    public let connector: any ServerConnecting
    public let catalogFallbackUsed: Bool

    public init(
        catalogStore: LocalCatalogStore,
        connector: any ServerConnecting,
        catalogFallbackUsed: Bool
    ) {
        self.catalogStore = catalogStore
        self.connector = connector
        self.catalogFallbackUsed = catalogFallbackUsed
    }
}

public enum ApplicationComposition {
    /// 兼容旧调用点；新的生产 AppModel 使用 `makeRuntimeDependencies()`，同时保存
    /// connector 与共享 catalogStore。
    public static func makeServerConnector() -> any ServerConnecting {
        makeRuntimeDependencies().connector
    }

    /// The sole production composition root. Store fallback is decided exactly once here,
    /// then the same actor is injected into every catalog consumer.
    public static func makeRuntimeDependencies(
        catalogStoreURL: URL? = nil
    ) -> ApplicationRuntimeDependencies {
        let opened = makeCatalogStore(url: catalogStoreURL ?? LocalCatalogStore.defaultStoreURL())
        return makeRuntimeDependencies(
            catalogStore: opened.store,
            catalogFallbackUsed: opened.fallbackUsed
        )
    }

    /// 注入已创建的 store（测试与扩展 composition 使用），不会再次打开或 fallback。
    public static func makeRuntimeDependencies(
        catalogStore: LocalCatalogStore,
        catalogFallbackUsed: Bool = false
    ) -> ApplicationRuntimeDependencies {
        makeRuntimeDependencies(
            catalogStore: catalogStore,
            catalogFallbackUsed: catalogFallbackUsed,
            credentialVault: KeychainCredentialVault(),
            persistence: makePersistence(),
            session: serverURLSession()
        )
    }

    /// 可注入版本供 composition identity 测试使用，避免测试读取真实 library.json/Keychain。
    static func makeRuntimeDependencies(
        catalogStore: LocalCatalogStore,
        catalogFallbackUsed: Bool,
        credentialVault: any CredentialVault,
        persistence: any AuralisPersisting,
        session: URLSession
    ) -> ApplicationRuntimeDependencies {
        let connector = ProductionServerConnector(
            credentialVault: credentialVault,
            persistence: persistence,
            catalogStore: catalogStore,
            session: session,
            sourceFactory: { client in
                OpenSubsonicLibrarySyncSource(client: client)
            }
        )
        return ApplicationRuntimeDependencies(
            catalogStore: catalogStore,
            connector: connector,
            catalogFallbackUsed: catalogFallbackUsed
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
        let url = libraryStoreURL()
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        if let store = try? StartupPerformanceTrace.measure(
            .persistenceInit,
            metadata: .init(fileBytes: bytes),
            operation: { try FileBackedPersistence(fileURL: url) }
        ) {
            return store
        }
        return InMemoryPersistence()
    }

    private static func makeCatalogStore(url: URL) -> (store: LocalCatalogStore, fallbackUsed: Bool) {
        let startedAt = ContinuousClock.now
        if let store = try? LocalCatalogStore(url: url) {
            StartupPerformanceTrace.record(
                .catalogStoreOpenConnector,
                since: startedAt,
                metadata: .init(fallbackUsed: false)
            )
            return (store, false)
        }
        // 兜底 1：临时目录文件库（避免相对路径 ":memory:" 在不可写 cwd 下 `try!` 崩溃）。
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-catalog-\(UUID().uuidString).sqlite")
        if let store = try? LocalCatalogStore(url: fallback) {
            AuralisLog.library.error("catalogFallbackUsed=true kind=temporary")
            StartupPerformanceTrace.record(
                .catalogStoreOpenConnector,
                since: startedAt,
                metadata: .init(fallbackUsed: true)
            )
            return (store, true)
        }
        // 兜底 2：真内存库（URL(path == ":memory:")）。内存库打开几乎不会失败；
        // 万一失败再试一个独立临时文件，仍失败才显式记录 fault（此时 SQLite 不可用）。
        if let store = try? LocalCatalogStore(url: URL(string: "file::memory:")!) {
            AuralisLog.library.error("catalogFallbackUsed=true kind=memory")
            StartupPerformanceTrace.record(
                .catalogStoreOpenConnector,
                since: startedAt,
                metadata: .init(fallbackUsed: true)
            )
            return (store, true)
        }
        let secondChance = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-catalog-\(UUID().uuidString).sqlite")
        if let store = try? LocalCatalogStore(url: secondChance) {
            AuralisLog.library.error("catalogFallbackUsed=true kind=temporary-second")
            StartupPerformanceTrace.record(
                .catalogStoreOpenConnector,
                since: startedAt,
                metadata: .init(fallbackUsed: true)
            )
            return (store, true)
        }
        AuralisLog.library.fault("catalogStoreOpenFailed: 临时目录与内存库均无法创建本地目录存储")
        preconditionFailure("无法初始化本地目录存储")
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
