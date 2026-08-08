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
            sourceFactory: { client in
                OpenSubsonicLibrarySyncSource(client: client)
            }
        )
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
