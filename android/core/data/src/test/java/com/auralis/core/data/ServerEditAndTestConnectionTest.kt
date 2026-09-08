// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import com.auralis.core.data.connector.ConnectionOutcome
import com.auralis.core.data.connector.ProductionServerConnector
import com.auralis.core.data.connector.TestConnectionResult
import com.auralis.core.data.db.AuralisDatabase
import com.auralis.core.data.repository.RoomCatalogRepository
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * 连接测试 / 编辑（对齐 Apple `testServerConnectionWithInput` + `updateServerConfiguration`）：
 * 1. testConnection 成功返回服务器公开信息，且**不持久化任何账户/凭据**；
 * 2. testConnection 认证失败 / 不可达 + 外网兜底 分类正确；
 * 3. connect() 前置策略：公网 HTTP / 内嵌凭据在写 Vault 前被拒；
 * 4. edit() 身份稳定：改地址不新建重复服务器、凭据引用不变、保留已同步目录。
 */
class ServerEditAndTestConnectionTest : RoomDbTest() {
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

    // ------------------------------------------------- testConnection：不落库

    @Test
    fun `testConnection 成功返回服务器信息且不持久化`() = runBlocking {
        val server = MockWebServer(); server.start()
        try {
            server.enqueueCatalog()
            val conn = connector()

            val result = conn.testConnection(
                displayName = "Probe",
                baseUrl = url(server),
                externalBaseUrl = null,
                username = "u",
                secret = "pw",
            )

            assertTrue("应成功: $result", result is TestConnectionResult.Success)
            result as TestConnectionResult.Success
            assertEquals("navidrome", result.serverType)
            // 不持久化：无服务器账户、无凭据、注册表为空。
            assertEquals(0, repo.servers().size)
            assertEquals(0, vault.snapshot().size)
            assertNull(conn.registry.resolve(com.auralis.core.domain.ServerId("whatever")))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `testConnection 认证失败被分类为 AuthenticationFailed 且不切外网`() = runBlocking {
        val internal = MockWebServer(); internal.start()
        val external = MockWebServer(); external.start()
        try {
            internal.enqueueAuthFailure()
            external.enqueueCatalog()
            val conn = connector()

            val result = conn.testConnection(
                displayName = "Probe",
                baseUrl = url(internal),
                externalBaseUrl = url(external),
                username = "u",
                secret = "wrong",
            )

            assertEquals(TestConnectionResult.AuthenticationFailed, result)
            assertEquals(0, external.requestCount)
            assertEquals(0, vault.snapshot().size)
        } finally {
            internal.shutdown(); external.shutdown()
        }
    }

    @Test
    fun `testConnection 内网不可达时走外网兜底`() = runBlocking {
        val internal = MockWebServer(); internal.start()
        val external = MockWebServer(); external.start()
        try {
            internal.enqueueHttp(503)
            external.enqueueCatalog()
            val conn = connector()

            val result = conn.testConnection(
                displayName = "Probe",
                baseUrl = url(internal),
                externalBaseUrl = url(external),
                username = "u",
                secret = "pw",
            )

            assertTrue("应走外网成功: $result", result is TestConnectionResult.Success)
            assertEquals(0, vault.snapshot().size)
        } finally {
            internal.shutdown(); external.shutdown()
        }
    }

    @Test
    fun `testConnection 地址策略拒绝公网 HTTP`() = runBlocking {
        val conn = connector()
        val result = conn.testConnection(
            displayName = "Probe",
            baseUrl = "http://music.example.test",
            externalBaseUrl = null,
            username = "u",
            secret = "pw",
        )
        assertTrue(result is TestConnectionResult.Failed)
        assertEquals(0, vault.snapshot().size)
    }

    // ------------------------------------------------- connect：策略前置

    @Test
    fun `connect 拒绝公网 HTTP 且不写凭据`() = runBlocking {
        val conn = connector()
        val outcome = conn.connect(
            displayName = "Public",
            baseUrl = "http://music.example.test",
            externalBaseUrl = null,
            username = "u",
            secret = "pw",
            previousAccount = null,
        )
        assertTrue("应被策略拒绝: $outcome", outcome is ConnectionOutcome.Failed)
        assertEquals(0, repo.servers().size)
        assertEquals(0, vault.snapshot().size)
    }

    @Test
    fun `connect 拒绝内嵌凭据`() = runBlocking {
        val conn = connector()
        val outcome = conn.connect(
            displayName = "Bad",
            baseUrl = "http://alice:secret@nas.local:4533",
            externalBaseUrl = null,
            username = "alice",
            secret = "pw",
            previousAccount = null,
        )
        assertTrue("应被策略拒绝: $outcome", outcome is ConnectionOutcome.Failed)
        assertEquals(0, repo.servers().size)
    }

    // ------------------------------------------------- edit：身份稳定

    @Test
    fun `edit 改地址保持同一 serverId 不新建重复服务器`() = runBlocking {
        val old = MockWebServer(); old.start()
        val now = MockWebServer(); now.start()
        try {
            old.enqueueCatalog()
            now.enqueueCatalog()
            val conn = connector()
            val first = conn.connect(
                displayName = "Srv",
                baseUrl = url(old),
                externalBaseUrl = null,
                username = "u",
                secret = "pw",
                previousAccount = null,
            )
            assertTrue(first is ConnectionOutcome.Success)
            val sid = (first as ConnectionOutcome.Success).serverId
            assertEquals("opensubsonic.${sid.value}", vault.snapshot().keys.single())

            // 改内网地址 + 显示名：身份不变。
            val second = conn.edit(
                account = repo.servers().single(),
                displayName = "Srv-renamed",
                baseUrl = url(now),
                externalBaseUrl = null,
                username = "u",
                secret = null,
            )
            assertTrue("编辑应成功: $second", second is ConnectionOutcome.Success)
            assertEquals(sid, (second as ConnectionOutcome.Success).serverId)

            // 仍只有一台服务器；显示名与地址已更新；凭据引用不变。
            val saved = repo.servers()
            assertEquals(1, saved.size)
            assertEquals("Srv-renamed", saved.single().displayName)
            assertEquals(url(now), saved.single().baseUrl)
            assertEquals("opensubsonic.${sid.value}", saved.single().credentialReference)
            // 注册表路由到新端点。
            assertEquals(url(now), conn.registry.client(sid)!!.baseUrl)
        } finally {
            old.shutdown(); now.shutdown()
        }
    }

    @Test
    fun `edit 密码留空沿用已存凭据`() = runBlocking {
        val server = MockWebServer(); server.start()
        try {
            server.enqueueCatalog()
            val conn = connector()
            val first = conn.connect(
                displayName = "Srv",
                baseUrl = url(server),
                externalBaseUrl = null,
                username = "u",
                secret = "pw-1",
                previousAccount = null,
            )
            assertTrue(first is ConnectionOutcome.Success)
            val sid = (first as ConnectionOutcome.Success).serverId
            assertEquals("pw-1", vault.retrieve("opensubsonic.${sid.value}"))

            // 密码留空 → 沿用旧凭据（不覆盖）。
            val second = conn.edit(
                account = repo.servers().single(),
                displayName = "Srv",
                baseUrl = url(server),
                externalBaseUrl = null,
                username = "u",
                secret = "",
            )
            assertTrue(second is ConnectionOutcome.Success)
            assertEquals("pw-1", vault.retrieve("opensubsonic.${sid.value}"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `edit 失败恢复旧账户与旧凭据`() = runBlocking {
        val old = MockWebServer(); old.start()
        val dead = MockWebServer(); dead.start()
        try {
            old.enqueueCatalog()
            dead.enqueueHttp(503)
            val conn = connector()
            val first = conn.connect(
                displayName = "Srv",
                baseUrl = url(old),
                externalBaseUrl = null,
                username = "u",
                secret = "pw-old",
                previousAccount = null,
            )
            assertTrue(first is ConnectionOutcome.Success)
            val sid = (first as ConnectionOutcome.Success).serverId

            val failed = conn.edit(
                account = repo.servers().single(),
                displayName = "Srv-new",
                baseUrl = url(dead),
                externalBaseUrl = null,
                username = "u",
                secret = "pw-new",
            )
            assertTrue("应失败: $failed", failed is ConnectionOutcome.Unreachable)

            // 回滚：旧账户、旧凭据、旧路由都在。
            val saved = repo.servers()
            assertEquals(1, saved.size)
            assertEquals(url(old), saved.single().baseUrl)
            assertEquals("pw-old", vault.retrieve("opensubsonic.${sid.value}"))
            assertEquals(url(old), conn.registry.client(sid)!!.baseUrl)
        } finally {
            old.shutdown(); dead.shutdown()
        }
    }
}
