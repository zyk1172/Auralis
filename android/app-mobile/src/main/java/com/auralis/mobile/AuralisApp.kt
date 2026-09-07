package com.auralis.mobile

import android.app.Application
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.playback.PlaybackDependencies
import com.auralis.core.offline.DownloadServiceHolder
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * Auralis 移动端 Application：进程级组合根。
 * 单一目录/单一连接器/单一播放引擎，避免 split-brain（对齐 Apple ApplicationComposition）。
 *
 * 启动**不做任何网络门槛**：
 * 1. 先装配本地（Room/DataStore），UI 立刻可用；
 * 2. 后台水合下载任务（走同一三并发调度器，不会同时 launch 上百任务）；
 * 3. activeCount 0→1 时才拉起下载前台服务，归零由服务自行 stopSelf。
 */
class AuralisApp : Application() {
    lateinit var graph: AuralisGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AuralisGraph(this)
        graph.install()
        // 播放引擎依赖注入：resolver + 历史/scrobble sink（服务创建引擎时使用）。
        PlaybackDependencies.install(graph.playbackResolver, graph.historyCoordinator)

        val downloads = graph.downloadManager
        DownloadServiceHolder.manager = downloads
        DownloadServiceHolder.initialized = true

        graph.appScope.launch {
            runCatching { graph.bootstrapFromLocal() }
            runCatching { downloads.hydrate { gid -> graph.catalogRepository.track(gid) } }
        }

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
