// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import android.content.Context
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.auralis.core.domain.PlaybackSourceResolver

/**
 * 播放长期单例主线。
 *
 * 对应 Apple 长期复用同一个 AVQueuePlayer + AudioSession 的做法：
 * - 本服务持有**单个 ExoPlayer**（进程内 [LocalPlaybackHost.engine]）；
 * - 通过 MediaSession 接通系统媒体控制：通知栏 / 锁屏 / 蓝牙耳机 / 媒体按键；
 * - 播放独立于 Activity 生命周期：切后台、熄屏、Activity 被回收、TV 页面切换均继续。
 *
 * 服务生命周期仍以 MediaSessionService 为权威：任务被划掉时沿用 Media3 默认策略
 * （正在播放则保留，非持续播放状态可停止）；服务真正销毁时必须释放 Player/Session，
 * 并清空进程内 Host，避免留下“available=true 但已无 MediaSessionService”的僵尸引擎。
 */
class AuralisPlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val engine = LocalPlaybackHost.engine ?: run {
            val created = PlaybackEngineFactory.create(
                applicationContext,
                PlaybackDependencies.requireResolver(),
                PlaybackDependencies.historySink(),
            )
            LocalPlaybackHost.engine = created
            created
        }
        mediaSession = MediaSession.Builder(this, engine.player)
            .setId(SESSION_ID)
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onDestroy() {
        // 先让所有 UI/Agent 观察者看到“引擎不可用”，阻止新命令继续落到正在销毁的 Player。
        val engine = LocalPlaybackHost.engine
        LocalPlaybackHost.clear()

        engine?.release()
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }

    companion object {
        const val SESSION_ID = "auralis.playback"
    }
}

/** 引擎装配依赖注入点（由各 App 的 Application 在启动时调用一次）。 */
object PlaybackDependencies {
    @Volatile
    private var resolver: PlaybackSourceResolver? = null

    @Volatile
    private var historySink: PlaybackHistorySink? = null

    fun install(resolver: PlaybackSourceResolver, historySink: PlaybackHistorySink?) {
        this.resolver = resolver
        this.historySink = historySink
    }

    internal fun requireResolver(): PlaybackSourceResolver =
        checkNotNull(resolver) { "PlaybackDependencies.install() 必须在 Application.onCreate 调用" }

    internal fun historySink(): PlaybackHistorySink? = historySink

    internal fun context(): Context? = null
}
