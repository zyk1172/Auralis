// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import com.auralis.core.data.local.AndroidLocalMusicLibrary
import com.auralis.core.domain.ServerId
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** Lightweight contract guard: local catalog identity must never collide with a real server id. */
class UnifiedCatalogRepositoryTest {
    @Test
    fun localNamespaceIsDistinctFromOrdinaryServerIdentity() {
        assertNotEquals(ServerId("server-a"), AndroidLocalMusicLibrary.LOCAL_SERVER_ID)
        assertNotEquals(ServerId("local"), AndroidLocalMusicLibrary.LOCAL_SERVER_ID)
    }
}
