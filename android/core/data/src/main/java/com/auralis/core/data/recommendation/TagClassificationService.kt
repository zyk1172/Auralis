// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.data.recommendation

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.auralis.core.data.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** User-started dataSync foreground service, including an always available Pause notification action. */
class TagClassificationService : Service() {
    companion object {
        @Volatile internal var manager: TagClassificationManager? = null
        private const val CHANNEL = "tag-classification"
        private const val NOTIFICATION = 7312
        private const val PAUSE = "auralis.classification.PAUSE"
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var observation: Job? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val controller = manager
        if (intent?.action == PAUSE || controller == null) {
            controller?.pause(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); return START_NOT_STICKY
        }
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, getString(R.string.classification_title), NotificationManager.IMPORTANCE_LOW))
        val pause = PendingIntent.getService(this, 0, Intent(this, javaClass).setAction(PAUSE), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun notification(text: String) = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(getString(R.string.classification_title)).setContentText(text).setOngoing(true)
            .addAction(Notification.Action.Builder(null, getString(R.string.classification_pause), pause).build()).build()
        val initial = notification(getString(R.string.classification_running))
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, initial, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NOTIFICATION, initial)
        } catch (error: Exception) {
            controller.serviceStartFailed(error); stopSelf(); return START_NOT_STICKY
        }
        controller.runFromService()
        observation?.cancel()
        observation = scope.launch {
            controller.state.collect { state ->
                if (!state.isRunning) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
                else notifications.notify(NOTIFICATION, notification(state.error ?: getString(R.string.classification_progress, state.indexedTracks, state.totalTracks)))
            }
        }
        return START_NOT_STICKY
    }
    override fun onTimeout(startId: Int, fgsType: Int) { manager?.pause(); stopSelf() }
    override fun onDestroy() {
        manager?.takeIf { it.state.value.isRunning }?.pause()
        scope.cancel(); super.onDestroy()
    }
}
