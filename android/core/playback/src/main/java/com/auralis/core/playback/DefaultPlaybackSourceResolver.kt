package com.auralis.core.playback

import com.auralis.core.domain.DownloadRepository
import com.auralis.core.domain.PlaybackSourceResolver
import com.auralis.core.domain.ResolvedSource
import com.auralis.core.domain.StreamUrlProvider
import com.auralis.core.domain.Track
import java.io.File

/**
 * 播放源解析：**本地完整缓存优先**，其次远端 OpenSubsonic stream URL。
 *
 * 对应 Apple `resolvePlayableTrack`（无类名，是 AppModel 方法）：
 * 1. 本地缓存存在 → 直接本地文件 Uri；
 * 2. 已有 streamUrl → 用之（非强制刷新时）；
 * 3. forceRefresh / 无 → 通过 [StreamUrlProvider] 即时解析（按 serverId 找对应客户端）。
 *
 * 注意：stream URL 带认证 query，**不持久化、不打日志**。
 */
class DefaultPlaybackSourceResolver(
    private val downloads: DownloadRepository,
    private val streamUrlProvider: StreamUrlProvider,
) : PlaybackSourceResolver {

    override suspend fun resolve(track: Track, forceRefresh: Boolean): ResolvedSource {
        val cached = downloads.localPath(track.globalId)
        if (cached != null && cached.isNotEmpty()) {
            val file = File(cached)
            if (file.exists() && file.length() > 0) {
                return ResolvedSource.Local(cached)
            }
        }
        val existingUrl = track.streamUrl
        if (!forceRefresh && existingUrl != null && existingUrl.isNotEmpty()) {
            return ResolvedSource.Remote(existingUrl)
        }
        val url = streamUrlProvider.streamUrl(track, forceRefresh)
        if (url.isNullOrEmpty()) return ResolvedSource.Unavailable
        return ResolvedSource.Remote(url)
    }
}
