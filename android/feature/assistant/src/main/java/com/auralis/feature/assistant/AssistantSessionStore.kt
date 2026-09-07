package com.auralis.feature.assistant

import android.content.Context
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * 会话持久化（对齐 Swift `agent-sessions.json`；文件级 JSON，进程内串行写）。
 *
 * - 流式/运行中内容不落盘；仅在消息定稿后调用 [appendMessage]/[updateSession] 持久化；
 * - 与操作日志分开两个文件：`agent-sessions.json` 与 `agent-actions.json`。
 */
class AssistantSessionStore(context: Context) {

    private val json = Json { ignoreUnknownKeys = true; prettyPrint = false }
    private val sessionsFile: File = File(File(context.filesDir, "assistant"), "agent-sessions.json")
    private val actionsFile: File = File(File(context.filesDir, "assistant"), "agent-actions.json")
    private val mutex = Mutex()

    private suspend fun readSessionsLocked(): List<AssistantSession> = withContext(Dispatchers.IO) {
        if (!sessionsFile.exists()) return@withContext emptyList()
        runCatching {
            json.decodeFromString<AssistantStoreFile>(sessionsFile.readText()).sessions
        }.getOrElse { emptyList() }
    }

    private suspend fun writeSessionsLocked(sessions: List<AssistantSession>) = withContext(Dispatchers.IO) {
        sessionsFile.parentFile?.mkdirs()
        sessionsFile.writeText(json.encodeToString(AssistantStoreFile(sessions = sessions)))
    }

    suspend fun loadSessions(): List<AssistantSession> = mutex.withLock { readSessionsLocked() }

    suspend fun saveSession(session: AssistantSession) = mutex.withLock {
        val all = readSessionsLocked()
        val updated = session.copy(updatedAtMillis = System.currentTimeMillis())
        writeSessionsLocked(all.map { if (it.id == session.id) updated else it })
    }

    suspend fun insertSession(session: AssistantSession) = mutex.withLock {
        val all = readSessionsLocked()
        writeSessionsLocked(listOf(session) + all.filterNot { it.id == session.id })
    }

    suspend fun deleteSession(sessionId: String) = mutex.withLock {
        val all = readSessionsLocked()
        writeSessionsLocked(all.filterNot { it.id == sessionId })
    }

    /** 追加一条消息并刷新 updatedAt（消息定稿时唯一落盘入口）。 */
    suspend fun appendMessage(sessionId: String, message: StoredAssistantMessage) = mutex.withLock {
        val all = readSessionsLocked()
        val updated = all.map { s ->
            if (s.id == sessionId) {
                s.copy(
                    messages = s.messages + message,
                    updatedAtMillis = System.currentTimeMillis(),
                )
            } else {
                s
            }
        }
        writeSessionsLocked(updated)
    }

    suspend fun clearMessages(sessionId: String) = mutex.withLock {
        val all = readSessionsLocked()
        writeSessionsLocked(all.map { if (it.id == sessionId) it.copy(messages = emptyList(), updatedAtMillis = System.currentTimeMillis()) else it })
    }

    // ------------------------------------------------------------ 操作日志

    private suspend fun readActionsLocked(): List<AssistantActionRecord> = withContext(Dispatchers.IO) {
        if (!actionsFile.exists()) return@withContext emptyList()
        runCatching {
            json.decodeFromString<List<AssistantActionRecord>>(actionsFile.readText())
        }.getOrElse { emptyList() }
    }

    private suspend fun writeActionsLocked(records: List<AssistantActionRecord>) = withContext(Dispatchers.IO) {
        actionsFile.parentFile?.mkdirs()
        actionsFile.writeText(json.encodeToString(records))
    }

    suspend fun loadActions(): List<AssistantActionRecord> = mutex.withLock { readActionsLocked() }

    suspend fun appendAction(record: AssistantActionRecord) = mutex.withLock {
        val all = readActionsLocked()
        writeActionsLocked(listOf(record) + all)
    }

    suspend fun removeAction(recordId: String) = mutex.withLock {
        val all = readActionsLocked()
        writeActionsLocked(all.filterNot { it.id == recordId })
    }
}
