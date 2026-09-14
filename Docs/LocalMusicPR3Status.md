# PR3 integration scope

This is the third stacked local-music PR on `feat/local-music-foundation`.

It integrates true local files into the existing user-facing catalog without changing the playback engine or pretending local storage is an OpenSubsonic server. Apple and Android expose local tracks through Library, Search and Agent read boundaries; semantic-collision recommendation grounding sees the same playable catalog. A no-server state remains usable as a local-only music library. Remote mutation coordinators stay bound to real server-backed repositories.

PR3 must pass Apple and Android CI before being merged into PR1. PR1 is not merged to `main` as part of this work.
