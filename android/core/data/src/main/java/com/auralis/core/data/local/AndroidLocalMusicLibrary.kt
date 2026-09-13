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

/** Android SAF-backed local music catalog. Mobile and TV share this implementation. */
class AndroidLocalMusicLibrary(private val context: Context) {
    private val prefs = context.getSharedPreferences("auralis_local_music_sources", Context.MODE_PRIVATE)
    private val _sources = MutableStateFlow(loadSources())
    private val _tracks = MutableStateFlow<List<Track>>(emptyList())
    val sources: StateFlow<List<LocalMusicSource>> = _sources.asStateFlow()
    val tracks: StateFlow<List<Track>> = _tracks.asStateFlow()

    fun addTree(uri: Uri) {
        context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val set = prefs.getStringSet(SOURCE_URIS, emptySet()).orEmpty().toMutableSet()
        set += uri.toString()
        prefs.edit().putStringSet(SOURCE_URIS, set).apply()
        _sources.value = loadSources()
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
                        if (track != null) next += track else failed++
                    }
                }
            }.onFailure { failed++ }
        }
        val oldIds = _tracks.value.mapTo(HashSet()) { it.id }
        val newIds = next.mapTo(HashSet()) { it.id }
        _tracks.value = next
        LocalLibraryScanSnapshot(
            discoveredFiles = discovered,
            importedTracks = (newIds - oldIds).size,
            updatedTracks = newIds.intersect(oldIds).size,
            removedTracks = (oldIds - newIds).size,
            failedFiles = failed,
        )
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
        private val EXTENSIONS = setOf(
            "mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ogg", "opus",
        )

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
