// SPDX-License-Identifier: GPL-3.0-only
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// IP 地址的最小、可跨平台表示，用于在连接前检查 DNS 结果。
public enum SafeWebIPAddress: Hashable, Sendable {
    case ipv4([UInt8])
    case ipv6([UInt8])
}

/// Web 能力共用的 URL / DNS 安全边界。
///
/// 这层只负责“目标地址是否可被 Web capability 访问”，不负责 HTML 解析或
/// Provider 协议。调用方必须在初始 URL、每一个 redirect hop 和最终 URL 上调用它。
public struct SafeWebURLPolicy: Sendable {
    public typealias HostResolver = @Sendable (String) throws -> [SafeWebIPAddress]

    public let maxRedirects: Int
    private let resolver: HostResolver

    public init(
        maxRedirects: Int = 5,
        resolver: @escaping HostResolver = SafeWebURLPolicy.resolveSystemHost
    ) {
        self.maxRedirects = max(0, maxRedirects)
        self.resolver = resolver
    }

    public func validateInitialURL(_ url: URL) async throws {
        try await validate(url)
    }

    public func validateResolvedHost(_ host: String) async throws {
        try validateHost(host)
    }

    public func validateRedirect(from: URL, to: URL) async throws {
        // The caller resolves Location against the current URL before reaching
        // this method. Refuse a still-relative target rather than guessing.
        guard to.baseURL == nil else { throw WebCapabilityError.invalidURL }
        try await validate(from)
        try await validate(to)
    }

    public func validateFinalURL(_ url: URL) async throws {
        try await validate(url)
    }

    private func validate(_ url: URL) async throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host,
              !host.isEmpty else {
            throw WebCapabilityError.invalidURL
        }
        try validateHost(host)
    }

    private func validateHost(_ rawHost: String) throws {
        let host = Self.normalizedHost(rawHost)
        guard !host.isEmpty else { throw WebCapabilityError.invalidURL }
        guard host != "localhost", !host.hasSuffix(".local") else {
            throw WebCapabilityError.privateAddress
        }

        if let address = Self.parseLiteralAddress(host) {
            guard !Self.isBlocked(address) else { throw WebCapabilityError.privateAddress }
            return
        }

        let addresses: [SafeWebIPAddress]
        do {
            addresses = try resolver(host)
        } catch {
            throw WebCapabilityError.dnsResolutionFailed
        }
        guard !addresses.isEmpty else { throw WebCapabilityError.dnsResolutionFailed }
        guard addresses.allSatisfy({ !Self.isBlocked($0) }) else {
            throw WebCapabilityError.privateAddress
        }
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func parseLiteralAddress(_ host: String) -> SafeWebIPAddress? {
        #if canImport(Darwin) || canImport(Glibc)
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return .ipv4(Array(withUnsafeBytes(of: v4.s_addr) { $0 }))
        }

        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return .ipv6(Array(withUnsafeBytes(of: v6.__u6_addr.__u6_addr8) { $0 }))
        }
        #endif
        return nil
    }

    private static func isBlocked(_ address: SafeWebIPAddress) -> Bool {
        switch address {
        case let .ipv4(bytes):
            guard bytes.count == 4 else { return true }
            let first = bytes[0]
            let second = bytes[1]
            // 0/8, 10/8, 127/8, 224/4 and 240/4.
            if first == 0 || first == 10 || first == 127 || first >= 224 { return true }
            // 100.64/10 (carrier-grade NAT).
            if first == 100, (second & 0xc0) == 0x40 { return true }
            // 169.254/16 (link-local / cloud metadata aliases).
            if first == 169, second == 254 { return true }
            // 172.16/12.
            if first == 172, (16...31).contains(second) { return true }
            // 192.168/16.
            if first == 192, second == 168 { return true }
            return false

        case let .ipv6(bytes):
            guard bytes.count == 16 else { return true }
            if bytes.allSatisfy({ $0 == 0 }) { return true } // ::
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true } // ::1
            if (bytes[0] & 0xfe) == 0xfc { return true } // fc00::/7
            if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return true } // fe80::/10
            if bytes[0] == 0xff { return true } // ff00::/8

            // ::ffff:a.b.c.d must inherit the IPv4 policy.
            let mappedPrefix = bytes.prefix(10).allSatisfy({ $0 == 0 })
                && bytes[10] == 0xff && bytes[11] == 0xff
            if mappedPrefix {
                return isBlocked(.ipv4(Array(bytes[12..<16])))
            }
            return false
        }
    }

    /// Resolve every A / AAAA result. A hostname is safe only if all returned
    /// addresses are public; accepting one public address beside one private
    /// address would make DNS rebinding / round-robin SSRF possible.
    public static func resolveSystemHost(_ host: String) throws -> [SafeWebIPAddress] {
        #if canImport(Darwin) || canImport(Glibc)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { getaddrinfo($0, nil, &hints, &result) }
        guard status == 0, let result else { throw WebCapabilityError.dnsResolutionFailed }
        defer { freeaddrinfo(result) }

        var addresses: [SafeWebIPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let item = cursor {
            guard let address = item.pointee.ai_addr else {
                cursor = item.pointee.ai_next
                continue
            }
            let family = Int32(address.pointee.sa_family)
            if family == AF_INET {
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    Array(withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { $0 })
                }
                addresses.append(.ipv4(bytes))
            } else if family == AF_INET6 {
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    Array(withUnsafeBytes(of: $0.pointee.sin6_addr.__u6_addr.__u6_addr8) { $0 })
                }
                addresses.append(.ipv6(bytes))
            }
            cursor = item.pointee.ai_next
        }
        return addresses
        #else
        throw WebCapabilityError.dnsResolutionFailed
        #endif
    }
}
