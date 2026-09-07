package com.auralis.tv

import android.app.Application
import com.auralis.core.data.graph.AuralisGraph
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * Auralis TV（Android TV / Leanback）入口。
 * 与移动端共用同一组合根；TV 不装配 AI 助手（feature:assistant 未纳入依赖）。
 *
 * 冷启动必须恢复本地服务器注册表：Room 里的账户本身不足以播放/加载封面，stream、
 * cover art、lyrics、search 等远程能力都从 ServerClientRegistry 取当前端点。
 * 下载水合也必须等注册表先恢复，避免恢复任务刚启动就因“无客户端”生成不了 URL。
 */
class AuralisTvApp : Application() {
    lateinit var graph: AuralisGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AuralisGraph(this)
        graph.install()

        val downloads = graph.downloadManager
        graph.appScope.launch {
            runCatching { graph.bootstrapFromLocal() }
            runCatching { downloads.hydrate { gid -> graph.catalogRepository.track(gid) } }
        }

        // TV 端同样允许从 Library / Now Playing 发起下载；存在任务时保持前台服务。
        graph.appScope.launch {
            var serviceRequested = false
            downloads.activeCount.collect { count ->
                if (count > 0 && !serviceRequested) {
                    serviceRequested = true
                    runCatching { graph.startDownloadService() }
                } else if (count == 0) {
                    serviceRequested = false
                }
            }
        }
    }
}
