// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import com.auralis.core.data.connector.ConnectionOutcome
import com.auralis.core.data.connector.EndpointKind
import com.auralis.core.data.connector.ProductionServerConnector
import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.repository.RoomCatalogRepository
import com.auralis.core.domain.ServerAccount
import com.auralis.core.domain.ServerId
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * P0 端点路由 + 凭据回滚测试（对应 Apple selectAuthenticatedClient 语义）：
 * 1. 内网可达 → 用内网（外网零请求）；
 * 2. 内网不可达 + 外网可达 → 同步/重同步/后续全部走外网；
 * 3. 内网认证失败 + 外网可达 → 仍报认证失败，绝不偷偷切外网；
 * 4. 内网协议错误 → 失败，不允许当成纯网络不可达；
 * 5. 编辑失败恢复旧凭据；新增失败删除全新凭据与残留账户。
 */
class ProductionServerConnectorTest : RoomDbTest() {
    private lateinit var db: AuralisDatabase
    private lateinit var repo: RoomCatalogRepository
    private lateinit var vault: FakeVault

    @Before
    fun setUp() {
        db = openDatabase()
        repo = repository(db)
        vault = FakeVault()
    }

    @After
    fun tearDown() {
        if (::db.isInitialized) db.close()
    }

    private fun connector() = ProductionServerConnector(vault, repo)

    private fun url(server: MockWebServer): String = server.url("/").toString()

    private suspend fun newServerAccount(
        internalUrl: String,
        externalUrl: String? = null,
        username: String = "u",
    ): Triple<ServerId, String, ServerAccount> {
        val conn = connector()
        val normalized = conn.normalizedBaseUrl(internalUrl)!!
        val sid = conn.stableServerId(normalized, username)
        val account = server(
            id = sid,
            displayName = "Test",
            baseUrl = normalized,
            external = externalUrl?.let { conn.normalizedBaseUrl(it) },
            username = username,
        )
        return Triple(sid, ProductionServerConnector.credentialReferenceFor(sid), account)
    }

    // ------------------------------------------------- 1) 内网优先

    @Test
    fun `内网可达时用内网且外网零请求`() = runBlocking {
        val internal = MockWebServer(); internal.start()
        val external = MockWebServer(); external.start()
        try {
            internal.enqueueCatalog()
            external.enqueueCatalog()

            val conn = connector()
            val outcome = conn.connect(
                displayName = "Srv",
                baseUrl = url(internal),
                externalBaseUrl = url(external),
                username = "u",
                secret = "pw",
                previousAccount = null,
            )
            assertTrue("connect 应成功: $outcome", outcome is ConnectionOutcome.Success)
            val sid = (outcome as ConnectionOutcome.Success).serverId

            // 路由内网；外网完全没被请求。
            assertEquals(EndpointKind.Internal, conn.registry.kind(sid))
            assertEquals(url(internal), conn.registry.client(sid)!!.baseUrl)
            assertEquals(0, external.requestCount)

            // 服务器账户已持久化（含内网地址）。
            val saved = repo.servers().first { it.id == sid }
            assertEquals(url(internal), saved.baseUrl)
        } finally {
            internal.shutdown(); external.shutdown()
        }
    }

    // ------------------------------------------------- 2) 内网挂 → 外网

    @Test
    fun `内网不可达且外网可达时同步重同步全走外网`() = runBlocking {
        val internal = MockWebServer(); internal.start()
        val external = MockWebServer(); external.start()
        try {
            internal.enqueueHttp(500) // transport 失败 → 不可达
            external.enqueueCatalog()

            val conn = connector()
            val outcome = conn.connect(
                displayName = "Srv",
                baseUrl = url(internal),
                externalBaseUrl = url(external),
                username = "u",
                secret = "pw",
                previousAccount = null,
            )
            assertTrue("应降级外网成功: $outcome", outcome is ConnectionOutcome.Success)
            val sid = (outcome as ConnectionOutcome.Success).serverId

            assertEquals(EndpointKind.External, conn.registry.kind(sid))
            assertEquals(url(external), conn.registry.client(sid)!!.baseUrl)
            assertEquals(1, internal.requestCount) // 仅探测那一次 ping

            // 重同步仍走外网，内网不被再次触碰。
            val beforeExternal = external.requestCount
            val resync = conn.resync(repo.servers().first { it.id == sid })
            assertTrue("resync 应成功: $resync", resync is ConnectionOutcome.Success)
            assertTrue(external.requestCount > beforeExternal)
            assertEquals(1, internal.requestCount)
        } finally {
            internal.shutdown(); external.shutdown()
        }
    }

    // ------------------------------------------------- 3) 认证失败不切外网

    @Test
    fun `内网认证失败时不切外网且不回写凭据`() = runBlocking {
        val internal = MockWebServer(); internal.start()
        val external = MockWebServer(); external.start()
        try {
            internal.enqueueAuthFailure()
            external.enqueueCatalog()

            val conn = connector()
            val (sid, ref, _) = newServerAccount(url(internal), url(external))
            val outcome = conn.connect(
                displayName = "Srv",
                baseUrl = url(internal),
                externalBaseUrl = url(external),
                username = "u",
                secret = "wrong",
                previousAccount = null,
            )
            assertTrue(outcome is ConnectionOutcome.AuthFailed)
            assertEquals(0, external.requestCount) // 认证失败绝不偷偷切外网
            assertEquals(1, internal.requestCount)

            // 全新服务器失败：不留 orphan 凭据 / orphan 账户。
            assertNull(vault.retrieve(ref))
            assertTrue(repo.servers().isEmpty())
        } finally {
            internal.shutdown(); external.shutdown()
        }
    }

    // ------------------------------------------------- 4) 协议错误 ≠ 网络不可达

    @Test
    fun `内网协议错误按失败处理不当作不可达不切外网`() = runBlocking {
        val internal = MockWebServer(); internal.start()
        val external = MockWebServer(); external.start()
        try {
            internal.enqueueGarbageBody()
            external.enqueueCatalog()

            val conn = connector()
            val outcome = conn.connect(
                displayName = "Srv",
                baseUrl = url(internal),
                externalBaseUrl = url(external),
                username = "u",
                secret = "pw",
                previousAccount = null,
            )
            assertTrue("应报协议失败: $outcome", outcome is ConnectionOutcome.Failed)
            assertTrue((outcome as ConnectionOutcome.Failed).message.contains("协议错误"))
            assertEquals(0, external.requestCount)
            assertEquals(1, internal.requestCount)
        } finally {
            internal.shutdown(); external.shutdown()
        }
    }

    // ------------------------------------------------- 5) 凭据回滚

    @Test
    fun `编辑失败恢复旧凭据与旧账户`() = runBlocking {
        val internal = MockWebServer(); internal.start()
        try {
            internal.enqueueAuthFailure()

            val conn = connector()
            val (sid, ref, previous) = newServerAccount(url(internal))
            // 已有旧账户与旧 secret。
            vault.store(ref, "old-secret")
            repo.upsertServer(previous)

            val outcome = conn.connect(
                displayName = "New Name",
                baseUrl = url(internal),
                externalBaseUrl = null,
                username = "u",
                secret = "new-secret",
                previousAccount = previous,
            )
            assertTrue(outcome is ConnectionOutcome.AuthFailed)

            // 旧 secret 恢复、旧账户未被破坏。
            assertEquals("old-secret", vault.retrieve(ref))
            val saved = repo.servers().single()
            assertEquals(previous.displayName, saved.displayName)
            assertEquals(previous.id, saved.id)
        } finally {
            internal.shutdown()
        }
    }

    @Test
    fun `成功连接后凭据与收藏回流落库`() = runBlocking {
        val internal = MockWebServer(); internal.start()
        try {
            internal.enqueueCatalogWithStarredSong()

            val conn = connector()
            val (sid, ref, _) = newServerAccount(url(internal))
            val outcome = conn.connect(
                displayName = "Srv",
                baseUrl = url(internal),
                externalBaseUrl = null,
                username = "u",
                secret = "pw",
                previousAccount = null,
            )
            assertTrue("应成功: $outcome", outcome is ConnectionOutcome.Success)

            // 凭据保留（成功后不回滚）。
            assertEquals("pw", vault.retrieve(ref))
            // getStarred2 回流 → favorites 表含该服务器的 s1（global_id = serverId:s1）。
            assertEquals(listOf("${sid.value}:s1"), db.annotationDao().favoriteTrackIds(sid.value))
        } finally {
            internal.shutdown()
        }
    }

    @Test
    fun `忘记服务器删除目录凭据与注册表条目`() = runBlocking {
        val internal = MockWebServer(); internal.start()
        try {
            internal.enqueueCatalog()

            val conn = connector()
            val (sid, ref, account) = newServerAccount(url(internal))
            val outcome = conn.connect(
                displayName = "Srv",
                baseUrl = url(internal),
                externalBaseUrl = null,
                username = "u",
                secret = "pw",
                previousAccount = null,
            )
            assertTrue(outcome is ConnectionOutcome.Success)
            assertNotNull(conn.registry.client(sid))

            conn.forgetServer(sid)

            assertNull(conn.registry.client(sid))
            assertNull(vault.retrieve(ref))
            assertTrue(repo.servers().none { it.id == sid })
        } finally {
            internal.shutdown()
        }
    }
}
