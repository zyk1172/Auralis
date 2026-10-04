// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.job
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

// ---------------------------------------------------------------------------
// AI-06：OkHttp 阻塞调用的协程取消桥接。
//
// Kotlin 协程超时是协作式的：`newCall(...).execute()` / `body.string()` 的阻塞读
// 不响应 withTimeout，360 秒并非硬期限。这里统一改为：
// 1. 以 enqueue 异步拿到响应头，协程取消时 Call.cancel()；
// 2. 响应体读取期间注册 Job 完成回调：协程一旦取消立即 Call.cancel()，
//    打断底层 socket 上的阻塞读；
// 3. 因取消而被打断的 IOException 归一化为 CancellationException，
//    保证 withTimeoutOrNull / 调用方的取消语义不被错误分类吞掉。
// ---------------------------------------------------------------------------

/** 异步执行请求直到拿到响应头；协程取消 → Call.cancel()。 */
internal suspend fun Call.awaitResponse(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            if (cont.isActive) cont.resume(response) else response.close()
        }
    })
}

/** 协程已被取消且底层 Call 被打断时，把阻塞读的 IOException 归一化为取消。 */
internal fun Call.rethrowAsCancellation(cause: Throwable) {
    if (isCanceled()) throw CancellationException("请求已取消").apply { initCause(cause) }
}

/**
 * 读取响应体期间响应协程取消：以 onCancelling=true 注册 Job 回调
 * （普通 invokeOnCompletion 要等 job 进入完成态，阻塞读未结束时永不触发；
 * onCancelling 在取消开始的瞬间即触发），一旦取消立即 cancel 底层 Call，
 * 使阻塞中的 read 及时抛出并返回；结束（含异常）关闭 Response。
 * block 原地内联展开，允许在其中挂起（如 flow emit）。
 *
 * 注：invokeOnCompletion(onCancelling=true) 标记为 InternalCoroutinesApi，
 * 但这是协程取消即时打断阻塞 IO 的唯一直接通道（invokeOnCancellation 只在
 * CancellableContinuation 上可用），故在此局部 OptIn。
 */
@OptIn(kotlinx.coroutines.InternalCoroutinesApi::class)
internal suspend inline fun <T> Response.useCancellable(call: Call, block: (Response) -> T): T {
    val job = currentCoroutineContext().job
    val handle = job.invokeOnCompletion(onCancelling = true) { cause ->
        if (cause is CancellationException) call.cancel()
    }
    try {
        return block(this)
    } catch (e: IOException) {
        call.rethrowAsCancellation(e)
        throw e
    } finally {
        handle.dispose()
        close()
    }
}

/** 非流式：执行请求并把整个响应体读成字符串（取消可打断，含响应体读取阶段）。 */
internal suspend fun OkHttpClient.executeForString(request: Request): Pair<Int, String> =
    withContext(Dispatchers.IO) {
        val call = newCall(request)
        val response = try {
            call.awaitResponse()
        } catch (e: IOException) {
            call.rethrowAsCancellation(e)
            throw e
        }
        response.useCancellable(call) { resp ->
            resp.code to (resp.body?.string() ?: "")
        }
    }
