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
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
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

    private data class DownloadTask(
        val key: String,
        val track: Track,
        @Volatile var runningJob: Job? = null,
    )

    private val activeTasks = ConcurrentHashMap<String, DownloadTask>()
    private val tombstones = ConcurrentHashMap.newKeySet<String>()
    private val queue = Channel<DownloadTask>(capacity = Channel.UNLIMITED)
    private val runningKeys = ConcurrentHashMap.newKeySet<String>()
    private val _activeCount = MutableStateFlow(0)
    private val _runningCount = MutableStateFlow(0)
    private val _failures = MutableStateFlow<Map<String, DownloadFailure>>(emptyMap())

    val activeCount: StateFlow<Int> = _activeCount.asStateFlow()
    val runningCount: StateFlow<Int> = _runningCount.asStateFlow()
    val failures: StateFlow<Map<String, DownloadFailure>> = _failures.asStateFlow()

    /**
     * 固定 worker 池：无论一次加入 10 首还是 10,000 首，真正存在的下载执行协程始终最多
     * [MAX_CONCURRENT_DOWNLOADS] 个。队列本身只保存轻量任务对象，不再“一首歌一个挂起协程”。
     */
    private val workers: List<Job> = List(MAX_CONCURRENT_DOWNLOADS) {
        scope.launch {
            for (task in queue) consume(task)
        }
    }

    suspend fun enqueue(track: Track) {
        submit(track.globalId.serialized, track)
    }

    fun cancel(gid: GlobalId) {
        val key = gid.serialized
        tombstones.add(key)
        cancelTask(key)
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
        cancelTask(key)
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
        queue.close()
        scope.cancel()
    }

    /**
     * 入队一个下载。
     *
     * 先用 activeTasks 原子占位，再落 Queued 状态并写入 Channel。固定 worker 池负责消费，
     * 因此排队数量不会转化成同等数量的挂起协程；同一 key 的重复提交也会被 putIfAbsent 拦截。
     */
    private suspend fun submit(key: String, track: Track) {
        tombstones.remove(key)
        val task = DownloadTask(key, track)
        if (activeTasks.putIfAbsent(key, task) != null) return
        _activeCount.update { it + 1 }
        try {
            downloads.record(DownloadRecord(track.globalId, DownloadStatus.Queued, 0f, null))
            queue.send(task)
        } catch (t: Throwable) {
            if (activeTasks.remove(key, task)) {
                _activeCount.update { (it - 1).coerceAtLeast(0) }
            }
            throw t
        }
    }

    /**
     * 取消任务。运行中的任务保留 activeTasks 占位直到真正退出，防止旧下载仍在收尾时同 key
     * 被立即重新入队并同时操作同一个 staging 文件；尚未运行的任务可立即从 active 集合移除，
     * Channel 中残留的旧条目会被 worker 识别为 stale 并跳过。
     */
    private fun cancelTask(key: String) {
        val task = activeTasks[key] ?: return
        tombstones.add(key)
        val running = task.runningJob
        if (running != null) {
            running.cancel()
        } else if (activeTasks.remove(key, task)) {
            _activeCount.update { (it - 1).coerceAtLeast(0) }
        }
    }

    private suspend fun consume(task: DownloadTask) {
        val key = task.key
        if (activeTasks[key] !== task) {
            if (!activeTasks.containsKey(key)) tombstones.remove(key)
            return
        }
        if (tombstones.contains(key)) {
            if (activeTasks.remove(key, task)) {
                _activeCount.update { (it - 1).coerceAtLeast(0) }
            }
            tombstones.remove(key)
            return
        }

        if (runningKeys.add(key)) {
            _runningCount.update { it + 1 }
        }
        try {
            coroutineScope {
                // 先创建但不启动，写入 runningJob 后再做一次有效性检查，避免 cancel() 恰好落在
                // “worker 取出任务”和“任务真正开始”之间时仍短暂启动旧下载。
                val job = launch(start = CoroutineStart.LAZY) {
                    if (!tombstones.contains(key)) runDownload(key, task.track)
                }
                task.runningJob = job
                if (activeTasks[key] !== task || tombstones.contains(key)) {
                    job.cancel()
                } else {
                    job.start()
                }
                job.join()
            }
        } finally {
            task.runningJob = null
            if (runningKeys.remove(key)) {
                _runningCount.update { (it - 1).coerceAtLeast(0) }
            }
            if (activeTasks.remove(key, task)) {
                _activeCount.update { (it - 1).coerceAtLeast(0) }
            }
            if (!activeTasks.containsKey(key)) tombstones.remove(key)
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
                    var lastWriteAt = 0L
                    val contentLength = body.contentLength()
                    while (source.read(buffer).also { read = it } != -1) {
                        if (tombstones.contains(key)) return
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
        _failures.update { current ->
            val next = LinkedHashMap(current)
            next.remove(key)
            next[key] = failure
            while (next.size > MAX_REMEMBERED_FAILURES) {
                val oldest = next.keys.firstOrNull() ?: break
                next.remove(oldest)
            }
            next
        }
    }

    private fun clearFailure(key: String) {
        _failures.update { current ->
            if (!current.containsKey(key)) current
            else LinkedHashMap(current).apply { remove(key) }
        }
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
