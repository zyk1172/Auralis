// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.auralis.core.domain.DownloadRepository
import com.auralis.core.domain.PlaybackSourceResolver
import com.auralis.core.domain.ResolvedSource
import com.auralis.core.domain.StreamUrlProvider
import com.auralis.core.domain.Track
import java.io.File

/** Existing downloaded files are local paths; local-library URIs are passed directly to Media3. */
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
            // Media3 consumes content:// and file:// via Uri.parse on the existing URL path.
            // They are local-library sources semantically even though the legacy transport enum
            // calls every URI-valued source Remote.
            return ResolvedSource.Remote(existingUrl)
        }
        // Local-library tracks must never fall through into an OpenSubsonic connector.
        if (track.serverId.value == "auralis-local") return ResolvedSource.Unavailable
        val url = streamUrlProvider.streamUrl(track, forceRefresh)
        if (url.isNullOrEmpty()) return ResolvedSource.Unavailable
        return ResolvedSource.Remote(url)
    }
}
