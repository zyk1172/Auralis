// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.auralis.core.domain.DownloadRepository
import com.auralis.core.domain.PlaybackSourceResolver
import com.auralis.core.domain.ResolvedSource
import com.auralis.core.domain.StreamUrlProvider
import com.auralis.core.domain.Track
import java.io.File

/** Local complete files/content URIs first, remote OpenSubsonic streams second. */
class DefaultPlaybackSourceResolver(
    private val downloads: DownloadRepository,
    private val streamUrlProvider: StreamUrlProvider,
) : PlaybackSourceResolver {

    override suspend fun resolve(track: Track, forceRefresh: Boolean): ResolvedSource {
        val cached = downloads.localPath(track.globalId)
        if (cached != null && cached.isNotEmpty()) {
            val file = File(cached)
            if (file.exists() && file.length() > 0) return ResolvedSource.Local(cached)
        }
        val existingUrl = track.streamUrl
        if (!forceRefresh && !existingUrl.isNullOrEmpty()) {
            if (existingUrl.startsWith("content://") || existingUrl.startsWith("file://")) {
                return ResolvedSource.Local(existingUrl)
            }
            return ResolvedSource.Remote(existingUrl)
        }
        // Local-library tracks never fall through into the server connector.
        if (track.serverId.value == "auralis-local") return ResolvedSource.Unavailable
        val url = streamUrlProvider.streamUrl(track, forceRefresh)
        if (url.isNullOrEmpty()) return ResolvedSource.Unavailable
        return ResolvedSource.Remote(url)
    }
}
