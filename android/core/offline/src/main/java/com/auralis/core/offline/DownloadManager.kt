// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.offline

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.auralis.core.domain.DownloadRecord
import com.auralis.core.domain.DownloadRepository
import com.auralis.core.domain.DownloadStatus
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.Track
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.OkHttpClient
import okhttp3.Request

sealed interface DownloadFailureKind {
    data object NetworkUnavailable : DownloadFailureKind
    data object TimedOut : DownloadFailureKind
    data object Authentication : DownloadFailureKind
    data object Unavailable : DownloadFailureKind
    data object InvalidResponse : DownloadFailureKind
    data object Storage : DownloadFailureKind
    data object Interrupted : DownloadFailureKind
    data object Unknown : DownloadFailureKind
}

data class DownloadFailure(val kind: DownloadFailureKind, val message: String)

/** Background downloader. Completed server tracks are promoted into LocalMusic/downloads. */
class DownloadManager(
    private val context: Context,
    private val downloads: DownloadRepository,
    private val urlFactory: suspend (Track) -> String?,
    private val okHttp: OkHttpClient = defaultOkHttpClient(),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val promotionStore = DownloadPromotionStore(context)
    private val cacheDir = prepareLocalMusicDownloadDirectory(context)
    private val stagingDir = File(context.filesDir, STAGING_DIR_NAME).apply { mkdirs() }

    private val activeTasks = ConcurrentHashMap<String, Job>()
    private val tombstones = ConcurrentHashMap.newKeySet<String>()
    private val semaphore = Semaphore(MAX_CONCURRENT_DOWNLOADS)
    private val runningKeys = ConcurrentHashMap.newKeySet<String>()
    private val pendingQueue = ConcurrentLinkedQueue<Pair<String, Track>>()
    private val _activeCount = MutableStateFlow(0)
    private val _runningCount = MutableStateFlow(0)
    private val _failures = MutableStateFlow<Map<String, DownloadFailure>>(emptyMap())

    val activeCount: StateFlow<Int> = _activeCount.asStateFlow()
    val runningCount: StateFlow<Int> = _runningCount.asStateFlow()
    val failures: StateFlow<Map<String, DownloadFailure>> = _failures.asStateFlow()

    suspend fun enqueue(track: Track) {
        val gid = track.globalId
        val key = gid.serialized
        if (activeTasks.containsKey(key)) return
        downloads.record(DownloadRecord(gid, DownloadStatus.Queued, 0f, null))
        submit(key, track)
    }

    fun cancel(gid: GlobalId) {
        val key = gid.serialized
        tombstones.add(key)
        activeTasks.remove(key)?.cancel()
        scope.launch {
            downloads.record(DownloadRecord(gid, DownloadStatus.NotDownloaded, 0f, null))
            downloads.remove(gid)
            cacheFor(gid)?.delete()
            promotionStore.remove(gid)
            stagingFor(key).delete()
        }
    }

    fun cancelDownloadOnly(gid: GlobalId) {
        val key = gid.serialized
        tombstones.add(key)
        activeTasks.remove(key)?.cancel()
        scope.launch {
            downloads.record(DownloadRecord(gid, DownloadStatus.NotDownloaded, 0f, null))
            downloads.remove(gid)
            stagingFor(key).delete()
        }
    }

    fun deleteCached(gid: GlobalId) {
        cacheFor(gid).delete()
        promotionStore.remove(gid)
        scope.launch { downloads.remove(gid) }
    }

    fun localCachePath(gid: GlobalId): String? {
        val file = cacheFor(gid)
        return if (file.exists() && file.length() > 0) file.absolutePath else null
    }

    fun canonicalLocalId(gid: GlobalId): GlobalId? = promotionStore.canonicalLocalId(gid)
    fun promotedMappings(): Map<GlobalId, GlobalId> = promotionStore.mappings()

    suspend fun hydrate(trackFor: suspend (GlobalId) -> Track?) {
        downloads.observeAll(null).first().forEach { record ->
            when (record.status) {
                DownloadStatus.Queued, DownloadStatus.Downloading -> {
                    val track = trackFor(record.globalId)
                    if (track != null && !activeTasks.containsKey(record.globalId.serialized)) {
                        downloads.record(DownloadRecord(record.globalId, DownloadStatus.Queued, 0f, null))
                        submit(record.globalId.serialized, track)
                    } else {
                        downloads.record(
                            DownloadRecord(
                                record.globalId,
                                DownloadStatus.Failed,
                                0f,
                                null,
                                updatedAtMillis = System.currentTimeMillis(),
                            ),
                        )
                    }
                }
                DownloadStatus.Downloaded -> {
                    // Migrate identities for downloads created before this feature.
                    if (localCachePath(record.globalId) != null) promotionStore.promote(record.globalId)
                }
                else -> Unit
            }
        }
    }

    fun release() {
        scope.cancel()
    }

    private fun submit(key: String, track: Track) {
        if (tombstones.contains(key)) tombstones.remove(key)
        if (activeTasks.containsKey(key)) return
        pendingQueue.add(key to track)
        val job = scope.launch {
            semaphore.withPermit {
                runningKeys.add(key)
                _runningCount.value = runningKeys.size
                try {
                    if (!tombstones.contains(key)) runDownload(key, track)
                } finally {
                    runningKeys.remove(key)
                    _runningCount.value = runningKeys.size
                }
            }
        }
        activeTasks[key] = job
        _activeCount.value = activeTasks.size
        job.invokeOnCompletion {
            activeTasks.remove(key)
            _activeCount.value = activeTasks.size
            pendingQueue.removeAll { it.first == key }
        }
    }

    private suspend fun runDownload(key: String, track: Track) {
        val gid = track.globalId
        val staging = stagingFor(key)
        staging.parentFile?.mkdirs()
        try {
            val url = urlFactory(track)
            if (url.isNullOrBlank()) {
                fail(gid, key, DownloadFailure(DownloadFailureKind.InvalidResponse, "无法生成下载地址"))
                return
            }
            downloads.record(DownloadRecord(gid, DownloadStatus.Downloading, 0f, null))
            val request = Request.Builder().url(url).build()
            okHttp.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    fail(gid, key, mapHttpFailure(response.code))
                    return
                }
                val body = response.body ?: run {
                    fail(gid, key, DownloadFailure(DownloadFailureKind.InvalidResponse, "空响应体"))
                    return
                }
                val source = body.source()
                staging.outputStream().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var read: Int
                    var total = 0L
                    var lastWrittenProgress = 0f
                    var lastWriteAt = 0L
                    val contentLength = body.contentLength()
                    while (source.read(buffer).also { read = it } != -1) {
                        if (tombstones.contains(key)) {
                            fail(gid, key, DownloadFailure(DownloadFailureKind.Interrupted, "已取消"))
                            return
                        }
                        output.write(buffer, 0, read)
                        total += read
                        val progress = if (contentLength > 0) total.toFloat() / contentLength else 0f
                        val now = System.currentTimeMillis()
                        if (progress - lastWrittenProgress >= PROGRESS_WRITE_DELTA ||
                            now - lastWriteAt >= PROGRESS_WRITE_INTERVAL_MS
                        ) {
                            lastWrittenProgress = progress
                            lastWriteAt = now
                            downloads.record(
                                DownloadRecord(gid, DownloadStatus.Downloading, progress.coerceIn(0f, 1f), null),
                            )
                        }
                    }
                }
                if (tombstones.contains(key)) return
                val cacheFile = cacheFor(gid)
                if (!staging.renameTo(cacheFile)) {
                    staging.copyTo(cacheFile, overwrite = true)
                    staging.delete()
                }
                promotionStore.promote(gid)
                downloads.record(DownloadRecord(gid, DownloadStatus.Downloaded, 1f, cacheFile.absolutePath))
            }
        } catch (e: CancellationException) {
            if (!tombstones.contains(key)) {
                downloads.record(DownloadRecord(gid, DownloadStatus.Failed, 0f, null))
            }
        } catch (e: java.net.SocketTimeoutException) {
            fail(gid, key, DownloadFailure(DownloadFailureKind.TimedOut, "下载超时"))
        } catch (e: java.net.UnknownHostException) {
            fail(gid, key, DownloadFailure(DownloadFailureKind.NetworkUnavailable, "网络不可用"))
        } catch (e: IOException) {
            fail(gid, key, DownloadFailure(DownloadFailureKind.NetworkUnavailable, "网络错误"))
        } catch (e: Exception) {
            fail(gid, key, DownloadFailure(DownloadFailureKind.Unknown, "未知错误"))
        } finally {
            staging.delete()
            tombstones.remove(key)
        }
    }

    private suspend fun fail(gid: GlobalId, key: String, failure: DownloadFailure) {
        stagingFor(key).delete()
        _failures.value = _failures.value + (key to failure)
        downloads.record(DownloadRecord(gid, DownloadStatus.Failed, 0f, null))
    }

    private fun mapHttpFailure(code: Int): DownloadFailure = when (code) {
        401, 403 -> DownloadFailure(DownloadFailureKind.Authentication, "认证失败")
        404, 410 -> DownloadFailure(DownloadFailureKind.Unavailable, "文件不存在")
        in 500..599 -> DownloadFailure(DownloadFailureKind.Unavailable, "服务器错误")
        else -> DownloadFailure(DownloadFailureKind.Unknown, "HTTP $code")
    }

    private fun cacheFor(gid: GlobalId): File = File(cacheDir, "${sanitize(gid.serialized)}.cache")
    private fun stagingFor(key: String): File = File(stagingDir, "${sanitize(key)}.download")
    private fun sanitize(raw: String): String = raw.replace(Regex("[^A-Za-z0-9_.-]"), "_").take(120)

    companion object {
        private const val LEGACY_CACHE_DIR_NAME = "trackcache"
        private const val STAGING_DIR_NAME = "downloadstaging"
        const val MAX_CONCURRENT_DOWNLOADS = 3
        private const val PROGRESS_WRITE_DELTA = 0.01f
        private const val PROGRESS_WRITE_INTERVAL_MS = 250L

        private fun prepareLocalMusicDownloadDirectory(context: Context): File {
            val root = File(context.filesDir, "localmusic").apply { mkdirs() }
            val target = File(root, "downloads")
            val legacy = File(context.filesDir, LEGACY_CACHE_DIR_NAME)
            if (!target.exists() && legacy.exists()) {
                target.parentFile?.mkdirs()
                if (!legacy.renameTo(target)) {
                    target.mkdirs()
                    legacy.listFiles()?.forEach { old ->
                        old.copyTo(File(target, old.name), overwrite = true)
                    }
                    legacy.deleteRecursively()
                }
            }
            target.mkdirs()
            return target
        }

        private fun defaultOkHttpClient(): OkHttpClient =
            OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .build()
    }
}

class DownloadService : Service() {
    private var manager: DownloadManager? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var activeCountJob: Job? = null
    private var isForegrounded = false

    override fun onCreate() {
        super.onCreate()
        createChannel()
        manager = DownloadServiceHolder.manager
        if (manager == null) stopSelf()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val mgr = manager ?: DownloadServiceHolder.manager
        if (mgr == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        manager = mgr
        updateForegroundState(mgr.activeCount.value)
        if (activeCountJob == null) {
            activeCountJob = scope.launch {
                mgr.activeCount.collect { count -> updateForegroundState(count) }
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        activeCountJob?.cancel()
        activeCountJob = null
        scope.cancel()
        super.onDestroy()
    }

    private fun updateForegroundState(count: Int) {
        if (count > 0) {
            if (!isForegrounded) {
                startForeground(NOTIFICATION_ID, buildNotification())
                isForegrounded = true
            }
            return
        }
        if (isForegrounded) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            isForegrounded = false
        }
        stopSelf()
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Auralis")
            .setContentText("正在下载歌曲…")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "下载", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    companion object {
        private const val CHANNEL_ID = "auralis.downloads"
        private const val NOTIFICATION_ID = 0x10
    }
}

object DownloadServiceHolder {
    @Volatile
    var manager: DownloadManager? = null

    @Volatile
    var initialized: Boolean = false
}
