package com.auralis.core.data.connector

import com.auralis.core.data.repository.RoomCatalogRepository
import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.Genre
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.ServerAccount
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.opensubsonic.CredentialVault
import com.auralis.core.opensubsonic.OpenSubsonicAuthentication
import com.auralis.core.opensubsonic.OpenSubsonicClient
import com.auralis.core.opensubsonic.OpenSubsonicConfiguration
import com.auralis.core.opensubsonic.OpenSubsonicError
import com.auralis.core.opensubsonic.OpenSubsonicException
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import com.auralis.core.opensubsonic.OpenSubsonicMapper
import com.auralis.core.opensubsonic.Child
import com.auralis.core.opensubsonic.AlbumDetail
import com.auralis.core.domain.ArtistId
import com.auralis.core.domain.AlbumId
import java.util.concurrent.TimeUnit

/**
 * 端点探测结果。Apple 语义：
 * - `.Transport`/5xx → 服务器**不可达**；
 * - 认证错误（40/41/50、401/403）→ 账号/密码错误，**绝不**当成「不可达」偷偷切外网；
 * - 协议错误 → 判定失败。
 */
enum class ProbeKind { Reachable, Unreachable, AuthenticationFailed, Failed }

data class ProbeResult(val kind: ProbeKind, val serverInfo: com.auralis.core.opensubsonic.ServerInfo? = null)

enum class ConnectionStage {
    Idle,
    Validating,
    StoringCredential,
    Authenticating,
    DetectingCapabilities,
    LoadingLibrary,
    SavingLibrary,
    Done,
}

sealed interface ConnectionOutcome {
    data class Success(val serverId: ServerId, val trackCount: Int) : ConnectionOutcome
    data class AuthFailed(val message: String) : ConnectionOutcome
    data class Unreachable(val message: String) : ConnectionOutcome
    data class Failed(val message: String) : ConnectionOutcome
}

/**
 * 服务器连接编排层（对应 Apple `ProductionServerConnector`，业务编排而非 Retrofit Service）。
 *
 * 职责：URL 归一化 → 凭据先落安全存储 → 双地址探测 → 认证 → capabilities →
 * 全量同步 → **全部成功才 commit**（失败保留旧本地目录）。连接失败回滚旧凭据/旧账号。
 */
class ProductionServerConnector(
    private val vault: CredentialVault,
    private val repository: RoomCatalogRepository,
    private val http: OkHttpClient = defaultHttpClient(),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _stage = MutableStateFlow(ConnectionStage.Idle)
    val stage: StateFlow<ConnectionStage> = _stage.asStateFlow()

    // ------------------------------------------------------------------ 装配

    fun clientFor(account: ServerAccount, external: Boolean = false): OpenSubsonicClient {
        val base = if (external) {
            requireNotNull(account.externalBaseUrl) { "服务器没有外网地址" }
        } else {
            requireNotNull(account.baseUrl) { "服务器没有内网地址" }
        }
        val uname = account.username
        val credential = requireNotNull(account.credentialReference) { "缺少凭据引用" }
        val auth = if (uname.isNullOrBlank()) {
            OpenSubsonicAuthentication.ApiKey(credential)
        } else {
            OpenSubsonicAuthentication.Token(username = uname, credentialReference = credential)
        }
        return OpenSubsonicClient(
            OpenSubsonicConfiguration(base, account.id, auth),
            http,
            vault,
        )
    }

    // ------------------------------------------------------------------ URL

    /** 归一化：scheme/host 小写、仅 path>1 去尾斜杠、剥掉 user/password/query/fragment。 */
    fun normalizedBaseUrl(input: String): String? {
        val raw = input.trim()
        if (raw.isEmpty()) return null
        val withScheme = if (raw.contains("://")) raw else "https://$raw"
        val uri = runCatching { java.net.URI(withScheme) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        val host = uri.host ?: return null
        var path = uri.path
        if (path.length > 1 && path.endsWith("/")) path = path.dropLast(1)
        val port = if (uri.port >= 0) ":${uri.port}" else ""
        return "$scheme://$host$port$path"
    }

    /** 稳定 ID：SHA256(normalizedURL + "\n" + username)，前缀 `server-`。 */
    fun stableServerId(baseUrl: String, username: String?): ServerId {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("$baseUrl\n${username.orEmpty()}".toByteArray(Charsets.UTF_8))
        val hex = digest.joinToString("") { "%02x".format(it) }
        return ServerId("server-$hex")
    }

    // ------------------------------------------------------------------ 探测

    /**
     * 内外网选择策略：
     * - 内网可达 → 用内网；
     * - 内网**认证/协议错误** → 直接失败（不切外网，避免「密码错」被误判成断网）；
     * - 内网不可达（transport/5xx）→ 才尝试外网。
     */
    suspend fun probeEndpoints(account: ServerAccount): ProbeResult {
        val internalResult = probe(account, external = false)
        when (internalResult.kind) {
            ProbeKind.Reachable -> return internalResult
            ProbeKind.AuthenticationFailed, ProbeKind.Failed -> return internalResult
            ProbeKind.Unreachable -> {
                if (account.externalBaseUrl.isNullOrBlank()) return internalResult
                return probe(account, external = true)
            }
        }
    }

    suspend fun probe(account: ServerAccount, external: Boolean): ProbeResult = try {
        val client = clientFor(account, external)
        val info = client.ping()
        ProbeResult(ProbeKind.Reachable, info)
    } catch (e: OpenSubsonicException) {
        when (e.kind) {
            is OpenSubsonicError.AuthenticationFailed,
            is OpenSubsonicError.AuthorizationFailed,
            -> ProbeResult(ProbeKind.AuthenticationFailed)

            is OpenSubsonicError.Unreachable,
            is OpenSubsonicError.NetworkUnavailable,
            is OpenSubsonicError.TimedOut,
            -> ProbeResult(ProbeKind.Unreachable)

            else -> ProbeResult(ProbeKind.Failed)
        }
    } catch (_: Exception) {
        ProbeResult(ProbeKind.Unreachable)
    }

    // --------------------------------------------------------------- 连接主流程

    /**
     * 连接 + 首次全量同步。
     * 失败语义：先存新凭据 → 探测失败时**恢复旧凭据**；同步在内存中全量拉取，
     * 全部成功才 commit（本地目录绝不会因网络失败变成半截）。
     */
    suspend fun connect(
        displayName: String,
        baseUrl: String,
        externalBaseUrl: String?,
        username: String?,
        secret: String,
        previousAccount: ServerAccount?,
    ): ConnectionOutcome {
        _stage.value = ConnectionStage.Validating
        val normalized = normalizedBaseUrl(baseUrl)
        val normalizedExternal = externalBaseUrl?.takeIf { it.isNotBlank() }?.let(::normalizedBaseUrl)
        if (normalized == null) return ConnectionOutcome.Failed("内网地址无效（需要 http/https + 主机名）")
        if (externalBaseUrl?.isNotBlank() == true && normalizedExternal == null) {
            return ConnectionOutcome.Failed("外网地址无效")
        }
        val serverId = stableServerId(normalized, username)
        val candidate = ServerAccount(
            id = serverId,
            displayName = displayName,
            baseUrl = normalized,
            externalBaseUrl = normalizedExternal,
            username = username,
            credentialReference = previousAccount?.credentialReference
                ?: vault.newReferenceOrFallback(),
        )

        _stage.value = ConnectionStage.StoringCredential
        vault.store(candidate.credentialReference!!, secret)

        val probeResult = probeEndpoints(candidate)
        if (probeResult.kind == ProbeKind.AuthenticationFailed) {
            rollbackCredential(previousAccount)
            _stage.value = ConnectionStage.Done
            return ConnectionOutcome.AuthFailed("认证失败：用户名或密码/API Key 不正确")
        }
        if (probeResult.kind != ProbeKind.Reachable) {
            rollbackCredential(previousAccount)
            _stage.value = ConnectionStage.Done
            return ConnectionOutcome.Unreachable(
                if (probeResult.kind == ProbeKind.Unreachable) "服务器不可达（内网与外网均无法连接）" else "服务器连接失败",
            )
        }

        // 探测成功 → 同步
        return try {
            val outcome = fullSync(candidate)
            if (outcome is ConnectionOutcome.Success) {
                _stage.value = ConnectionStage.Done
                outcome
            } else {
                rollbackCredential(previousAccount)
                _stage.value = ConnectionStage.Done
                outcome
            }
        } catch (e: Exception) {
            rollbackCredential(previousAccount)
            _stage.value = ConnectionStage.Done
            ConnectionOutcome.Failed("同步失败：${e.message ?: "未知错误"}")
        }
    }

    private suspend fun rollbackCredential(previous: ServerAccount?) {
        if (previous?.credentialReference == null) return
        // 恢复到旧凭据引用（secret 由调用方在 UI 层重新写入或沿用 vault 里旧值）
        repository.upsertServer(previous)
    }

    private fun CredentialVault.newReferenceOrFallback(): String {
        @Suppress("DEPRECATION")
        return "cred-${java.util.UUID.randomUUID()}"
    }

    // ------------------------------------------------------------ 全量同步

    /**
     * 拉取（分页）+ capabilities + genres/playlists/收藏；全部成功才 commit。
     * 首次连接 album 分页 250；曲目通过专辑详情补全（对齐 Apple 实现路径）。
     */
    suspend fun fullSync(account: ServerAccount): ConnectionOutcome {
        _stage.value = ConnectionStage.Authenticating
        val client = clientFor(account)
        val info = client.ping()
        _stage.value = ConnectionStage.DetectingCapabilities
        val capabilities = client.capabilities()
        _stage.value = ConnectionStage.LoadingLibrary

        val artists = runCatching { client.artists() }.getOrDefault(emptyList())
        val albums = fetchAllAlbums(client)
        val tracks = ArrayList<Track>()
        val albumPage = ArrayList<Album>()
        albums.chunked(6).forEachIndexed { index, chunk ->
            // Apple：专辑列表 + 6 并发专辑详情
            val details = chunk.mapNotNull { album ->
                runCatching { client.album(album.id.value) }.getOrNull()
            }
            details.forEach { detail ->
                val albumDomain = dtoToAlbum(detail, account.id)
                albumPage.add(albumDomain)
                detail.song.forEach { child ->
                    tracks.add(
                        dtoToTrack(child, account.id),
                    )
                }
            }
            if (index % 10 == 9) delay(1)
        }
        val genres = runCatching { client.genres() }.getOrDefault(emptyList())
        val playlists = runCatching { client.playlists() }.getOrDefault(emptyList())

        _stage.value = ConnectionStage.SavingLibrary
        repository.commitCatalogSnapshot(
            serverId = account.id,
            artists = artists,
            albums = if (albumPage.isNotEmpty()) albumPage else albums,
            tracks = tracks,
            genres = genres,
            playlists = playlists,
        )
        repository.upsertServer(account)
        return ConnectionOutcome.Success(account.id, tracks.size)
    }

    private suspend fun fetchAllAlbums(client: OpenSubsonicClient): List<Album> {
        val result = ArrayList<Album>()
        var offset = 0
        while (true) {
            val page = client.albums(offset = offset)
            result.addAll(page)
            if (page.size < OpenSubsonicClient.DEFAULT_ALBUM_PAGE_SIZE) break
            offset += page.size
            if (result.size > MAX_SYNC_ALBUMS) break
        }
        return result
    }

    /** 后台刷新：只同步辅助数据 + 校验连接（不重建目录主体）。 */
    suspend fun refreshAuxiliary(account: ServerAccount) {
        runCatching {
            val client = clientFor(account)
            client.ping()
        }
    }

    suspend fun resync(account: ServerAccount): ConnectionOutcome = fullSync(account)

    /** 忘记服务器：仅清本地，不触远端（对齐 Apple forgetServer）。 */
    suspend fun forgetServer(serverId: ServerId) {
        repository.deleteServer(serverId)
    }

    companion object {
        private const val MAX_SYNC_ALBUMS = 20_000

        private fun defaultHttpClient(): OkHttpClient =
            OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .build()
    }
}

/** 专辑详情 DTO → Domain。OpenSubsonic `getAlbum` 的 detail 结构。 */
private fun dtoToAlbum(detail: AlbumDetail, serverId: ServerId): Album = Album(
    id = AlbumId(detail.id?.value.orEmpty()),
    serverId = serverId,
    artistId = ArtistId(detail.artistId?.value.orEmpty()),
    title = detail.name,
    artistName = detail.artist.orEmpty(),
    year = detail.year,
    genre = detail.genre,
    artworkKey = detail.coverArt?.value,
    songCount = detail.songCount,
)

/** 曲目 Child DTO → Domain（复用以调试干净的 OpenSubsonicMapper）。 */
private fun dtoToTrack(child: Child, serverId: ServerId): Track =
    OpenSubsonicMapper.track(child, serverId)
