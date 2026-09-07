package com.auralis.feature.server

import com.auralis.core.data.connector.ConnectionStage
import com.auralis.core.data.connector.TestConnectionResult

/** 表单「测试连接」结果 → 一行可读状态（对齐 Swift statusLabel）。 */
sealed interface ServerTestUi {
    data object Success : ServerTestUi
    data object AuthenticationFailed : ServerTestUi
    data object Unreachable : ServerTestUi
    data class Failed(val message: String) : ServerTestUi
}

/** 连接进度阶段的可读标题（对齐 Swift ServerConnectionStage.title）。 */
fun ConnectionStage.titleZh(): String = when (this) {
    ConnectionStage.Idle -> "就绪"
    ConnectionStage.Validating -> "检查地址"
    ConnectionStage.StoringCredential -> "保护凭据"
    ConnectionStage.Authenticating -> "验证服务器"
    ConnectionStage.DetectingCapabilities -> "检测能力"
    ConnectionStage.LoadingLibrary -> "读取音乐库"
    ConnectionStage.SavingLibrary -> "保存资料库"
    ConnectionStage.Done -> "完成"
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
