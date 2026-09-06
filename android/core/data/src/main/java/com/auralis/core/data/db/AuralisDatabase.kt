package com.auralis.core.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import kotlinx.serialization.json.Json

/**
 * 本地权威目录数据库（进程单例）。
 *
 * 对应 Apple `LocalCatalogStore` 的 `catalog.sqlite`。
 *
 * 铁律：
 * 1. **进程内只允许一个实例**（AuralisDatabaseProvider），Connector / Search / Home /
 *    AI Tool Runtime 全部共用——Apple 曾专门避免 catalog split-brain。
 * 2. **禁止 `fallbackToDestructiveMigration()`**：数据库打不开/迁移失败时记录错误并
 *    保留原文件（里面有收藏/不喜欢/推荐索引等本地状态），绝不在连接失败时静默删库。
 */
@Database(
    entities = [
        ServerEntity::class,
        ArtistEntity::class,
        AlbumEntity::class,
        TrackEntity::class,
        TrackFtsEntity::class,
        GenreEntity::class,
        PlaylistEntity::class,
        PlaylistTrackEntity::class,
        FavoriteEntity::class,
        RatingEntity::class,
        PlayHistoryEntity::class,
        DownloadEntity::class,
        LyricEntity::class,
        DislikedTrackEntity::class,
        SyncSessionEntity::class,
        SyncCheckpointEntity::class,
        SyncStagedTrackEntity::class,
        SyncMetaEntity::class,
    ],
    version = 1,
    exportSchema = true,
)
abstract class AuralisDatabase : RoomDatabase() {
    abstract fun serverDao(): ServerDao
    abstract fun artistDao(): ArtistDao
    abstract fun albumDao(): AlbumDao
    abstract fun trackDao(): TrackDao
    abstract fun trackFtsDao(): TrackFtsDao
    abstract fun genreDao(): GenreDao
    abstract fun playlistDao(): PlaylistDao
    abstract fun annotationDao(): AnnotationDao
    abstract fun downloadDao(): DownloadDao
    abstract fun syncDao(): SyncDao
}

object AuralisDatabaseProvider {
    @Volatile
    private var instance: AuralisDatabase? = null

    /** 进程单例。任何模块都不得自行调用 `Room.databaseBuilder`。 */
    fun get(context: Context): AuralisDatabase {
        instance?.let { return it }
        synchronized(this) {
            instance?.let { return it }
            val database = Room.databaseBuilder(
                context.applicationContext,
                AuralisDatabase::class.java,
                DATABASE_NAME,
            )
                // 有意不调用 fallbackToDestructiveMigration()：
                // 正式 catalog 里存有收藏 / 不喜欢 / 播放历史 / 下载记录等本地状态，
                // 迁移失败宁可让用户看到明确的数据库错误，也不能静默清空。
                .addCallback(object : RoomDatabase.Callback() {})
                .build()
            instance = database
            return database
        }
    }
}

object DataJson {
    val json: Json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        explicitNulls = false
        coerceInputValues = true
    }
}

const val DATABASE_NAME = "catalog.sqlite"
