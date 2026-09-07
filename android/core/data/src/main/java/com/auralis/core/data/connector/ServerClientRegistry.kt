package com.auralis.core.data.connector

import com.auralis.core.domain.ServerAccount
import com.auralis.core.domain.ServerId
import com.auralis.core.opensubsonic.CredentialVault
import com.auralis.core.opensubsonic.OpenSubsonicAuthentication
import com.auralis.core.opensubsonic.OpenSubsonicClient
import com.auralis.core.opensubsonic.OpenSubsonicConfiguration
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient

/** 端点类型：探测/使用中实际选中的地址类别。 */
enum class EndpointKind { Internal, External }

/**
 * 探测/连接后**实际被选中**的服务器端点。此后一切远程操作
 * （sync / resync / stream / download / cover art / lyrics / star / rating /
 * playlist mutation / search / scrobble / similar）都从这里按 serverID 取客户端，
 * 不允许再「默认用内网地址重建 client」。
 *
 * 对应 Apple `selectAuthenticatedClient` 返回的 `(client, serverInfo)`。
 */
data class ResolvedServerEndpoint(
    val serverId: ServerId,
    /** 选中且归一化后的地址（内网或外网）。 */
    val baseUrl: String,
    val kind: EndpointKind,
    val client: OpenSubsonicClient,
)

/**
 * 进程级服务器客户端注册表。
 *
 * serverID → 当前真正可用的 [ResolvedServerEndpoint]。
 *
 * 为什么不是缓存：Apple 侧 `clients[serverID]` 由 ServerConnector 在成功
 * connect/resync 后写入；服务器新增/编辑/删除后注册表随之更新——Graph 与所有
 * 消费者**只**读注册表，不维护第二份易漂移的 ServerAccount 快照。
 */
class ServerClientRegistry(
    private val vault: CredentialVault,
    private val http: OkHttpClient = defaultHttpClient(),
) {
    private val endpoints = ConcurrentHashMap<String, ResolvedServerEndpoint>()

    /** 按 serverID 取当前选中端点；未连接/已删除返回 null。 */
    fun resolve(serverId: ServerId): ResolvedServerEndpoint? = endpoints[serverId.value]

    /** 按 serverID 取当前可用客户端（无则 null）。 */
    fun client(serverId: ServerId): OpenSubsonicClient? = endpoints[serverId.value]?.client

    /** 当前是否把该服务器路由到外网。 */
    fun kind(serverId: ServerId): EndpointKind? = endpoints[serverId.value]?.kind

    /** 由探测/连接成功后登记真实端点。 */
    fun registerResolved(endpoint: ResolvedServerEndpoint) {
        endpoints[endpoint.serverId.value] = endpoint
    }

    /** 删除服务器后注销。 */
    fun remove(serverId: ServerId) {
        endpoints.remove(serverId.value)
    }

    // ------------------------------------------------------- 构造（不登记）

    /**
     * 构造内网客户端。冷启动「先用内网，后台探测再切换」的默认路径；
     * 不写入注册表，由调用方决定何时 registerResolved。
     */
    fun makeInternalEndpoint(account: ServerAccount): ResolvedServerEndpoint {
        val base = requireNotNull(account.baseUrl) { "服务器缺少内网地址" }
        return ResolvedServerEndpoint(
            serverId = account.id,
            baseUrl = base,
            kind = EndpointKind.Internal,
            client = makeClient(base, account),
        )
    }

    /** 构造外网客户端（仅当账户有外网地址）。 */
    fun makeExternalEndpoint(account: ServerAccount): ResolvedServerEndpoint {
        val base = requireNotNull(account.externalBaseUrl) { "服务器没有外网地址" }
        return ResolvedServerEndpoint(
            serverId = account.id,
            baseUrl = base,
            kind = EndpointKind.External,
            client = makeClient(base, account),
        )
    }

    private fun makeClient(baseUrl: String, account: ServerAccount): OpenSubsonicClient {
        val credential = requireNotNull(account.credentialReference) { "缺少凭据引用" }
        val uname = account.username
        val auth = if (uname.isNullOrBlank()) {
            OpenSubsonicAuthentication.ApiKey(credential)
        } else {
            OpenSubsonicAuthentication.Token(username = uname, credentialReference = credential)
        }
        return OpenSubsonicClient(
            OpenSubsonicConfiguration(baseUrl, account.id, auth),
            http,
            vault,
        )
    }

    companion object {
        fun defaultHttpClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .build()
    }
}
