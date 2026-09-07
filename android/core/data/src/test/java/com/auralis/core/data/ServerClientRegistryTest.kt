package com.auralis.core.data

import com.auralis.core.data.connector.EndpointKind
import com.auralis.core.data.connector.ServerClientRegistry
import com.auralis.core.domain.ServerId
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ServerClientRegistry 语义：注册表是进程级「serverID → 当前可用端点」的唯一真相。
 * - registerResolved 后 client/resolve/kind 一致；
 * - remove 后彻底失效；
 * - 未登记返回 null（UI 据此进入「未连接」而非崩溃）。
 */
class ServerClientRegistryTest {

    private fun vault() = FakeVault()

    private fun account(serverId: ServerId, external: String? = null) =
        com.auralis.core.domain.ServerAccount(
            id = serverId,
            displayName = "Srv",
            baseUrl = "http://lan:4530/",
            externalBaseUrl = external,
            username = "admin",
            credentialReference = "opensubsonic.${serverId.value}",
        )

    @Test
    fun `登记后可解析到同一客户端与端点类别`() = runBlocking {
        val registry = ServerClientRegistry(vault())
        val id = ServerId("server-1")
        val endpoint = registry.makeInternalEndpoint(account(id))
        registry.registerResolved(endpoint)

        assertSame(endpoint.client, registry.client(id))
        assertEquals(EndpointKind.Internal, registry.kind(id))
        assertEquals(endpoint.baseUrl, registry.resolve(id)?.baseUrl)
        assertEquals("http://lan:4530/", registry.resolve(id)?.baseUrl)
    }

    @Test
    fun `外网端点登记为 External 且 baseUrl 指向外网`() = runBlocking {
        val registry = ServerClientRegistry(vault())
        val id = ServerId("server-2")
        val endpoint = registry.makeExternalEndpoint(account(id, external = "https://wan.example.com/music"))
        registry.registerResolved(endpoint)

        assertEquals(EndpointKind.External, registry.kind(id))
        assertEquals("https://wan.example.com/music", registry.resolve(id)?.baseUrl)
    }

    @Test
    fun `未登记与删除后返回 null 而不是抛错`() = runBlocking {
        val registry = ServerClientRegistry(vault())
        val id = ServerId("server-3")

        assertNull(registry.client(id))
        assertNull(registry.resolve(id))
        assertNull(registry.kind(id))

        val endpoint = registry.makeInternalEndpoint(account(id))
        registry.registerResolved(endpoint)
        assertNotNull(registry.client(id))

        registry.remove(id)
        assertNull(registry.client(id))
    }

    @Test
    fun `无外网地址时构造外网端点抛错（调用方降级为 Unreachable）`() = runBlocking {
        val registry = ServerClientRegistry(vault())
        val id = ServerId("server-4")
        val boom = runCatching { registry.makeExternalEndpoint(account(id, external = null)) }
        assertTrue(boom.isFailure)
    }
}
