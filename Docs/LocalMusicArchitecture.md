# Local music architecture

Local music is a first-class music source, not a second player and not an OpenSubsonic server impersonation.

## Ownership

- All source management lives under **Settings → Local Music** on Apple, Android mobile and Android TV.
- Existing library/player screens consume unified catalog results; they do not own folder permissions.
- Platform location tokens are opaque. Apple may persist security-scoped bookmarks; Android persists SAF/MediaStore URIs.
- Playback URLs are resolved just in time through `PlaybackSourceReference`.

## Download promotion contract

PR2 promotes a completed server download into the configured local-music library instead of leaving it in a private cache. Promotion creates a `TrackIdentityTransition` from the old `(serverID, trackID)` to the canonical local track ID. The old remote identity remains a resolvable alias so active queues, history and playlists do not break during or after the transition.

## Delivery sequence

1. PR1: source/identity/playback contracts plus Settings-only management surface.
2. PR2: platform source authorization, scanner/metadata ingestion, local playback, server-download promotion and alias persistence.
3. PR3: unified catalog/search/library/Agent/recommendation consumption.
