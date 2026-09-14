// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data.graph

import com.auralis.core.data.local.AndroidLocalMusicLibrary

/** Shared process-level local-library runtime used by Settings, Library and Agent surfaces. */
val AuralisGraph.localMusicLibrary: AndroidLocalMusicLibrary
    get() = AndroidLocalMusicLibrary.get(appContext)
