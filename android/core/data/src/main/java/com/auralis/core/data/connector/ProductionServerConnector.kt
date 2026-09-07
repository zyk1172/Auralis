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
import com.auralis.core.opensubsonic.OpenSubsonicClient
import com.auralis.core.opensubsonic.OpenSubsonicError
import com.auralis.core.opensubsonic.OpenSubsonicException
import com.auralis.core.opensubsonic.OpenSubsonicMapper
import com.auralis.core.opensubsonic.AlbumDetail
import com.auralis.core.opensubsonic.Child
import com.auralis.core.domain.AlbumId
import com.auralis.core.domain.ArtistId
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/** 端点探测原始结果。Apple 语义：Transport/5xx → 不可达；认证错误绝不当作断网。 */
enum class ProbeKind { Reachable, Unreachable, AuthenticationFailed, Failed }

data class ProbeResult(val kind: ProbeKind, val serverInfo: com.auralis.core.opensubsonic.ServerInfo? = null)

/**
 * 端点选择结果：成功后携带**实际被选中**的端点（内网或外网）。
 * 之后的一切远程操作都必须使用 `endpoint.client`，禁止再默认重建内网 client。
 */
sealed interface EndpointSelection {
    data class Reachable(
        val endpoint: ResolvedServerEndpoint,
        val serverInfo: com.auralis.core.opensubsonic.ServerInfo? = null,
    ) : EndpointSelection

    /** 认证/授权失败：绝不降级切外网。 */
    data object AuthenticationFailed : EndpointSelection

    /** 内外网均不可达（transport/408/5xx）。 */
    data object Unreachable : EndpointSelection

    /** 协议错误 / 未知失败。 */
    data class Failed(val message: String) : EndpointSelection
}

enum class ConnectionStage {
    Idle, Validating, StoringCredential, Authenticating,
    DetectingCapabilities, LoadingLibrary, SavingLibrary, Done,
}

sealed interface ConnectionOutcome {
    data class Success(val serverId: ServerId, val trackCount: Int) : ConnectionOutcome
    data class AuthFailed(val message: String) : ConnectionOutcome
    data class Unreachable(val message: String) : ConnectionOutcome
    data class Failed(val message: String) : ConnectionOutcome
}

/**
 * 服务器连接编排层（对应 Apple `ProductionServerConnector`）。
 *
 * 语义对齐点：
 * 1. **凭据引用固定**为 `opensubsonic.{serverId}`（Apple credentialID），不再随机生成；
 *    连接前读取 previousSecret，失败时 store 回旧 secret；本次全新则 delete 新凭据。
 * 2. **端点选择**：`selectEndpoint` 只在「内网不可达」时才试外网；内网认证失败/
 *    协议错误直接失败（不偷偷切外网）。成功路径返回选中端点并由 [registry] 登记，
 *    之后 sync / resync / stream / download / cover / lyrics / star / rating /
 *    playlist / search / scrobble / similar 全部从注册表取 client。
 * 3. **失败补偿**：逆序恢复（catalog → 凭据），尽力恢复不再抛，避免掩盖原始错误。
 * 4. **目录提交**：全量拉取完成后才 `commitCatalogSnapshot`（单事务）；失败保留旧目录。
 */
class ProductionServerConnector(
    private val vault: CredentialVault,
    private val repository: RoomCatalogRepository,
    private val http: OkHttpClient = ServerClientRegistry.defaultHttpClient(),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _stage = MutableStateFlow(ConnectionStage.Idle)
    val stage: StateFlow<ConnectionStage> = _stage.asStateFlow()

    /** 进程级客户端注册表：成功后登记端点，所有消费者只从这里取 client。 */
    val registry = ServerClientRegistry(vault, http)

    // ------------------------------------------------------------------ 装配

    fun clientFor(account: ServerAccount, external: Boolean = false): OpenSubsonicClient =
        registry.run {
            (if (external) runCatching { makeExternalEndpoint(account) }.getOrNull()
            else runCatching { makeInternalEndpoint(account) }.getOrNull())
                ?.client
                ?: registry.makeInternalEndpoint(account).client
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
     * 端点选择（Apple `selectAuthenticatedClient`）：
     * - 内网可达 → 内网；
     * - 内网**认证/协议失败** → 直接失败，不切外网（避免「密码错」被当断网）；
     * - 内网不可达（transport/5xx/超时）且配置了外网 → 试外网。
     */
    suspend fun selectEndpoint(account: ServerAccount): EndpointSelection {
        val internalEndpoint = registry.makeInternalEndpoint(account)
        val internalResult = probe(internalEndpoint)
        when (internalResult.kind) {
            ProbeKind.Reachable -> {
                return EndpointSelection.Reachable(internalEndpoint, internalResult.serverInfo)
            }

            ProbeKind.AuthenticationFailed, ProbeKind.Failed -> {
                return if (internalResult.kind == ProbeKind.AuthenticationFailed) {
                    EndpointSelection.AuthenticationFailed
                } else {
                    EndpointSelection.Failed("内网连接失败（协议错误）")
                }
            }

            ProbeKind.Unreachable -> {
                val external = runCatching { registry.makeExternalEndpoint(account) }.getOrNull()
                    ?: return EndpointSelection.Unreachable
                val externalResult = probe(external)
                return when (externalResult.kind) {
                    ProbeKind.Reachable -> EndpointSelection.Reachable(external, externalResult.serverInfo)
                    ProbeKind.AuthenticationFailed, ProbeKind.Failed ->
                        if (externalResult.kind == ProbeKind.AuthenticationFailed) {
                            EndpointSelection.AuthenticationFailed
                        } else {
                            EndpointSelection.Failed("外网连接失败（协议错误）")
                        }

                    ProbeKind.Unreachable -> EndpointSelection.Unreachable
                }
            }
        }
    }

    suspend fun probeEndpoints(account: ServerAccount): ProbeResult = when (val s = selectEndpoint(account)) {
        is EndpointSelection.Reachable -> ProbeResult(ProbeKind.Reachable, s.serverInfo)
        EndpointSelection.AuthenticationFailed -> ProbeResult(ProbeKind.AuthenticationFailed)
        EndpointSelection.Unreachable -> ProbeResult(ProbeKind.Unreachable)
        is EndpointSelection.Failed -> ProbeResult(ProbeKind.Failed)
    }

    suspend fun probe(endpoint: ResolvedServerEndpoint): ProbeResult = try {
        val info = endpoint.client.ping()
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
     * 连接（新增或编辑）。
     *
     * @param previousAccount 编辑场景的旧账户；null 表示全新服务器。其值仅用于失败补偿
     *   （恢复旧账户 / 判断是否需要 purge），地址/凭据总是以本次输入为准。
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
        val credentialRef = credentialReferenceFor(serverId)

        // R12 前置快照（严格读取）：区分「确实没有旧密码」与「读取失败」。
        val previousSecret = vault.retrieve(credentialRef)
        val candidate = ServerAccount(
            id = serverId,
            displayName = displayName,
            baseUrl = normalized,
            externalBaseUrl = normalizedExternal,
            username = username,
            credentialReference = credentialRef,
        )

        // 先写新凭据再认证（Apple 顺序：storingCredential → authenticating）。
        _stage.value = ConnectionStage.StoringCredential
        vault.store(credentialRef, secret)

        val selection = selectEndpoint(candidate)
        return when (selection) {
            is EndpointSelection.Reachable -> {
                val outcome = try {
                    syncOnEndpoint(selection.endpoint, candidate)
                } catch (e: Exception) {
                    rollback(serverId, credentialRef, previousSecret, previousAccount)
                    _stage.value = ConnectionStage.Done
                    return ConnectionOutcome.Failed("同步失败：${e.message ?: "未知错误"}")
                }
                if (outcome is ConnectionOutcome.Success) {
                    _stage.value = ConnectionStage.Done
                    outcome
                } else {
                    rollback(serverId, credentialRef, previousSecret, previousAccount)
                    _stage.value = ConnectionStage.Done
                    outcome
                }
            }

            EndpointSelection.AuthenticationFailed -> {
                rollback(serverId, credentialRef, previousSecret, previousAccount)
                _stage.value = ConnectionStage.Done
                ConnectionOutcome.AuthFailed("认证失败：用户名或密码/API Key 不正确")
            }

            EndpointSelection.Unreachable -> {
                rollback(serverId, credentialRef, previousSecret, previousAccount)
                _stage.value = ConnectionStage.Done
                ConnectionOutcome.Unreachable("服务器不可达（内网与外网均无法连接）")
            }

            is EndpointSelection.Failed -> {
                rollback(serverId, credentialRef, previousSecret, previousAccount)
                _stage.value = ConnectionStage.Done
                ConnectionOutcome.Failed(selection.message)
            }
        }
    }

    /**
     * 全量同步 + 提交 + 登记客户端（以**已选中**端点执行）。
     * 收藏回流：以 getStarred2 完整集合写回 favorites（对齐 Apple connect 尾部）。
     */
    private suspend fun syncOnEndpoint(
        endpoint: ResolvedServerEndpoint,
        account: ServerAccount,
    ): ConnectionOutcome {
        val client = endpoint.client
        _stage.value = ConnectionStage.Authenticating
        client.ping()
        _stage.value = ConnectionStage.DetectingCapabilities
        runCatching { client.capabilities() }
        _stage.value = ConnectionStage.LoadingLibrary

        val artists = runCatching { client.artists() }.getOrDefault(emptyList())
        val albums = fetchAllAlbums(client)
        val tracks = ArrayList<Track>()
        val albumPage = ArrayList<Album>()
        albums.chunked(6).forEachIndexed { index, chunk ->
            // Apple：专辑列表 + 6 并发专辑详情补全曲目。
            val details = chunk.mapNotNull { album ->
                runCatching { client.album(album.id.value) }.getOrNull()
            }
            details.forEach { detail ->
                val albumDomain = dtoToAlbum(detail, account.id)
                albumPage.add(albumDomain)
                detail.song.forEach { child ->
                    tracks.add(dtoToTrack(child, account.id))
                }
            }
            if (index % 10 == 9) delay(1)
        }
        val genres = runCatching { client.genres() }.getOrDefault(emptyList())
        val playlists = runCatching { client.playlists() }.getOrDefault(emptyList())
        // 服务器收藏回流：失败不阻断主流程，保留本地现状。
        val starredIds = runCatching { client.starred().song.mapNotNull { it.id?.value } }.getOrDefault(emptyList())

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
        if (starredIds.isNotEmpty()) {
            repository.replaceFavoriteTracks(account.id, starredIds)
        }
        // 登记当前真正可用的客户端 → 后续 stream/download/cover/lyrics/star 全走它。
        registry.registerResolved(endpoint)
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

    /** 后台校验连接：只 ping 当前选中端点，不重建目录。 */
    suspend fun refreshAuxiliary(account: ServerAccount) {
        val client = registry.client(account.id) ?: runCatching {
            registry.makeInternalEndpoint(account).also { registry.registerResolved(it) }.client
        }.getOrNull() ?: return
        runCatching { client.ping() }
    }

    /** 重新同步：沿用注册表中当前选中端点（外网路由同样生效）。 */
    suspend fun resync(account: ServerAccount): ConnectionOutcome {
        val endpoint = registry.resolve(account.id) ?: runCatching {
            registry.makeInternalEndpoint(account).also { registry.registerResolved(it) }
        }.getOrNull() ?: return ConnectionOutcome.Failed("服务器尚未连接")
        return try {
            syncOnEndpoint(endpoint, account)
        } catch (e: Exception) {
            ConnectionOutcome.Failed("同步失败：${e.message ?: "未知错误"}")
        }
    }

    /**
     * 忘记服务器：删除本地 server-scoped 目录 + 注销客户端 + 删除安全凭据。
     * 不触远端 Navidrome。active server 切换由调用方（UI/组合根）负责。
     */
    suspend fun forgetServer(serverId: ServerId) {
        registry.remove(serverId)
        repository.deleteServer(serverId)
        runCatching { vault.delete(credentialReferenceFor(serverId)) }
    }

    // ------------------------------------------------------------------ 补偿

    /**
     * 失败补偿（尽力恢复，恢复动作失败只记日志不掩盖原始错误）：
     * 1. 恢复 catalog：有旧账户 → 还原；无旧账户（本次新增失败）→ purge 该 server 残留，
     *    不留 orphan server / 半同步目录；
     * 2. 恢复凭据：有 previousSecret → 写回；全新 reference → delete。
     */
    private suspend fun rollback(
        serverId: ServerId,
        credentialRef: String,
        previousSecret: String?,
        previousAccount: ServerAccount?,
    ) {
        if (previousAccount != null) {
            runCatching { repository.upsertServer(previousAccount) }
        } else {
            runCatching { repository.deleteServer(serverId) }
        }
        if (previousSecret != null) {
            runCatching { vault.store(credentialRef, previousSecret) }
        } else {
            runCatching { vault.delete(credentialRef) }
        }
    }

    companion object {
        private const val MAX_SYNC_ALBUMS = 20_000

        /** 凭据引用固定格式（对齐 Apple `opensubsonic.{serverID}`）。 */
        fun credentialReferenceFor(serverId: ServerId): String = "opensubsonic.${serverId.value}"
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
