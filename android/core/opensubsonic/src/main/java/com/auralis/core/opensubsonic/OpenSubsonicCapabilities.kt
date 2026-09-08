// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.opensubsonic

import com.auralis.core.domain.ServerCapabilities

/**
 * `getOpenSubsonicExtensions` → [ServerCapabilities]。
 * 对齐 Apple `CapabilityRegistry`：扩展名先归一化（去非字母 + 小写）再匹配。
 */
object OpenSubsonicCapabilities {
    fun parse(extensions: List<ExtensionDto>): ServerCapabilities {
        val names = extensions.map { normalize(it.name) }.toSet()
        return ServerCapabilities(
            supportsStructuredLyrics = names.contains("getlyricsbysongid"),
            supportsSonicSimilarity = names.contains("getsonicsimilartracks") || names.contains("findsonicpath"),
            supportsIndexedQueue = names.contains("saveplayqueuebyindex") || names.contains("getplayqueuebyindex"),
            supportsPlaybackReport = names.contains("reportplayback"),
            supportsTranscoding = names.contains("gettranscodedecision") || names.contains("gettranscodestream"),
            supportsTranscodeOffset = names.contains("transcodeoffset") || names.contains("gettranscodestream"),
            supportsApiKeyAuthentication = names.contains("apikeyauthentication"),
        )
    }

    private fun normalize(name: String): String = name.lowercase().filter { it.isLetter() }
}
