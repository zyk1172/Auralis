<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Local music download identity

Server downloads are promoted into the app-managed local music library instead of remaining opaque cache-only files. On iOS/iPadOS, their physical audio is also relocated into the Files-visible `Documents/LocalMusic` one-song package layout after download completion.

## Identity contract

- The remote identity (`serverID + remote trackID`) remains a compatibility alias so existing queue entries, history, playlists and pending UI state do not break when a download completes.
- A completed download also receives a deterministic canonical local TrackID under the `auralis-local` namespace.
- Re-downloading the same remote track reuses the same canonical local identity even when the physical package or file name changes.
- Moving the downloaded audio into the Files-visible package does not create a second audio copy; TrackCacheStore updates its persisted location mapping to the new package file.
- Removing a download removes the promotion mapping together with the entire Auralis-managed song package.
- Legacy Apple `Auralis/TrackCache` / internal LocalMusic download files keep working and are migrated lazily when the server track metadata can be resolved.

## Files-visible package on iOS/iPadOS

The app owns `Documents/LocalMusic`, exposed through `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` as:

`Files → On My iPhone/iPad → Auralis → LocalMusic`

A completed server download is normalized into a package such as:

```text
LocalMusic/
└── Artist - Title [identity]/
    ├── audio.flac
    ├── cover.jpg
    ├── lyrics.lrc
    └── metadata.json
```

The audio is mandatory. Artwork and lyrics are written when the server provides them; their absence does not invalidate the download. `metadata.json` records the user-facing track metadata and an internal download ownership marker plus remote server/track identity.

The LocalMusic scanner intentionally skips packages marked as download-managed. They are visible in Files but remain represented by their existing remote/download identity path in the unified catalog, preventing one downloaded song from appearing twice.

## Playback routing

Local identities must resolve to local file/content URIs and must never fall through to an OpenSubsonic connector. Remote aliases may still resolve to the promoted local file so an already-materialized queue can continue playback without rewriting every queue/history/playlist reference at download completion time.

TrackCacheStore accepts both legacy relative cache locations and managed-package absolute file locations. This lets old downloads continue working while newer/migrated downloads use the visible package without changing DownloadStore's status APIs.

## Migration and failure behavior

Old cached downloads are checked lazily when cached IDs are restored. If the corresponding server track can be resolved, Auralis obtains available metadata/artwork/lyrics and relocates the audio into a standard package. If the server is offline or enrichment cannot be resolved, the old cached file remains untouched and playable; migration can retry later.

For a newly completed download, package enrichment is best-effort. Failure to obtain artwork or lyrics is not a download failure. If the final package move itself fails, the completed internal cache remains available and the UI may report that organization into LocalMusic failed.

## Settings-only management

Local music source management is owned entirely by Settings. On iOS/iPadOS, Settings also exposes “导入歌曲”, which copies selected audio or a single-song folder into `Documents/LocalMusic` and normalizes recognized audio metadata, artwork, lyrics and metadata sidecars into the same standard package format.

macOS continues to use explicit security-scoped folder selection. Android continues to use persisted SAF tree URIs; this iOS/iPadOS Files-visible packaging change does not redefine Android storage behavior.

## Catalog integration

Unified catalog integration remains active:

- with an active server, Library/Search/Agent reads expose the active server plus true user-imported local files;
- without an active server, the user-facing catalog can become local-only;
- `auralis-local` remains an entity namespace rather than a fake server account;
- local identities are accepted by Agent grounding/entity validation, while identities from unrelated saved servers remain isolated;
- server-side mutations still use the real server-backed repository and are never routed through the local namespace;
- server-download packages in Files are storage materialization of an existing download identity, not an additional scanned local entity.
