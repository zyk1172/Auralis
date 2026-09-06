package com.auralis.mobile

import android.app.Application
import com.auralis.core.data.graph.AuralisGraph

/**
 * Auralis 移动端 Application：进程级组合根。
 * 单一目录/单一连接器/单一播放引擎，避免 split-brain（对齐 Apple ApplicationComposition）。
 */
class AuralisApp : Application() {
    lateinit var graph: AuralisGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AuralisGraph(this)
        graph.install()
    }
}
