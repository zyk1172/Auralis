// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.server

import androidx.annotation.StringRes
import com.auralis.core.data.connector.ConnectionStage
import com.auralis.core.data.connector.TestConnectionResult
import com.auralis.core.designsystem.R as AuralisR

/** 表单「测试连接」结果 → 一行可读状态（对齐 Swift statusLabel）。 */
sealed interface ServerTestUi {
    data object Success : ServerTestUi
    data object AuthenticationFailed : ServerTestUi
    data object Unreachable : ServerTestUi
    data class Failed(val message: String) : ServerTestUi
}

/** 连接进度阶段标题资源（对齐 Swift ServerConnectionStage.title；由持有 Context 方解析）。 */
fun ConnectionStage.titleRes(): Int = when (this) {
    ConnectionStage.Idle -> R.string.server_stage_idle
    ConnectionStage.Validating -> R.string.server_stage_validating
    ConnectionStage.StoringCredential -> R.string.server_stage_storing_credential
    ConnectionStage.Authenticating -> R.string.server_stage_authenticating
    ConnectionStage.DetectingCapabilities -> R.string.server_stage_capabilities
    ConnectionStage.LoadingLibrary -> R.string.server_stage_loading_library
    ConnectionStage.SavingLibrary -> R.string.server_stage_saving_library
    ConnectionStage.Done -> AuralisR.string.done
}

/** core 测试结果 → UI 可读分类。 */
fun TestConnectionResult.toUi(): ServerTestUi = when (this) {
    is TestConnectionResult.Success -> ServerTestUi.Success
    TestConnectionResult.AuthenticationFailed -> ServerTestUi.AuthenticationFailed
    is TestConnectionResult.Failed -> ServerTestUi.Failed(message)
}

/**
 * 脱敏显示服务器地址：只显示 scheme + host + port（对齐 Swift maskedURL），
 * 不含路径参数与认证信息。
 */
fun maskedUrl(url: String?): String {
    if (url.isNullOrBlank()) return ""
    val withScheme = if (url.contains("://")) url else "https://$url"
    val uri = runCatching { java.net.URI(withScheme) }.getOrNull() ?: return url
    val scheme = uri.scheme ?: return url
    val host = uri.host ?: return url
    val port = if (uri.port >= 0) ":${uri.port}" else ""
    return "$scheme://$host$port"
}
