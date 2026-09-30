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
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
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
    /**
     * 下载执行器。
     *
     * 必须是 `Dispatchers.IO`：`runDownload` 内部用的是**阻塞式** `okHttp.newCall(...).execute()`
     * 与文件流拷贝。历史上这里用 `Dispatchers.Default`（并行度 = max(2, CPU-1)，4 核手机仅 3），
     * 而 `MAX_CONCURRENT_DOWNLOADS = 3` 恰好能把 Default 池占满；`AuralisGraph.appScope`
     * （bootstrap、下载水合、本地扫描、目录解码）同样跑在 Default 上，于是「下载」会把整个应用的
     * 后台工作饿死，表现为首页不刷新、扫描停滞、界面假死。
     */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val promotionStore = DownloadPromotionStore(context)
    private val cacheDir = prepareLocalMusicDownloadDirectory(context)
    private val stagingDir = File(context.filesDir, STAGING_DIR_NAME).apply { mkdirs() }

    private val activeTasks = ConcurrentHashMap<String, Job>()
    private val tombstones = ConcurrentHashMap.newKeySet<String>()
    private val semaphore = Semaphore(MAX_CONCURRENT_DOWNLOADS)
    private val runningKeys = ConcurrentHashMap.newKeySet<String>()
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

    /**
     * 入队一个下载。
     *
     * 并发上限只约束**同时执行**的数量（[semaphore]）；历史实现每次 `submit` 都无条件
     * `scope.launch` 再挂在信号量上等待，因此「下载整张专辑/整个歌单」会一次性创建成百上千个
     * 排队协程，各自持有 Track 引用。现在改为惰性启动 + 原子去重：`putIfAbsent` 失败说明同一
     * key 已在队列中，直接取消本次新建的协程，不产生第二个排队者。
     */
    private fun submit(key: String, track: Track) {
        tombstones.remove(key)
        val job = scope.launch(start = CoroutineStart.LAZY) {
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
        if (activeTasks.putIfAbsent(key, job) != null) {
            job.cancel()
            return
        }
        _activeCount.value = activeTasks.size
        job.invokeOnCompletion {
            activeTasks.remove(key)
            _activeCount.value = activeTasks.size
        }
        job.start()
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
                        // 进度写库会 invalidate `downloads` 表，从而让所有 `observe(globalId)` /
                        // `observeAll` 的订阅者（资料库列表每行一个）重新发射。历史节流是
                        // 「变化 ≥1% 或 250ms」，最坏 3 并发 × 4 次/秒 = 12 次整表刷新/秒。
                        // 收敛到 1 次/秒即可保持进度条观感，同时把刷新风暴降为原来的 1/4。
                        if (now - lastWriteAt >= PROGRESS_WRITE_INTERVAL_MS) {
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
                // 重试/重新下载成功后清除历史失败记录，避免 failures 只增不减。
                clearFailure(key)
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
        rememberFailure(key, failure)
        downloads.record(DownloadRecord(gid, DownloadStatus.Failed, 0f, null))
    }

    /**
     * 记录失败。
     *
     * 历史实现是 `_failures.value = _failures.value + (key to failure)`：整表复制且**永不清除**，
     * 长期使用后 Map 无界增长，且每次失败都触发一次 O(size) 拷贝 + StateFlow 发射。
     * 现在按插入顺序保留最近 [MAX_REMEMBERED_FAILURES] 条。
     */
    private fun rememberFailure(key: String, failure: DownloadFailure) {
        val next = LinkedHashMap(_failures.value)
        next.remove(key)
        next[key] = failure
        while (next.size > MAX_REMEMBERED_FAILURES) {
            val oldest = next.keys.firstOrNull() ?: break
            next.remove(oldest)
        }
        _failures.value = next
    }

    private fun clearFailure(key: String) {
        val current = _failures.value
        if (!current.containsKey(key)) return
        _failures.value = LinkedHashMap(current).apply { remove(key) }
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

        /** 进度落库节流：1 次/秒（见 runDownload 内的说明）。 */
        private const val PROGRESS_WRITE_INTERVAL_MS = 1_000L

        /** `failures` 的保留上限，避免长期运行后无界增长。 */
        private const val MAX_REMEMBERED_FAILURES = 200

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

        /**
         * 下载用 OkHttp。
         *
         * `readTimeout = 0`（永不超时）意味着服务器半开连接或卡流时，执行 `execute()` 的线程
         * 会**永久**占住调度器；配合 `Dispatchers.Default` 时代直接饿死整个应用的后台工作。
         * 现在改回有限读超时：单次 socket 读 60s 无数据即失败，交给既有的 retry / fail 路径处理。
         */
        private fun defaultOkHttpClient(): OkHttpClient =
            OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .callTimeout(30, TimeUnit.MINUTES)
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
            stopSelf(startId)
            return START_NOT_STICKY
        }
        manager = mgr
        // `startForegroundService` 契约：启动后必须在约 5s 内调用 `startForeground`。
        // 历史实现直接用 activeCount 决定是否进入前台，于是存在这样的竞态窗口 ——
        // 收集器读到 count>0 并发出 startForegroundService 之后、本回调执行之前，
        // 最后一个下载恰好完成使 count 归零，于是走 `count == 0` 分支只执行
        // `stopForeground/stopSelf`，**从未调用 startForeground**。部分 OEM 与 Android 12+
        // 会把这种情况上报为 `ForegroundServiceDidNotStartInTimeException`
        // （android.app.RemoteServiceException）并杀掉进程。
        // 因此这里无条件先进入前台，再按任务数决定是否降级退出。
        promoteToForeground()
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

    private fun promoteToForeground() {
        if (isForegrounded) return
        startForeground(NOTIFICATION_ID, buildNotification())
        isForegrounded = true
    }

    private fun updateForegroundState(count: Int) {
        if (count > 0) {
            promoteToForeground()
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
