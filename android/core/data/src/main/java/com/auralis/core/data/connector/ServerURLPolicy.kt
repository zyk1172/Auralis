// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.connector

/**
 * 服务器 URL 策略（对齐 Apple `ServerURLPolicy` + `NetworkHostClassifier`）。
 *
 * 为什么在 core:data：连接/测试/编辑前统一把关，杜绝「凭据随地址明文落库」与
 * 「HTTP 明文连公网」两类隐私风险；UI 层与 Connector 共用同一判断，不复制两份。
 *
 * 规则：
 * 1. scheme 必须是 http/https，且必须有 host —— 否则 InvalidUrl；
 * 2. 拒绝内嵌凭据 `user:pass@host`（http 与 https 都拒）—— 凭据只进 Vault；
 * 3. `http://` 只允许私网/本机主机；公网必须 HTTPS —— InsecurePublicServer。
 *
 * 私网/本机判定（对齐 Swift NetworkHostClassifier）：
 * - 主机名 `localhost`、后缀 `.local`；
 * - IPv4：10/8、127/8、172.16/12、192.168/16、169.254/16；
 * - IPv6：`::1`、ULA `fc00::/7`、link-local `fe80::/10`、`::ffff:a.b.c.d` IPv4-mapped；
 * - 带 zone identifier（`fe80::1%en0`）。
 */
object ServerURLPolicy {

    sealed interface Failure {
        val message: String

        /** 地址格式错误（非 http/https、无主机）。 */
        data object InvalidUrl : Failure {
            override val message: String = "服务器地址无效，请包含 http:// 或 https://。"
        }

        /** 地址内嵌 user:pass@ —— 凭据会随地址明文落库/进日志。 */
        data object EmbeddedCredentials : Failure {
            override val message: String =
                "服务器地址不能内嵌用户名或密码（如 user:pass@host）。请把用户名与密码填写在对应输入框。"
        }

        /** http 明文连公网被拒；HTTP 仅允许本机或私有局域网地址。 */
        data object InsecurePublicServer : Failure {
            override val message: String =
                "公共网络服务器必须使用 HTTPS；HTTP 仅允许本机或私有局域网地址。"
        }
    }

    /**
     * 校验完整地址字符串。
     * @return null = 通过；否则为对应的拒绝原因（含可直接展示的中文文案）。
     */
    fun validate(rawInput: String): Failure? {
        val raw = rawInput.trim()
        if (raw.isEmpty()) return Failure.InvalidUrl
        val withScheme = if (raw.contains("://")) raw else "https://$raw"
        val uri = runCatching { java.net.URI(withScheme) }.getOrNull()
            ?: return Failure.InvalidUrl
        val scheme = uri.scheme?.lowercase() ?: return Failure.InvalidUrl
        if (scheme != "http" && scheme != "https") return Failure.InvalidUrl
        // 内嵌凭据（http/https 一律拒绝）：Java URI 把 user:pass@host 解析进 userInfo。
        if (!uri.userInfo.isNullOrEmpty()) return Failure.EmbeddedCredentials
        val host = uri.host ?: return Failure.InvalidUrl
        if (scheme == "http" && !isPrivateOrLocal(host)) return Failure.InsecurePublicServer
        return null
    }

    /** 主机是否私网 / 本机。`host` 可为 IP 字面量（含 IPv6 方括号）或主机名。 */
    fun isPrivateOrLocal(host: String): Boolean {
        val normalized = host.lowercase()
            .removePrefix("[")
            .removeSuffix("]")
        if (normalized == "localhost" || normalized.endsWith(".local")) return true

        // 剥离 IPv6 zone identifier：fe80::1%en0 → fe80::1
        val withoutZone = normalized.substringBefore('%')

        // IPv4-mapped IPv6：::ffff:192.168.1.5 → 按 IPv4 判断
        if (withoutZone.startsWith("::ffff:")) {
            return isPrivateIpv4(withoutZone.removePrefix("::ffff:"))
        }

        if (withoutZone.contains(':')) {
            if (!isValidIpv6(withoutZone)) return false
            if (withoutZone == "::1") return true
            // fc00::/7（ULA：fc00–fdff）
            if (withoutZone.startsWith("fc") || withoutZone.startsWith("fd")) return true
            // fe80::/10（link-local：fe80–febf）
            if (withoutZone.startsWith("fe8") || withoutZone.startsWith("fe9") ||
                withoutZone.startsWith("fea") || withoutZone.startsWith("feb")
            ) {
                return true
            }
            return false
        }

        return isPrivateIpv4(withoutZone)
    }

    private fun isPrivateIpv4(host: String): Boolean {
        val octets = host.split('.').map { it.toIntOrNull() }
        if (octets.size != 4 || octets.any { it == null || it !in 0..255 }) return false
        val o = octets.map { it!! }
        if (o[0] == 10 || o[0] == 127) return true
        if (o[0] == 192 && o[1] == 168) return true
        if (o[0] == 172 && o[1] in 16..31) return true
        if (o[0] == 169 && o[1] == 254) return true
        return false
    }

    private fun isValidIpv6(host: String): Boolean {
        // Java InetAddress 可解析冒号字面量；失败返回 null。
        return runCatching {
            val a = java.net.InetAddress.getByName(host)
            a is java.net.Inet6Address
        }.getOrDefault(false)
    }
}
