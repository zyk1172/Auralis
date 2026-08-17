import Foundation
import Security

/// Keychain-backed credential storage for server passwords, tokens, and AI API
/// keys. Values are stored as Generic Password items and never in UserDefaults.
public actor KeychainCredentialVault: CredentialVault {
    public static let defaultService = "com.auralis.player.credentials"

    private let service: String
    private let accessGroup: String?
    private let backend: any KeychainBackend

    /// Creates a production vault backed by the platform Security framework.
    ///
    /// Items use `afterFirstUnlockThisDeviceOnly`: background sync can continue
    /// after the user first unlocks the device, while credentials are excluded
    /// from backups and do not migrate to another device.
    public init(
        service: String = KeychainCredentialVault.defaultService,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        backend = SystemKeychainBackend()
    }

    init(
        service: String = KeychainCredentialVault.defaultService,
        accessGroup: String? = nil,
        backend: any KeychainBackend
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.backend = backend
    }

    public func store(_ value: String, for id: CredentialID) async throws {
        let query = try makeQuery(for: id)
        let data = Data(value.utf8)
        let updateStatus = backend.update(data, matching: query)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw Self.error(for: updateStatus)
        }

        let request = KeychainAddRequest(
            query: query,
            valueData: data,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        let addStatus = backend.add(request)

        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Another process may have inserted the item between our update and
            // add operations. Retrying the update makes store an atomic upsert
            // from the caller's perspective.
            let retryStatus = backend.update(data, matching: query)
            guard retryStatus == errSecSuccess else {
                throw Self.error(for: retryStatus)
            }
        default:
            throw Self.error(for: addStatus)
        }
    }

    public func retrieve(id: CredentialID) async throws -> String {
        let query = try makeQuery(for: id)
        let result = backend.read(matching: query)

        switch result {
        case let .success(data):
            guard let value = String(data: data, encoding: .utf8) else {
                throw CredentialVaultError.invalidData
            }
            return value
        case let .failure(status):
            throw Self.error(for: status)
        }
    }

    public func delete(id: CredentialID) async throws {
        let query = try makeQuery(for: id)
        let status = backend.delete(matching: query)

        // Deletion is intentionally idempotent, matching the in-memory vault.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status)
        }
    }

    private func makeQuery(for id: CredentialID) throws -> KeychainQuery {
        guard id.isValid,
              !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !service.contains("\0"),
              accessGroup?.contains("\0") != true
        else {
            throw CredentialVaultError.invalidReference
        }

        return KeychainQuery(service: service, account: id.rawValue, accessGroup: accessGroup)
    }

    private static func error(for status: OSStatus) -> CredentialVaultError {
        switch status {
        case errSecItemNotFound:
            .missing
        case errSecNotAvailable, errSecInteractionNotAllowed:
            .unavailable
        case errSecDecode:
            .invalidData
        default:
            .operationFailed(status: status)
        }
    }
}

// MARK: - Injectable Keychain boundary

enum KeychainItemAccessibility: Equatable, Sendable {
    case afterFirstUnlockThisDeviceOnly
}

struct KeychainQuery: Equatable, Sendable {
    let service: String
    let account: String
    let accessGroup: String?
}

struct KeychainAddRequest: Equatable, Sendable {
    let query: KeychainQuery
    let valueData: Data
    let accessibility: KeychainItemAccessibility
}

enum KeychainReadResult: Equatable, Sendable {
    case success(Data)
    case failure(OSStatus)
}

protocol KeychainBackend: Sendable {
    func update(_ data: Data, matching query: KeychainQuery) -> OSStatus
    func add(_ request: KeychainAddRequest) -> OSStatus
    func read(matching query: KeychainQuery) -> KeychainReadResult
    func delete(matching query: KeychainQuery) -> OSStatus
}

struct SystemKeychainBackend: KeychainBackend {
    func update(_ data: Data, matching query: KeychainQuery) -> OSStatus {
        SecItemUpdate(
            attributes(for: query) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
    }

    func add(_ request: KeychainAddRequest) -> OSStatus {
        var item = attributes(for: request.query)
        item[kSecValueData] = request.valueData
        item[kSecAttrAccessible] = accessibilityValue(for: request.accessibility)
        item[kSecAttrSynchronizable] = kCFBooleanFalse
        let status = SecItemAdd(item as CFDictionary, nil)
#if os(macOS)
        // 某些 macOS 版本 / 无解锁会话环境下，kSecAttrAccessible + kSecAttrSynchronizable
        // 组合会返回 errSecInteractionNotAllowed (-128)。分级降级：
        // 第一次：完整策略（accessible + synchronizable=false）；
        // 第二次：只移除同步标记，**保留 kSecAttrAccessible**（凭据保护策略不降级）；
        // 仍失败则原样返回状态，由上层映射为 .unavailable，绝不静默写入无保护项目。
        if status == errSecInteractionNotAllowed {
            var fallback = attributes(for: request.query)
            fallback[kSecValueData] = request.valueData
            fallback[kSecAttrAccessible] = accessibilityValue(for: request.accessibility)
            return SecItemAdd(fallback as CFDictionary, nil)
        }
#endif
        return status
    }

    func read(matching query: KeychainQuery) -> KeychainReadResult {
        var itemQuery = attributes(for: query)
        itemQuery[kSecReturnData] = kCFBooleanTrue
        itemQuery[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(itemQuery as CFDictionary, &result)
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = result as? Data else { return .failure(errSecDecode) }
        return .success(data)
    }

    func delete(matching query: KeychainQuery) -> OSStatus {
        SecItemDelete(attributes(for: query) as CFDictionary)
    }

    private func attributes(for query: KeychainQuery) -> [CFString: Any] {
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: query.service,
            kSecAttrAccount: query.account,
        ]
        if let accessGroup = query.accessGroup, !accessGroup.isEmpty {
            attributes[kSecAttrAccessGroup] = accessGroup
        }
        return attributes
    }

    private func accessibilityValue(for accessibility: KeychainItemAccessibility) -> CFString {
        switch accessibility {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}
