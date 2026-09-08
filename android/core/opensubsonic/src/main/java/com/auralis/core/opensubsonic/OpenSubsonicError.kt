// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.opensubsonic

sealed interface OpenSubsonicError {
    data object InvalidBaseUrl : OpenSubsonicError
    data class InvalidConfiguration(val detail: String) : OpenSubsonicError
    data object NetworkUnavailable : OpenSubsonicError
    data object TimedOut : OpenSubsonicError
    data object Unreachable : OpenSubsonicError
    data object AuthenticationFailed : OpenSubsonicError
    data object AuthorizationFailed : OpenSubsonicError
    data object NotFound : OpenSubsonicError
    data class Server(val code: Int, val message: String) : OpenSubsonicError
    data class InvalidResponse(val detail: String) : OpenSubsonicError
    data object Unknown : OpenSubsonicError
}

class OpenSubsonicException(val kind: OpenSubsonicError, cause: Throwable? = null) :
    RuntimeException(describe(kind), cause) {
    companion object {
        private fun describe(kind: OpenSubsonicError): String = when (kind) {
            is OpenSubsonicError.Server -> "OpenSubsonic error ${kind.code}: ${kind.message}"
            is OpenSubsonicError.InvalidConfiguration -> kind.detail
            is OpenSubsonicError.InvalidResponse -> kind.detail
            else -> kind::class.simpleName ?: "OpenSubsonic failure"
        }
    }
}

/**
 * 端点是否可安全重试。
 * 对齐 Apple：写操作（歌单 / star / rating / scrobble / savePlayQueue）**不可重试**，
 * 读与流可重试。破坏性请求绝不能盲目重放。
 */
fun OpenSubsonicEndpoint.isRetryable(): Boolean = when (this) {
    OpenSubsonicEndpoint.Ping,
    OpenSubsonicEndpoint.GetOpenSubsonicExtensions,
    OpenSubsonicEndpoint.GetMusicFolders,
    OpenSubsonicEndpoint.GetArtists,
    OpenSubsonicEndpoint.GetArtist,
    OpenSubsonicEndpoint.GetAlbum,
    OpenSubsonicEndpoint.GetSong,
    OpenSubsonicEndpoint.GetGenres,
    OpenSubsonicEndpoint.GetAlbumList2,
    OpenSubsonicEndpoint.GetRandomSongs,
    OpenSubsonicEndpoint.GetStarred2,
    OpenSubsonicEndpoint.Search3,
    OpenSubsonicEndpoint.GetPlaylists,
    OpenSubsonicEndpoint.GetPlaylist,
    OpenSubsonicEndpoint.GetCoverArt,
    OpenSubsonicEndpoint.GetLyrics,
    OpenSubsonicEndpoint.GetLyricsBySongId,
    OpenSubsonicEndpoint.Stream,
    OpenSubsonicEndpoint.Download,
    OpenSubsonicEndpoint.GetPlayQueue,
    OpenSubsonicEndpoint.GetSimilarSongs2,
    -> true

    OpenSubsonicEndpoint.CreatePlaylist,
    OpenSubsonicEndpoint.UpdatePlaylist,
    OpenSubsonicEndpoint.DeletePlaylist,
    OpenSubsonicEndpoint.Star,
    OpenSubsonicEndpoint.Unstar,
    OpenSubsonicEndpoint.SetRating,
    OpenSubsonicEndpoint.Scrobble,
    OpenSubsonicEndpoint.SavePlayQueue,
    -> false
}
