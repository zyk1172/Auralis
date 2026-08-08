@testable import SecurityKit
import Foundation
import Security
import Testing

@Test("Keychain vault updates an existing item without adding a duplicate")
func updatesExistingCredential() async throws {
    let backend = RecordingKeychainBackend(
        updateStatuses: [errSecSuccess]
    )
    let vault = KeychainCredentialVault(service: "test.auralis.credentials", backend: backend)
    let id = CredentialID(rawValue: "provider.primary")

    try await vault.store("synthetic-test-value", for: id)

    let snapshot = backend.snapshot()
    #expect(snapshot.operations == [.update])
    #expect(snapshot.lastQuery?.service == "test.auralis.credentials")
    #expect(snapshot.lastQuery?.account == id.rawValue)
}

@Test("Keychain vault adds a missing item with device-only background-safe accessibility")
func addsMissingCredential() async throws {
    let backend = RecordingKeychainBackend(
        updateStatuses: [errSecItemNotFound],
        addStatuses: [errSecSuccess]
    )
    let vault = KeychainCredentialVault(backend: backend)

    try await vault.store("synthetic-test-value", for: CredentialID(rawValue: "server.primary"))

    let snapshot = backend.snapshot()
    #expect(snapshot.operations == [.update, .add])
    #expect(snapshot.lastAddRequest?.accessibility == .afterFirstUnlockThisDeviceOnly)
}

@Test("Keychain vault retries update if a concurrent add creates a duplicate")
func retriesAfterDuplicateAdd() async throws {
    let backend = RecordingKeychainBackend(
        updateStatuses: [errSecItemNotFound, errSecSuccess],
        addStatuses: [errSecDuplicateItem]
    )
    let vault = KeychainCredentialVault(backend: backend)

    try await vault.store("synthetic-test-value", for: CredentialID(rawValue: "server.concurrent"))

    #expect(backend.snapshot().operations == [.update, .add, .update])
}

@Test("Keychain vault retrieves UTF-8 data and maps a missing item")
func retrievesAndMapsMissingCredential() async throws {
    let backend = RecordingKeychainBackend(
        readResults: [
            .success(Data("synthetic-test-value".utf8)),
            .failure(errSecItemNotFound),
        ]
    )
    let vault = KeychainCredentialVault(backend: backend)
    let id = CredentialID(rawValue: "ai.primary")

    #expect(try await vault.retrieve(id: id) == "synthetic-test-value")
    await #expect(throws: CredentialVaultError.missing) {
        try await vault.retrieve(id: id)
    }
}

@Test("Keychain delete is idempotent")
func deleteIsIdempotent() async throws {
    let backend = RecordingKeychainBackend(
        deleteStatuses: [errSecSuccess, errSecItemNotFound]
    )
    let vault = KeychainCredentialVault(backend: backend)
    let id = CredentialID(rawValue: "server.removed")

    try await vault.delete(id: id)
    try await vault.delete(id: id)

    #expect(backend.snapshot().operations == [.delete, .delete])
}

@Test("Vault rejects blank references before touching secure storage")
func rejectsBlankReferences() async {
    let backend = RecordingKeychainBackend()
    let vault = KeychainCredentialVault(backend: backend)

    await #expect(throws: CredentialVaultError.invalidReference) {
        try await vault.store("synthetic-test-value", for: CredentialID(rawValue: "  \n"))
    }
    #expect(backend.snapshot().operations.isEmpty)
}

@Test("Keychain failures never include credential contents")
func failuresDoNotExposeCredentialContents() async {
    let backend = RecordingKeychainBackend(updateStatuses: [errSecAuthFailed])
    let vault = KeychainCredentialVault(backend: backend)
    let value = "synthetic-private-value"

    do {
        try await vault.store(value, for: CredentialID(rawValue: "server.failure"))
        Issue.record("Expected secure storage to reject the operation")
    } catch {
        #expect(!error.localizedDescription.contains(value))
        #expect(String(reflecting: error) != value)
    }
}

@Test("Secret redaction does not expose contents or length")
func redactsSecrets() {
    let firstSecret = "synthetic-private-value"
    let secondSecret = "another-private-value"
    let diagnostic = "Authorization: \(firstSecret); fallback=\(secondSecret)"
    let output = SecretRedactor.redacting([firstSecret, secondSecret], in: diagnostic)

    #expect(SecretRedactor.sanitized(firstSecret) == "<redacted>")
    #expect(!output.contains(firstSecret))
    #expect(!output.contains(secondSecret))
    #expect(output == "Authorization: <redacted>; fallback=<redacted>")
    #expect(SecretRedactor.sanitized("") == "<empty>")
}

@Test("Keychain 凭据按 account 隔离，跨服务器不会串读")
func credentialsAreIsolatedAcrossServers() async throws {
    let backend = RecordingKeychainBackend(readResults: [
        .success(Data("secret-for-server-a".utf8)),
        .failure(errSecItemNotFound),
        .success(Data("secret-for-server-b".utf8)),
    ])
    let vault = KeychainCredentialVault(backend: backend)

    try await vault.store("secret-for-server-a", for: CredentialID(rawValue: "server.a"))
    try await vault.store("secret-for-server-b", for: CredentialID(rawValue: "server.b"))

    let readA = try await vault.retrieve(id: CredentialID(rawValue: "server.a"))
    #expect(readA == "secret-for-server-a")
    // 读取不存在的 account 必须找不到，且绝不能泄露 server.a 的凭据。
    await #expect(throws: CredentialVaultError.missing) {
        try await vault.retrieve(id: CredentialID(rawValue: "server.c"))
    }
    let readB = try await vault.retrieve(id: CredentialID(rawValue: "server.b"))
    #expect(readB == "secret-for-server-b")
    #expect(readA != readB)

    // 每次读取都绑定到各自的 account，证明存储按 account 维度分区。
    let accounts = backend.recordedQueries().map(\.account)
    #expect(accounts.contains("server.a"))
    #expect(accounts.contains("server.b"))
    #expect(accounts.contains("server.c"))
}

@Test("Keychain 删除单台服务器凭据不影响其他服务器")
func deletionIsScopedToSingleServer() async throws {
    // 三次读取分别命中 server.a、server.b、以及删除后的 server.b。
    let backend = RecordingKeychainBackend(readResults: [
        .success(Data("secret-for-server-a".utf8)),
        .success(Data("secret-for-server-b".utf8)),
        .success(Data("secret-for-server-b".utf8)),
    ])
    let vault = KeychainCredentialVault(backend: backend)

    try await vault.store("secret-for-server-a", for: CredentialID(rawValue: "server.a"))
    try await vault.store("secret-for-server-b", for: CredentialID(rawValue: "server.b"))

    // 读取各自独立、互不串读。
    #expect(try await vault.retrieve(id: CredentialID(rawValue: "server.a")) == "secret-for-server-a")
    #expect(try await vault.retrieve(id: CredentialID(rawValue: "server.b")) == "secret-for-server-b")

    try await vault.delete(id: CredentialID(rawValue: "server.a"))

    // 全量操作中只有一个 .delete，且唯一命中 server.a，证明删除未波及 server.b。
    #expect(backend.snapshot().operations.filter { $0 == .delete }.count == 1)
    #expect(backend.recordedQueries().last?.account == "server.a")

    // 删除后 server.b 仍可正常读取，确未被删除操作波及。
    #expect(try await vault.retrieve(id: CredentialID(rawValue: "server.b")) == "secret-for-server-b")
}

private final class RecordingKeychainBackend: KeychainBackend, @unchecked Sendable {
    enum Operation: Equatable, Sendable {
        case update
        case add
        case read
        case delete
    }

    struct Snapshot: Sendable {
        let operations: [Operation]
        let lastQuery: KeychainQuery?
        let lastAddRequest: KeychainAddRequest?
    }

    private let lock = NSLock()
    private var updateStatuses: [OSStatus]
    private var addStatuses: [OSStatus]
    private var readResults: [KeychainReadResult]
    private var deleteStatuses: [OSStatus]
    private var operations: [Operation] = []
    private var lastQuery: KeychainQuery?
    private var lastAddRequest: KeychainAddRequest?
    private var allQueries: [KeychainQuery] = []

    init(
        updateStatuses: [OSStatus] = [],
        addStatuses: [OSStatus] = [],
        readResults: [KeychainReadResult] = [],
        deleteStatuses: [OSStatus] = []
    ) {
        self.updateStatuses = updateStatuses
        self.addStatuses = addStatuses
        self.readResults = readResults
        self.deleteStatuses = deleteStatuses
    }

    func update(_ data: Data, matching query: KeychainQuery) -> OSStatus {
        withLock {
            operations.append(.update)
            lastQuery = query
            allQueries.append(query)
            return updateStatuses.isEmpty ? errSecSuccess : updateStatuses.removeFirst()
        }
    }

    func add(_ request: KeychainAddRequest) -> OSStatus {
        withLock {
            operations.append(.add)
            lastQuery = request.query
            allQueries.append(request.query)
            lastAddRequest = request
            return addStatuses.isEmpty ? errSecSuccess : addStatuses.removeFirst()
        }
    }

    func read(matching query: KeychainQuery) -> KeychainReadResult {
        withLock {
            operations.append(.read)
            lastQuery = query
            allQueries.append(query)
            return readResults.isEmpty ? .failure(errSecItemNotFound) : readResults.removeFirst()
        }
    }

    func delete(matching query: KeychainQuery) -> OSStatus {
        withLock {
            operations.append(.delete)
            lastQuery = query
            allQueries.append(query)
            return deleteStatuses.isEmpty ? errSecSuccess : deleteStatuses.removeFirst()
        }
    }

    func snapshot() -> Snapshot {
        withLock {
            Snapshot(
                operations: operations,
                lastQuery: lastQuery,
                lastAddRequest: lastAddRequest
            )
        }
    }

    /// 全部读写删操作的查询，用于断言按 account 级别隔离。
    func recordedQueries() -> [KeychainQuery] {
        withLock { allQueries }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
