// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AI-12：披露权限的模型投影 —— 受限类别只回元信息/计数，正文不外发；
 * 权限允许时原样放行；未分类工具不受影响。
 */
class AiPrivacyProjectionTest {

    private val defaultPermissions = AiPrivacyPermissions() // 默认：仅 metadata 开

    private fun project(category: AiPrivacyCategory?, result: String, permissions: AiPrivacyPermissions = defaultPermissions) =
        AiPrivacyProjection.projectToolResult(category, result, permissions)

    @Test
    fun `歌词关闭时只回元信息不回正文`() {
        val result = """{"ok":true,"synced":true,"language":"zh","lineCount":42,"preview":[{"text":"的秘密歌词内容"}]}"""
        val projected = project(AiPrivacyCategory.Lyrics, result)
        assertTrue(projected.contains("隐藏"))
        assertTrue(projected.contains("42"))
        assertTrue(projected.contains("zh"))
        assertFalse(projected.contains("的秘密歌词内容"))
        // 权限打开后原样放行。
        val allowed = AiPrivacyPermissions(allowsLyrics = true)
        assertEquals(result, project(AiPrivacyCategory.Lyrics, result, allowed))
    }

    @Test
    fun `无歌词的失败结果不含正文可原样回灌`() {
        val result = """{"ok":false,"message":"没有可用歌词"}"""
        assertEquals(result, project(AiPrivacyCategory.Lyrics, result))
    }

    @Test
    fun `播放历史关闭时只回条目数`() {
        val result = """{"ok":true,"count":3,"entries":[{"title":"私密歌曲A","artist":"某人"},{"title":"私密歌曲B","artist":"某人"}]}"""
        val projected = project(AiPrivacyCategory.PlaybackHistory, result)
        assertTrue(projected.contains("3"))
        assertFalse(projected.contains("私密歌曲A"))
        val allowed = AiPrivacyPermissions(allowsPlaybackHistory = true)
        assertEquals(result, project(AiPrivacyCategory.PlaybackHistory, result, allowed))
    }

    @Test
    fun `收藏关闭时列表只回数量`() {
        val result = """{"ok":true,"tracks":{"count":2,"items":[{"title":"收藏曲目","artist":"某人"}]}}"""
        val projected = project(AiPrivacyCategory.FavoritesAndRatings, result)
        assertTrue(projected.contains("2"))
        assertFalse(projected.contains("收藏曲目"))
    }

    @Test
    fun `收藏关闭时单条结果剥离收藏与评分字段`() {
        val result = """{"ok":true,"track":{"title":"夜曲"},"isFavorite":true,"rating":5}"""
        val projected = project(AiPrivacyCategory.FavoritesAndRatings, result)
        assertFalse(projected.contains("isFavorite"))
        assertFalse(projected.contains("rating"))
        assertTrue(projected.contains("夜曲")) // 元数据类别仍开
    }

    @Test
    fun `纯文本操作确认在收藏关闭时脱敏`() {
        val projected = project(AiPrivacyCategory.FavoritesAndRatings, "已收藏《夜曲》")
        assertFalse(projected.contains("夜曲"))
        val allowed = AiPrivacyPermissions(allowsFavoritesAndRatings = true)
        assertEquals("已收藏《夜曲》", project(AiPrivacyCategory.FavoritesAndRatings, "已收藏《夜曲》", allowed))
    }

    @Test
    fun `未分类工具结果不受影响`() {
        val result = """{"ok":true,"anything":"原样"}"""
        assertEquals(result, project(null, result))
    }
}
