// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisSpacing

/** The feed and shelves use the available window width, including split view. */
@Composable
internal fun HomeFeed(
    topPadding: Dp,
    bottomPadding: Dp,
    modifier: Modifier = Modifier,
    state: LazyListState = rememberLazyListState(),
    content: LazyListScope.() -> Unit,
) {
    LazyColumn(
        state = state,
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = topPadding, bottom = bottomPadding),
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.xLarge),
        content = content,
    )
}

/** Inset items, never the viewport: scrolling reaches both window edges. */
@Composable
internal fun HomeShelf(content: LazyListScope.() -> Unit) {
    LazyRow(
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(horizontal = AuralisSpacing.large),
        horizontalArrangement = Arrangement.spacedBy(AuralisChrome.homeCardSpacing),
        content = content,
    )
}
