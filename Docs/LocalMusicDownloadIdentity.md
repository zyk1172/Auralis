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

Local music source management is owned entirely by Settings. Android `SettingsScreen` navigates to the Local Music page internally; mobile and TV application shells do not expose or inject a separate local-music navigation callback. This keeps source permissions, rescans and storage management behind one consistent Settings entry while ordinary Library/Search/Assistant reads consume the resulting tracks through the unified catalog.

On iOS/iPadOS, Auralis additionally owns an automatic user-visible import source at `Documents/LocalMusic`. With `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`, this appears in Files as `On My iPhone/iPad → Auralis → LocalMusic`. The app creates the directory itself; users do not need to pre-create or select a folder before adding local music. Server downloads remain a separate managed source and are not recursively re-imported as user files.

macOS continues to use explicit security-scoped folder selection. Android continues to use persisted SAF tree URIs.

## Catalog integration

Unified catalog integration is now active rather than deferred:

- with an active server, Library/Search/Agent reads expose the active server plus true local files;
- without an active server, the user-facing catalog becomes local-only;
- `auralis-local` remains an entity namespace rather than a fake server account;
- local identities are accepted by Agent grounding/entity validation, while identities from unrelated saved servers remain isolated;
- server-side mutations still use the real server-backed repository and are never routed through the local namespace.
