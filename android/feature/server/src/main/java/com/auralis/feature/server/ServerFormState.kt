package com.auralis.feature.server

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.auralis.core.data.connector.ConnectionOutcome
import com.auralis.core.data.connector.ProductionServerConnector
import com.auralis.core.data.connector.ServerURLPolicy
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.domain.ServerAccount
import com.auralis.core.domain.ServerId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * 服务器添加/编辑表单状态（对齐 Swift `ServerConnectionSheet` / 编辑页）：
 * - 本地校验（必填 + URL 策略）先行，错误内联展示；
 * - 「测试连接」= core `testConnection`：**不保存凭据、不同步**，只回一行状态；
 * - 「保存」= 新增走 `connect`，编辑走 `edit`（身份稳定、密码留空沿用旧凭据），
 *   成功回调后由导航层关闭页面；失败显示分类错误并可展开详情。
 */
class ServerFormState(
    private val scope: CoroutineScope,
    private val graph: AuralisGraph,
    /** 非 null = 编辑既有服务器（身份保持稳定）。 */
    private val existing: ServerAccount? = null,
    private val onSuccess: (ServerId) -> Unit,
    private val onBack: () -> Unit,
) {
    val isEdit: Boolean = existing != null

    var displayName by mutableStateOf(existing?.displayName ?: "")
    var serverUrl by mutableStateOf(existing?.baseUrl ?: "")
    var externalUrl by mutableStateOf(existing?.externalBaseUrl ?: "")
    var username by mutableStateOf(existing?.username ?: "")
    var password by mutableStateOf("")

    /** 进行中的连接阶段标题（保存时跟随 connector.stage）。 */
    var busy by mutableStateOf(false)
    var busyLabel by mutableStateOf<String?>(null)
    var localError by mutableStateOf<String?>(null)
    var testUi by mutableStateOf<ServerTestUi?>(null)
    var isTesting by mutableStateOf(false)
    var failureMessage by mutableStateOf<String?>(null)
    var showErrorDetails by mutableStateOf(false)

    private var stageJob: Job? = null

    /** URL 是否可解析（客户端可保存性判断；真实策略校验在提交/测试时执行）。 */
    private fun isUrlParseable(raw: String): Boolean {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return false
        val withScheme = if (trimmed.contains("://")) trimmed else "https://$trimmed"
        val uri = runCatching { java.net.URI(withScheme) }.getOrNull() ?: return false
        return (uri.scheme == "http" || uri.scheme == "https") && uri.host != null
    }

    /** 底部「保存」可用性：核心字段填齐且没有进行中的连接/测试。 */
    fun canSave(): Boolean {
        if (busy || isTesting) return false
        if (displayName.trim().isEmpty()) return false
        if (!isUrlParseable(serverUrl)) return false
        if (username.trim().isEmpty()) return false
        // 新增必须输密码；编辑允许留空（沿用本机已存凭据）。
        if (!isEdit && password.isEmpty()) return false
        return true
    }

    /** 本地策略校验 → 错误文案；通过返回 null。 */
    private fun policyError(): String? {
        val urlTrimmed = serverUrl.trim()
        if (urlTrimmed.isEmpty() || !isUrlParseable(urlTrimmed)) {
            return "服务器地址无效，请包含 http:// 或 https://。"
        }
        ServerURLPolicy.validate(urlTrimmed)?.let { return it.message }
        val extTrimmed = externalUrl.trim()
        if (extTrimmed.isNotEmpty()) {
            if (!isUrlParseable(extTrimmed)) return "服务器地址无效，请包含 http:// 或 https://。"
            ServerURLPolicy.validate(extTrimmed)?.let { return it.message }
        }
        return null
    }

    /** 「测试连接」：只测不存。 */
    fun runTest() {
        if (isTesting || busy) return
        isTesting = true
        testUi = null
        localError = null
        scope.launch {
            val error = policyError()
            if (error != null) {
                localError = error
                isTesting = false
                return@launch
            }
            val result = graph.connector.testConnection(
                displayName = displayName.trim(),
                baseUrl = serverUrl.trim(),
                externalBaseUrl = externalUrl.trim().ifEmpty { null },
                username = username.trim().ifEmpty { null },
                secret = password,
            )
            testUi = result.toUi()
            isTesting = false
        }
    }

    /** 保存：新增 connect / 编辑 edit；成功后回调并清理。 */
    fun save() {
        if (!canSave()) return
        busy = true
        busyLabel = null
        localError = null
        failureMessage = null
        testUi = null
        stageJob = scope.launch {
            graph.connector.stage.collect { busyLabel = it.titleZh() }
        }
        scope.launch {
            try {
                val outcome = if (isEdit && existing != null) {
                    graph.connector.edit(
                        account = existing,
                        displayName = displayName.trim(),
                        baseUrl = serverUrl.trim(),
                        externalBaseUrl = externalUrl.trim().ifEmpty { null },
                        username = username.trim().ifEmpty { null },
                        secret = password.ifEmpty { null },
                    )
                } else {
                    graph.connector.connect(
                        displayName = displayName.trim(),
                        baseUrl = serverUrl.trim(),
                        externalBaseUrl = externalUrl.trim().ifEmpty { null },
                        username = username.trim().ifEmpty { null },
                        secret = password,
                        previousAccount = existing,
                    )
                }
                when (outcome) {
                    is ConnectionOutcome.Success -> {
                        graph.preferences.setActiveServerId(outcome.serverId.value)
                        finishBusy()
                        onSuccess(outcome.serverId)
                    }

                    is ConnectionOutcome.AuthFailed -> {
                        failureMessage = outcome.message
                        finishBusy()
                    }

                    is ConnectionOutcome.Unreachable -> {
                        failureMessage = outcome.message
                        finishBusy()
                    }

                    is ConnectionOutcome.Failed -> {
                        failureMessage = outcome.message
                        finishBusy()
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                failureMessage = "连接未完成：${e.message ?: "未知错误"}"
                finishBusy()
            }
        }
    }

    /** 取消/返回：连接进行中不可中断（core 连接是原子的，失败自动回滚），与 macOS 一致禁用。 */
    fun cancel() {
        if (busy || isTesting) return
        onBack()
    }

    private fun finishBusy() {
        stageJob?.cancel()
        stageJob = null
        busyLabel = null
        busy = false
    }
}
