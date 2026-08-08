import Foundation

public struct CredentialID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    var isValid: Bool {
        !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rawValue.contains("\0")
    }
}

public enum CredentialVaultError: Error, Equatable, Sendable {
    case missing
    case invalidReference
    case invalidData
    case unavailable
    case operationFailed(status: Int32)
}

extension CredentialVaultError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missing:
            "The requested credential was not found."
        case .invalidReference:
            "The credential reference is invalid."
        case .invalidData:
            "The stored credential data is invalid."
        case .unavailable:
            "Secure credential storage is currently unavailable."
        case let .operationFailed(status):
            "Secure credential storage failed with status \(status)."
        }
    }
}

public protocol CredentialVault: Sendable {
    func store(_ value: String, for id: CredentialID) async throws
    func retrieve(id: CredentialID) async throws -> String
    func delete(id: CredentialID) async throws
}

/// Test-only implementation. Production configuration uses
/// `KeychainCredentialVault`, never UserDefaults.
public actor InMemoryCredentialVault: CredentialVault {
    private var storage: [CredentialID: String] = [:]

    public init() {}

    public func store(_ value: String, for id: CredentialID) throws {
        guard id.isValid else { throw CredentialVaultError.invalidReference }
        storage[id] = value
    }

    public func retrieve(id: CredentialID) throws -> String {
        guard id.isValid else { throw CredentialVaultError.invalidReference }
        guard let value = storage[id] else { throw CredentialVaultError.missing }
        return value
    }

    public func delete(id: CredentialID) throws {
        guard id.isValid else { throw CredentialVaultError.invalidReference }
        storage.removeValue(forKey: id)
    }
}

public enum SecretRedactor {
    public static func sanitized(_ value: String) -> String {
        guard !value.isEmpty else { return "<empty>" }
        return "<redacted>"
    }

    /// Removes exact secret values from a diagnostic string before it reaches a
    /// logger or user-facing error surface. Empty values are deliberately ignored
    /// because replacing them would insert markers between every character.
    public static func redacting(_ secrets: [String], in diagnostic: String) -> String {
        let candidates = Set(secrets.filter { !$0.isEmpty })
            .sorted { $0.count > $1.count }

        return candidates.reduce(diagnostic) { partialResult, secret in
            partialResult.replacingOccurrences(of: secret, with: "<redacted>")
        }
    }
}
