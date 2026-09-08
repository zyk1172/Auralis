// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.server

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.auralis.core.data.connector.EndpointKind
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.domain.ServerAccount
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * 服务器列表状态（对齐 macOS `MacServerPage`）：
 * - 已保存服务器摘要（显示名 + 脱敏地址 + 当前激活勾选 + 实际路由端点标签）；
 * - 点行 = 切换当前服务器；行内 编辑 / 删除（删除需二次确认，且只删本地）；
 * - 空状态引导添加第一台服务器。
 * 模型层文案经 [context] 从资源解析（R5：UI 文案不硬编码中文）。
 */
class ServerListState(
    private val context: Context,
    private val scope: CoroutineScope,
    private val graph: AuralisGraph,
    private val onAdd: () -> Unit,
    private val onEdit: (ServerAccount) -> Unit,
    private val onEnter: () -> Unit,
) {
    var servers by mutableStateOf<List<ServerAccount>>(emptyList())
        private set
    var activeServerId by mutableStateOf<String?>(null)
        private set
    var loaded by mutableStateOf(false)
        private set
    var pendingDelete by mutableStateOf<ServerAccount?>(null)
        private set
    var lastError by mutableStateOf<String?>(null)
        private set

    fun load() {
        scope.launch {
            runCatching {
                servers = graph.catalogRepository.servers()
                activeServerId = graph.preferences.activeServerIdValue()
            }.onFailure {
                lastError = context.getString(R.string.server_load_failed, it.message ?: "")
            }
            loaded = true
        }
    }

    /** 该服务器当前实际路由到的端点标签（内网/外网/未连接）。 */
    fun routeLabel(account: ServerAccount): String? = when (graph.connector.registry.kind(account.id)) {
        EndpointKind.Internal -> context.getString(R.string.server_route_internal)
        EndpointKind.External -> context.getString(R.string.server_route_external)
        null -> null
    }

    /** 点行切换当前服务器；若已有任何服务器则进入主界面。 */
    fun switchTo(account: ServerAccount) {
        scope.launch { graph.preferences.setActiveServerId(account.id.value) }
        activeServerId = account.id.value
        onEnter()
    }

    /** 空状态下的添加按钮。 */
    fun add() = onAdd()

    /** 行内编辑。 */
    fun edit(account: ServerAccount) = onEdit(account)

    /** 请求删除：弹确认框（不立即删）。 */
    fun requestDelete(account: ServerAccount) {
        pendingDelete = account
    }

    fun dismissDelete() {
        pendingDelete = null
    }

    /** 确认删除：只删本地（目录/凭据/客户端），远端不受影响。 */
    fun confirmDelete() {
        val target = pendingDelete ?: return
        pendingDelete = null
        scope.launch {
            val next = graph.forgetServer(target.id)
            activeServerId = next?.value
            servers = graph.catalogRepository.servers()
        }
    }
}
