// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.domain

import kotlinx.serialization.Serializable

@JvmInline
@Serializable
value class LocalLibraryId(val value: String)

@Serializable
data class LocalMusicSource(
    val id: LocalLibraryId,
    val displayName: String,
    /** Persisted SAF/MediaStore URI or another platform-owned opaque token; never assume a raw path. */
    val locationToken: String,
    val isEnabled: Boolean = true,
    val addedAtMillis: Long = System.currentTimeMillis(),
)

@Serializable
sealed interface MusicSource {
    @Serializable
    data class Server(val serverId: ServerId) : MusicSource

    @Serializable
    data class Local(val libraryId: LocalLibraryId) : MusicSource
}

@Serializable
data class LocalTrackReference(
    val libraryId: LocalLibraryId,
    val stableFileId: String,
    /** Resolved to content:// or file:// only when playback needs it. */
    val locationToken: String,
)

@Serializable
sealed interface PlaybackSourceReference {
    @Serializable
    data class Remote(val serverId: ServerId, val trackId: TrackId) : PlaybackSourceReference

    @Serializable
    data class Local(val reference: LocalTrackReference) : PlaybackSourceReference
}

/** Remote IDs remain aliases after a downloaded server track becomes a canonical local-library track. */
@Serializable
data class TrackIdentityTransition(
    val remoteServerId: ServerId,
    val remoteTrackId: TrackId,
    val localLibraryId: LocalLibraryId,
    val localTrackId: TrackId,
    val promotedAtMillis: Long = System.currentTimeMillis(),
)

@Serializable
data class LocalLibraryScanSnapshot(
    val discoveredFiles: Int = 0,
    val importedTracks: Int = 0,
    val updatedTracks: Int = 0,
    val removedTracks: Int = 0,
    val failedFiles: Int = 0,
    val completedAtMillis: Long = System.currentTimeMillis(),
)

interface LocalMusicSourceStore {
    suspend fun sources(): List<LocalMusicSource>
    suspend fun saveSource(source: LocalMusicSource)
    suspend fun removeSource(id: LocalLibraryId)
}

fun interface LocalMusicScanner {
    suspend fun scan(source: LocalMusicSource): LocalLibraryScanSnapshot
}

fun interface PlaybackSourceResolver {
    suspend fun resolve(source: PlaybackSourceReference): String
}
