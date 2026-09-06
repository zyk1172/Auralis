package com.auralis.core.opensubsonic

import java.security.MessageDigest
import java.util.UUID

/**
 * OpenSubsonic 协议常量与工具。
 * 逐项对齐 Apple `OpenSubsonicKit/OpenSubsonic.swift` 与 `Authentication.swift`。
 */

enum class OpenSubsonicEndpoint(val path: String) {
    Ping("ping"),
    GetOpenSubsonicExtensions("getOpenSubsonicExtensions"),
    GetMusicFolders("getMusicFolders"),
    GetArtists("getArtists"),
    GetArtist("getArtist"),
    GetAlbum("getAlbum"),
    GetSong("getSong"),
    GetGenres("getGenres"),
    GetAlbumList2("getAlbumList2"),
    GetRandomSongs("getRandomSongs"),
    GetStarred2("getStarred2"),
    Search3("search3"),
    GetPlaylists("getPlaylists"),
    GetPlaylist("getPlaylist"),
    CreatePlaylist("createPlaylist"),
    UpdatePlaylist("updatePlaylist"),
    DeletePlaylist("deletePlaylist"),
    Stream("stream"),
    Download("download"),
    GetCoverArt("getCoverArt"),
    GetLyrics("getLyrics"),
    GetLyricsBySongId("getLyricsBySongId"),
    Star("star"),
    Unstar("unstar"),
    SetRating("setRating"),
    Scrobble("scrobble"),
    GetPlayQueue("getPlayQueue"),
    SavePlayQueue("savePlayQueue"),
    GetSimilarSongs2("getSimilarSongs2"),
}

object OpenSubsonicProtocol {
    const val CLIENT_NAME = "Auralis"
    const val PROTOCOL_VERSION = "1.16.1"
    const val FORMAT = "json"

    /** 保留认证参数：调用方禁止传入，由 [OpenSubsonicClient] 注入。 */
    val RESERVED_AUTH_PARAMS = setOf("u", "p", "t", "s", "apikey")

    /** `<scheme>://<host>[:port]<basePath>/rest/<endpoint>.view` */
    fun endpointUrl(baseUrl: String, endpoint: OpenSubsonicEndpoint): String {
        var base = baseUrl.trim()
        require(base.startsWith("http://", ignoreCase = true) || base.startsWith("https://", ignoreCase = true)) {
            "Invalid base URL: $baseUrl"
        }
        while (base.endsWith("/")) base = base.dropLast(1)
        val fragment = base.indexOf('#')
        if (fragment >= 0) base = base.substring(0, fragment)
        val query = base.indexOf('?')
        if (query >= 0) base = base.substring(0, query)
        return "$base/rest/${endpoint.path}.view"
    }
}

/**
 * token = md5(password + salt) 的小写十六进制。
 * 逐字对齐 Apple `OpenSubsonicTokenSigner`：输入顺序为先 password 再 salt，无分隔符。
 */
object OpenSubsonicTokenSigner {
    fun token(password: String, salt: String): String {
        require(salt.length >= 6) { "salt must have at least six characters" }
        val digest = MessageDigest.getInstance("MD5").digest((password + salt).toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    /** 默认 salt：去横线的小写 UUID（32 字符）。 */
    fun newSalt(): String = UUID.randomUUID().toString().replace("-", "").lowercase()
}

/**
 * 表单编码。Apple `OpenSubsonicFormEncoder` 的转义规则**不是标准** percent-encoding：
 * 保留 `A-Za-z0-9-._~`，空格 → `+`，其余字节 → `%XX`（**大写**十六进制）。
 * 必须逐字复刻，否则签名/参数会与 Apple 端不一致。
 */
object OpenSubsonicFormEncoder {
    fun escape(value: String): String {
        val out = StringBuilder(value.length)
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val c = byte.toInt() and 0xFF
            val ch = c.toChar()
            when {
                ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '.' || ch == '_' || ch == '~' ->
                    out.append(ch)
                c == 0x20 -> out.append('+')
                else -> out.append("%%%02X".format(c))
            }
        }
        return out.toString()
    }

    fun encode(items: List<Pair<String, String>>): String =
        items.joinToString("&") { (name, value) -> "${escape(name)}=${escape(value)}" }
}
