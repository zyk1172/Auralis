// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.graph

import com.auralis.core.data.local.AndroidLocalMusicLibrary
import java.util.WeakHashMap

private val localMusicStores = WeakHashMap<AuralisGraph, AndroidLocalMusicLibrary>()

/** One local-library runtime per application graph without widening the existing composition constructor. */
val AuralisGraph.localMusicLibrary: AndroidLocalMusicLibrary
    get() = synchronized(localMusicStores) {
        localMusicStores.getOrPut(this) { AndroidLocalMusicLibrary(appContext) }
    }
