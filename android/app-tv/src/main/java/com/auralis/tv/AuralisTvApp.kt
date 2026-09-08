// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import android.app.Application
import com.auralis.core.data.graph.AuralisGraph

/**
 * Auralis TV（Android TV / Leanback）入口。
 * 与移动端共用同一组合根；TV 不装配 AI 助手（feature:assistant 未纳入依赖）。
 */
class AuralisTvApp : Application() {
    lateinit var graph: AuralisGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AuralisGraph(this)
        graph.install()
    }
}
