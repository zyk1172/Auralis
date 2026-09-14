// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.local

import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract
import com.auralis.core.domain.AlbumId
import com.auralis.core.domain.ArtistId
import com.auralis.core.domain.AudioSourceInfo
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.LocalLibraryId
import com.auralis.core.domain.LocalLibraryScanSnapshot
import com.auralis.core.domain.LocalMusicSource
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/** Android SAF-backed local music catalog. Mobile and TV share one process-level runtime. */
class AndroidLocalMusicLibrary private constructor(private val context: Context) {
    private val prefs = context.getSharedPreferences("auralis_local_music_sources", Context.MODE_PRIVATE)
    private val statePrefs = context.getSharedPreferences("auralis_local_music_state", Context.MODE_PRIVATE)
    private val _sources = MutableStateFlow(loadSources())
    private val _tracks = MutableStateFlow<List<Track>>(emptyList())
    private val _revision = MutableStateFlow(0L)
    val sources: StateFlow<List<LocalMusicSource>> = _sources.asStateFlow()
    val tracks: StateFlow<List<Track>> = _tracks.asStateFlow()
    val revision: StateFlow<Long> = _revision.asStateFlow()

    fun addTree(uri: Uri) {
        context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val set = prefs.getStringSet(SOURCE_URIS, emptySet()).orEmpty().toMutableSet()
        set += uri.toString()
        prefs.edit().putStringSet(SOURCE_URIS, set).apply()
        _sources.value = loadSources()
        bumpRevision()
    }

    fun removeSource(source: LocalMusicSource) {
        val set = prefs.getStringSet(SOURCE_URIS, emptySet()).orEmpty().toMutableSet()
        set.remove(source.locationToken)
        prefs.edit().putStringSet(SOURCE_URIS, set).apply()
        runCatching {
            context.contentResolver.releasePersistableUriPermission(
                Uri.parse(source.locationToken),
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
        _sources.value = loadSources()
        _tracks.value = _tracks.value.filterNot { belongs(it, source.id) }
        bumpRevision()
    }

    suspend fun scanAll(): LocalLibraryScanSnapshot = withContext(Dispatchers.IO) {
        val next = ArrayList<Track>()
        var discovered = 0
        var failed = 0
        for (source in _sources.value) {
            val tree = Uri.parse(source.locationToken)
            runCatching {
                walkTree(tree) { document, name, mime ->
                    if (mime.startsWith("audio/") || supported(name)) {
                        discovered++
                        val track = runCatching { trackFor(document, name, source) }.getOrNull()
                        if (track != null) next += applyPersistentState(track) else failed++
                    }
                }
            }.onFailure { failed++ }
        }
        val oldIds = _tracks.value.mapTo(HashSet()) { it.id }
        val newIds = next.mapTo(HashSet()) { it.id }
        _tracks.value = next
        bumpRevision()
        LocalLibraryScanSnapshot(
            discoveredFiles = discovered,
            importedTracks = (newIds - oldIds).size,
            updatedTracks = newIds.intersect(oldIds).size,
            removedTracks = (oldIds - newIds).size,
            failedFiles = failed,
        )
    }

    fun track(globalId: GlobalId): Track? =
        if (globalId.serverId != LOCAL_SERVER_ID) null
        else _tracks.value.firstOrNull { it.id.value == globalId.remoteId }

    fun setFavorite(globalId: GlobalId, value: Boolean) {
        requireLocal(globalId)
        statePrefs.edit().putBoolean(stateKey(FAVORITE_PREFIX, globalId), value).apply()
        _tracks.value = _tracks.value.map { track ->
            if (track.globalId == globalId) track.copy(isFavorite = value) else track
        }
        bumpRevision()
    }

    fun setRating(globalId: GlobalId, rating: Int?) {
        requireLocal(globalId)
        val key = stateKey(RATING_PREFIX, globalId)
        val editor = statePrefs.edit()
        if (rating == null) editor.remove(key) else editor.putInt(key, rating.coerceIn(0, 5))
        editor.apply()
        _tracks.value = _tracks.value.map { track ->
            if (track.globalId == globalId) track.copy(rating = rating?.coerceIn(0, 5)) else track
        }
        bumpRevision()
    }

    fun setDisliked(globalId: GlobalId, disliked: Boolean) {
        requireLocal(globalId)
        statePrefs.edit().putBoolean(stateKey(DISLIKED_PREFIX, globalId), disliked).apply()
        bumpRevision()
    }

    fun isDisliked(globalId: GlobalId): Boolean =
        globalId.serverId == LOCAL_SERVER_ID &&
            statePrefs.getBoolean(stateKey(DISLIKED_PREFIX, globalId), false)

    fun dislikedIds(): Set<GlobalId> =
        _tracks.value.asSequence().map { it.globalId }.filter(::isDisliked).toSet()

    fun recordPlay(globalId: GlobalId, completed: Boolean) {
        requireLocal(globalId)
        val countKey = stateKey(PLAY_COUNT_PREFIX, globalId)
        val nextCount = statePrefs.getInt(countKey, 0) + 1
        statePrefs.edit()
            .putInt(countKey, nextCount)
            .putLong(stateKey(LAST_PLAYED_PREFIX, globalId), System.currentTimeMillis())
            .putBoolean(stateKey(COMPLETED_PREFIX, globalId), completed)
            .apply()
        bumpRevision()
    }

    fun markCompleted(globalId: GlobalId) {
        requireLocal(globalId)
        statePrefs.edit()
            .putBoolean(stateKey(COMPLETED_PREFIX, globalId), true)
            .putLong(stateKey(LAST_PLAYED_PREFIX, globalId), System.currentTimeMillis())
            .apply()
        bumpRevision()
    }

    fun playCount(globalId: GlobalId): Int =
        if (globalId.serverId != LOCAL_SERVER_ID) 0
        else statePrefs.getInt(stateKey(PLAY_COUNT_PREFIX, globalId), 0)

    fun lastPlayedMillis(globalId: GlobalId): Long? {
        if (globalId.serverId != LOCAL_SERVER_ID) return null
        val key = stateKey(LAST_PLAYED_PREFIX, globalId)
        if (!statePrefs.contains(key)) return null
        return statePrefs.getLong(key, 0L)
    }

    private fun applyPersistentState(track: Track): Track {
        val gid = track.globalId
        val ratingKey = stateKey(RATING_PREFIX, gid)
        return track.copy(
            isFavorite = statePrefs.getBoolean(stateKey(FAVORITE_PREFIX, gid), false),
            rating = if (statePrefs.contains(ratingKey)) statePrefs.getInt(ratingKey, 0) else null,
        )
    }

    private fun requireLocal(globalId: GlobalId) {
        require(globalId.serverId == LOCAL_SERVER_ID) { "不是本地音乐身份：${globalId.serialized}" }
    }

    private fun stateKey(prefix: String, globalId: GlobalId): String = "$prefix${globalId.serialized}"

    private fun bumpRevision() {
        _revision.value = _revision.value + 1
    }

    private fun loadSources(): List<LocalMusicSource> =
        prefs.getStringSet(SOURCE_URIS, emptySet()).orEmpty().sorted().map { raw ->
            val uri = Uri.parse(raw)
            LocalMusicSource(
                id = LocalLibraryId("tree-${fnv64(raw)}"),
                displayName = uri.lastPathSegment?.substringAfterLast(':')?.ifBlank { "本地音乐" }
                    ?: "本地音乐",
                locationToken = raw,
            )
        }

    private fun walkTree(tree: Uri, onDocument: (Uri, String, String) -> Unit) {
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
        walkDocument(tree, root, onDocument)
    }

    private fun walkDocument(tree: Uri, document: Uri, onDocument: (Uri, String, String) -> Unit) {
        val docId = DocumentsContract.getDocumentId(document)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
        context.contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            while (cursor.moveToNext()) {
                val child = DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(idCol))
                val name = cursor.getString(nameCol) ?: ""
                val mime = cursor.getString(mimeCol) ?: ""
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walkDocument(tree, child, onDocument)
                } else {
                    onDocument(child, name, mime)
                }
            }
        }
    }

    private fun trackFor(uri: Uri, fileName: String, source: LocalMusicSource): Track {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)
            val title = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
                ?.takeIf { it.isNotBlank() }
                ?: fileName.substringBeforeLast('.', fileName)
            val artist = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                ?.takeIf { it.isNotBlank() } ?: "未知艺术家"
            val album = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
                ?.takeIf { it.isNotBlank() } ?: "未知专辑"
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            val bitrate = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
                ?.toIntOrNull()
            val year = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_YEAR)
                ?.toIntOrNull()
            val genres = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_GENRE)
                ?.split(';', ',', '/')
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                .orEmpty()
            val sourceHash = fnv64(source.id.value)
            val idHash = fnv64(uri.toString())
            return Track(
                id = TrackId("local-file-$sourceHash-$idHash"),
                serverId = LOCAL_SERVER_ID,
                albumId = AlbumId("local-album-${fnv64("$artist|$album")}"),
                artistId = ArtistId("local-artist-${fnv64(artist)}"),
                title = title,
                artistName = artist,
                albumTitle = album,
                durationSeconds = durationMs / 1000.0,
                year = year,
                genres = genres,
                sourceInfo = AudioSourceInfo(
                    codec = fileName.substringAfterLast('.', "").lowercase(),
                    bitRate = bitrate,
                ),
                streamUrl = uri.toString(),
            )
        } finally {
            retriever.release()
        }
    }

    private fun belongs(track: Track, sourceId: LocalLibraryId): Boolean =
        track.id.value.startsWith("local-file-${fnv64(sourceId.value)}-")

    private fun supported(name: String): Boolean =
        name.substringAfterLast('.', "").lowercase() in EXTENSIONS

    companion object {
        val LOCAL_SERVER_ID = ServerId("auralis-local")
        private const val SOURCE_URIS = "tree_uris"
        private const val FAVORITE_PREFIX = "favorite:"
        private const val RATING_PREFIX = "rating:"
        private const val DISLIKED_PREFIX = "disliked:"
        private const val PLAY_COUNT_PREFIX = "play-count:"
        private const val LAST_PLAYED_PREFIX = "last-played:"
        private const val COMPLETED_PREFIX = "completed:"
        private val EXTENSIONS = setOf(
            "mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ogg", "opus",
        )
        @Volatile private var instance: AndroidLocalMusicLibrary? = null

        fun get(context: Context): AndroidLocalMusicLibrary =
            instance ?: synchronized(this) {
                instance ?: AndroidLocalMusicLibrary(context.applicationContext).also { instance = it }
            }

        internal fun fnv64(value: String): String {
            var hash = 0xcbf29ce484222325UL
            for (byte in value.encodeToByteArray()) {
                hash = hash xor byte.toUByte().toULong()
                hash *= 0x100000001b3UL
            }
            return hash.toString(16)
        }
    }
}
