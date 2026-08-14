@testable import Application
import Foundation
import LocalCatalog
import Persistence
import SecurityKit
import Testing

@Test("生产运行时把同一个 LocalCatalogStore 注入 connector")
func runtimeCompositionSharesCatalogStoreIdentity() throws {
    let store = try LocalCatalogStore(url: URL(string: "file::memory:")!)
    let runtime = ApplicationComposition.makeRuntimeDependencies(
        catalogStore: store,
        catalogFallbackUsed: false,
        credentialVault: InMemoryCredentialVault(),
        persistence: InMemoryPersistence(),
        session: URLSession(configuration: .ephemeral)
    )
    let connector = try #require(runtime.connector as? ProductionServerConnector)

    #expect(runtime.catalogStore === store)
    #expect(connector.catalogStoreIdentity == ObjectIdentifier(store))
    #expect(runtime.catalogFallbackUsed == false)
}
