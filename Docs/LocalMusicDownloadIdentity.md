<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Local music download identity

Server downloads are promoted into the app-managed local music library instead of remaining cache-only files.

## Identity contract

- The remote identity (`serverID + remote trackID`) remains a compatibility alias so existing queue entries, history, playlists and pending UI state do not break when a download completes.
- A completed download also receives a deterministic canonical local TrackID under the `auralis-local` namespace.
- Re-downloading the same remote track reuses the same canonical local identity even when the physical file name changes.
- Removing a download removes the promotion mapping together with the physical local file.
- Legacy Apple `Auralis/TrackCache` and Android `trackcache` files are migrated into the LocalMusic downloads directory; identity promotion is backfilled lazily when needed.

## Playback routing

Local identities must resolve to local file/content URIs and must never fall through to an OpenSubsonic connector. Remote aliases may still resolve to the promoted local file so an already-materialized queue can continue playback without rewriting every queue/history/playlist reference at download completion time.

## Settings-only management

Local music source management is owned entirely by Settings. Android `SettingsScreen` navigates to the Local Music page internally; mobile and TV application shells do not expose or inject a separate local-music navigation callback. This keeps source permissions, rescans and storage management behind one consistent Settings entry while the ordinary Library may later consume the resulting tracks as read-only catalog content.

## Catalog integration

The promotion layer is intentionally separate from unified catalog aggregation. A later integration layer may expose canonical local tracks in Library/Search/Agent while keeping the remote alias for compatibility and server-side mutations.