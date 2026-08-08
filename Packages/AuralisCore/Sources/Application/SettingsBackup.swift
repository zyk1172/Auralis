import CommonCrypto
import CryptoKit
import Domain
import Foundation

// MARK: - 备份内容模型

/// 设置备份内容：只包含配置（服务器 + 大模型接口 + 其他设置），
/// 刻意**不包含**歌曲、专辑、艺术家、歌单、收藏、播放记录、封面、歌词等音乐资料。
public struct SettingsBackup: Codable, Sendable {
    public var version: Int
    public var createdAt: Date
    public var servers: [BackupServer]
    public var ai: BackupAISettings
    public var preferences: [String: String]

    public static let currentVersion = 1

    public init(
        version: Int = SettingsBackup.currentVersion,
        createdAt: Date,
        servers: [BackupServer],
        ai: BackupAISettings,
        preferences: [String: String]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.servers = servers
        self.ai = ai
        self.preferences = preferences
    }
}

/// 单台服务器的账号信息 + 登录凭据。
/// `secret` 是明文密码 / Token——它只会存在于**已加密**的备份文件内部，绝不落盘明文。
public struct BackupServer: Codable, Sendable {
    public var account: ServerAccount
    public var secret: String?

    public init(account: ServerAccount, secret: String?) {
        self.account = account
        self.secret = secret
    }
}

/// OpenAI 兼容接口（大模型）配置。
public struct BackupAISettings: Codable, Sendable {
    public var baseURL: String
    public var apiPath: String
    public var model: String
    /// API Key 明文——只会存在于已加密的备份文件内部。
    public var apiKey: String?

    public init(baseURL: String, apiPath: String, model: String, apiKey: String?) {
        self.baseURL = baseURL
        self.apiPath = apiPath
        self.model = model
        self.apiKey = apiKey
    }
}

public enum SettingsBackupError: Error, LocalizedError, Equatable, Sendable {
    case emptyPassword
    case noServers
    case invalidFormat
    case unsupportedVersion(Int)
    case wrongPassword
    case encodingFailed
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            "请设置备份密码（至少 8 位）。"
        case .noServers:
            "还没有配置服务器，没有可备份的内容。"
        case .invalidFormat:
            "这不是有效的 Auralis 备份文件。"
        case let .unsupportedVersion(version):
            "备份文件版本（\(version)）不受支持，请升级 App 后重试。"
        case .wrongPassword:
            "备份密码不正确，或备份文件已损坏。"
        case .encodingFailed:
            "生成备份文件失败，请重试。"
        case .invalidData:
            "备份文件内容无法解析。"
        }
    }
}

// MARK: - 备份服务

/// 设置备份的加密 / 解密 / 设置白名单读写。
///
/// 加密使用 AES-GCM，密钥由用户密码经 PBKDF2-HMAC-SHA256（600,000 轮，带随机 salt）派生；
/// 旧版备份（v1）使用单次 HKDF-SHA256，解密时按文件版本自动选择派生方式；
/// 备份文件不含任何明文凭据（凭据只在已加密的 payload 内部）。
/// 无状态、可测试；UserDefaults 由调用方以参数传入。
public struct SettingsBackupService: Sendable {
    public init() {}

    // MARK: 加密 / 解密

    /// 文件布局：magic(4) + version(1) + salt(16) + AES.GCM.combined。
    public func encrypt(_ backup: SettingsBackup, password: String) throws -> Data {
        guard !password.isEmpty else { throw SettingsBackupError.emptyPassword }
        let payload = try JSONEncoder().encode(backup)
        let salt = Self.randomSalt()
        let key = Self.deriveKey(password: password, salt: salt, version: Self.versionByte)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw SettingsBackupError.encodingFailed }

        var data = Data()
        data.append(Self.magic)
        data.append(Self.versionByte)
        data.append(salt)
        data.append(combined)
        return data
    }

    public func decrypt(_ data: Data, password: String) throws -> SettingsBackup {
        guard !password.isEmpty else { throw SettingsBackupError.emptyPassword }
        var cursor = data.startIndex
        guard data.count >= Self.magic.count + 1 + Self.saltLength,
              data[data.startIndex ..< data.index(data.startIndex, offsetBy: Self.magic.count)] == Self.magic
        else {
            throw SettingsBackupError.invalidFormat
        }
        cursor = data.index(cursor, offsetBy: Self.magic.count)
        let version = data[cursor]
        cursor = data.index(after: cursor)
        // v1 = 单次 HKDF（旧版，兼容解密）；v2 = PBKDF2-HMAC-SHA256（当前）。
        guard version == 1 || version == Self.versionByte else {
            throw SettingsBackupError.unsupportedVersion(Int(version))
        }
        let salt = Data(data[cursor ..< data.index(cursor, offsetBy: Self.saltLength)])
        cursor = data.index(cursor, offsetBy: Self.saltLength)
        let combined = Data(data[cursor...])

        let key = Self.deriveKey(password: password, salt: salt, version: version)
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let payload = try AES.GCM.open(sealed, using: key)
            guard let backup = try? JSONDecoder().decode(SettingsBackup.self, from: payload) else {
                throw SettingsBackupError.invalidData
            }
            return backup
        } catch {
            // 密码错误或数据被篡改：AES-GCM 认证失败。
            throw SettingsBackupError.wrongPassword
        }
    }

    // MARK: - 设置白名单（仅这些非歌曲配置参与备份）

    private enum PreferenceValueKind: Sendable {
        case string
        case bool
    }

    private static let preferenceTypes: [String: PreferenceValueKind] = [
        "auralis.selected-theme": .string,
        "auralis.ai.enabled": .bool,
        "auralis.ai.allowsMetadata": .bool,
        "auralis.ai.allowsLyrics": .bool,
        "auralis.ai.allowsHistory": .bool,
        "auralis.audio.highQualityWiFi": .bool,
        "auralis.audio.cellularTranscoding": .bool,
        "auralis.ui.showMiniPlayer": .bool,
        "auralis.debug.crashLogEnabled": .bool,
    ]

    /// 读取白名单设置的当前值（统一 String 化，便于序列化）。
    public static func collectedPreferences(from defaults: UserDefaults) -> [String: String] {
        var result: [String: String] = [:]
        for (key, kind) in preferenceTypes {
            switch kind {
            case .string:
                if let value = defaults.string(forKey: key) { result[key] = value }
            case .bool:
                if defaults.object(forKey: key) != nil {
                    result[key] = defaults.bool(forKey: key) ? "true" : "false"
                }
            }
        }
        return result
    }

    /// 把备份中的白名单设置写回 UserDefaults。
    public static func writePreferences(_ preferences: [String: String], defaults: UserDefaults) {
        for (key, value) in preferences {
            guard let kind = preferenceTypes[key] else { continue }
            switch kind {
            case .string:
                defaults.set(value, forKey: key)
            case .bool:
                defaults.set(value == "true", forKey: key)
            }
        }
    }

    // MARK: - 密钥派生

    private static let magic = Data("AUBK".utf8)
    /// 当前备份格式版本：v2 起使用 PBKDF2-HMAC-SHA256（600,000 轮）派生密钥。
    /// v1（HKDF 单次派生）仍可解密，用于兼容旧备份。
    private static let versionByte: UInt8 = 2
    private static let saltLength = 16

    private static func randomSalt() -> Data {
        (0 ..< saltLength).reduce(into: Data()) { result, _ in
            result.append(UInt8.random(in: .min ... .max))
        }
    }

    /// PBKDF2-HMAC-SHA256 迭代轮数（OWASP 2023 对 SHA-256 的建议值）。
    /// 故意取高轮数以对抗离线暴力破解：备份文件含服务器密码与 AI API Key。
    private static let pbkdf2Rounds: UInt32 = 600_000

    private static func deriveKey(password: String, salt: Data, version: UInt8) -> SymmetricKey {
        switch version {
        case 1:
            // 旧版格式：单次 HKDF（弱于口令拉伸，仅保留用于解密历史备份）。
            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: Data(password.utf8)),
                salt: salt,
                info: Data("auralis.settings-backup.v1".utf8),
                outputByteCount: 32
            )
        default:
            return pbkdf2Key(password: password, salt: salt)
        }
    }

    private static func pbkdf2Key(password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        let keyLength = 32
        var derived = Data(count: keyLength)
        // 注意：闭包内不得再访问 derived.count（会对同一存储产生排他性冲突），
        // 长度用局部常量 keyLength。
        let status: Int32 = derived.withUnsafeMutableBytes { derivedBytes in
            guard let derivedBase = derivedBytes.baseAddress else { return Int32(-1) }
            return salt.withUnsafeBytes { saltBytes in
                guard let saltBase = saltBytes.baseAddress else { return Int32(-1) }
                return passwordData.withUnsafeBytes { passwordBytes in
                    guard let passwordBase = passwordBytes.baseAddress else { return Int32(-1) }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBase,
                        passwordData.count,
                        saltBase,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        Self.pbkdf2Rounds,
                        derivedBase,
                        keyLength
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 派生失败（状态 \(status)）")
        return SymmetricKey(data: derived)
    }
}
