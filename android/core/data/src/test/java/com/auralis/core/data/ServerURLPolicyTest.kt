package com.auralis.core.data

import com.auralis.core.data.connector.ServerURLPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ServerURLPolicy 对齐 Swift `ServerURLPolicyTests`：
 * - HTTPS 任意主机通过；
 * - HTTP 仅限私网/本机（localhost / .local / RFC1918 / link-local / 回环）；
 * - 公网 HTTP 拒绝；内嵌 user:pass@ 一律拒绝（http 与 https）。
 */
class ServerURLPolicyTest {

    private fun valid(vararg urls: String) {
        urls.forEach { assertNull("应通过: $it", ServerURLPolicy.validate(it)) }
    }

    private fun rejected(kind: ServerURLPolicy.Failure, vararg urls: String) {
        urls.forEach { assertEquals("应拒绝: $it", kind, ServerURLPolicy.validate(it)) }
    }

    @Test
    fun `HTTPS 任意主机名被接受`() {
        valid("https://music.example.test", "https://nas.local", "https://192.168.1.5:4533")
    }

    @Test
    fun `HTTP 仅限本机与私网主机`() {
        valid(
            "http://localhost:4533",
            "http://music.local:4533",
            "http://127.0.0.1:4533",
            "http://10.20.30.40:4533",
            "http://172.16.0.5:4533",
            "http://172.31.255.254:4533",
            "http://192.168.50.5:4533",
            "http://169.254.1.1:4533",
        )
    }

    @Test
    fun `公网 HTTP 被拒绝`() {
        rejected(ServerURLPolicy.Failure.InsecurePublicServer, "http://music.example.test")
    }

    @Test
    fun `非 http-https scheme 或无主机被拒绝`() {
        rejected(
            ServerURLPolicy.Failure.InvalidUrl,
            "ftp://music.example.test",
            "file:///etc/passwd",
            "http://",
            "https://",
            "",
            "  ",
        )
    }

    @Test
    fun `URL 内嵌 user-pass 被拒绝（http 与 https）`() {
        rejected(
            ServerURLPolicy.Failure.EmbeddedCredentials,
            "http://alice:secret@nas.local:4533",
            "https://alice:secret@music.example.test",
            "https://alice@music.example.test",
        )
    }

    @Test
    fun `IPv6 私网本机被判定为私网`() {
        assertTrue(ServerURLPolicy.isPrivateOrLocal("fc00::1"))
        assertTrue(ServerURLPolicy.isPrivateOrLocal("fd12:3456::1"))
        assertTrue(ServerURLPolicy.isPrivateOrLocal("fe80::1"))
        assertTrue(ServerURLPolicy.isPrivateOrLocal("fe80::1%en0"))
        assertTrue(ServerURLPolicy.isPrivateOrLocal("::1"))
        assertTrue(ServerURLPolicy.isPrivateOrLocal("::ffff:192.168.1.5"))
    }

    @Test
    fun `IPv6 公网地址被判定为非私网`() {
        assertTrue(!ServerURLPolicy.isPrivateOrLocal("2001:db8::1"))
        assertTrue(!ServerURLPolicy.isPrivateOrLocal("2606:4700::1111"))
        assertTrue(!ServerURLPolicy.isPrivateOrLocal("2a00:1450:4001::1"))
    }

    @Test
    fun `HTTP 加 IPv6 私网地址通过校验`() {
        valid("http://[::1]:4533", "http://[fc00::1]:4533")
    }
}
