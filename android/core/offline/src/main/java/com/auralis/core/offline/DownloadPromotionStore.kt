// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.offline

import android.content.Context
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.LocalLibraryId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.TrackId
import com.auralis.core.domain.TrackIdentityTransition

/** Persistent remote -> canonical-local alias table for completed server downloads. */
class DownloadPromotionStore(context: Context) {
    private val prefs = context.getSharedPreferences("auralis_download_promotions", Context.MODE_PRIVATE)

    fun promote(remote: GlobalId): GlobalId {
        val existing = prefs.getString(remote.serialized, null)
        if (existing != null) return GlobalId.parse(existing)
        val local = GlobalId(LOCAL_SERVER_ID, "local-download-${fnv64(remote.serialized)}")
        prefs.edit().putString(remote.serialized, local.serialized).apply()
        return local
    }

    fun canonicalLocalId(remote: GlobalId): GlobalId? =
        prefs.getString(remote.serialized, null)?.let(GlobalId::parse)

    fun transition(remote: GlobalId): TrackIdentityTransition? {
        val local = canonicalLocalId(remote) ?: return null
        return TrackIdentityTransition(
            remoteServerId = remote.serverId,
            remoteTrackId = TrackId(remote.remoteId),
            localLibraryId = DOWNLOADS_LIBRARY_ID,
            localTrackId = TrackId(local.remoteId),
        )
    }

    fun mappings(): Map<GlobalId, GlobalId> = prefs.all.mapNotNull { (key, value) ->
        val raw = value as? String ?: return@mapNotNull null
        runCatching { GlobalId.parse(key) to GlobalId.parse(raw) }.getOrNull()
    }.toMap()

    fun remove(remote: GlobalId) {
        prefs.edit().remove(remote.serialized).apply()
    }

    fun clear() {
        prefs.edit().clear().apply()
    }

    companion object {
        val LOCAL_SERVER_ID = ServerId("auralis-local")
        val DOWNLOADS_LIBRARY_ID = LocalLibraryId("downloads")

        internal fun fnv64(value: String): String {
            var hash = 0xcbf29ce484222325UL
            for (byte in value.encodeToByteArray()) {
                hash = hash xor byte.toUByte().toULong()
                hash *= 0x100000001b3UL
            }
            return hash.toString(16)
        }
    }
}
