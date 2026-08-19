import Foundation

/// 统一的主机私网/本机分类器：供 ServerURLPolicy、OpenSubsonicKit 错误提示等共用，
/// 避免「同一套 IPv4 判断复制两份且都缺 IPv6」。
///
/// 覆盖：
/// - IPv4 私网（10/8、172.16/12、192.168/16、169.254/16 link-local、127/8 loopback）
/// - IPv6 loopback `::1`、ULA `fc00::/7`、link-local `fe80::/10`、IPv4-mapped IPv6（`::ffff:a.b.c.d`）
/// - zone identifier（`fe80::1%en0`）
/// - 主机名 `localhost` / `.local`
public enum NetworkHostClassifier {
    /// 主机是否属于私网 / 本机。`host` 可为 IP 或主机名。
    public static func isPrivateOrLocal(host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized.hasSuffix(".local") { return true }

        // 剥离 IPv6 zone identifier：fe80::1%en0 → fe80::1
        let withoutZone = normalized.split(separator: "%", maxSplits: 1).first.map(String.init) ?? normalized

        // IPv4-mapped IPv6：::ffff:192.168.1.5 → 按 IPv4 判断
        if withoutZone.hasPrefix("::ffff:") {
            return isPrivateIPv4(String(withoutZone.dropFirst(7)))
        }

        if withoutZone.contains(":") {
            guard isValidIPv6(withoutZone) else { return false }
            if withoutZone == "::1" { return true }
            // fc00::/7（ULA：fc00–fdff）
            if withoutZone.hasPrefix("fc") || withoutZone.hasPrefix("fd") { return true }
            // fe80::/10（link-local：fe80–febf）
            if withoutZone.hasPrefix("fe8") || withoutZone.hasPrefix("fe9")
                || withoutZone.hasPrefix("fea") || withoutZone.hasPrefix("feb") {
                return true
            }
            return false
        }

        return isPrivateIPv4(withoutZone)
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ 0...255 ~= $0 }) else { return false }
        if octets[0] == 10 || octets[0] == 127 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 169 && octets[1] == 254 { return true }
        return false
    }

    private static func isValidIPv6(_ host: String) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16)
        return host.withCString { inet_pton(AF_INET6, $0, &buffer) == 1 }
    }
}
