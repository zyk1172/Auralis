# Local Music Unified Catalog

PR3 keeps server synchronization and true local files as separate sources of truth, then composes them at user-facing read boundaries.

- `auralis-local` is an entity namespace, not a `ServerAccount` and never owns OpenSubsonic credentials.
- With an active server, Library/Search/Agent reads expose that server plus true local files; other saved servers remain isolated.
- Without an active server, user-facing catalog reads are local-only, so Auralis remains a usable local player.
- Apple publishes security-scoped scan results to the in-memory `LibraryCatalog` and transactionally mirrors local artist/album/track rows into the existing SQLite catalog for Agent/FTS resolution.
- Android composes Room-backed remote data with the SAF local runtime through `UnifiedCatalogRepository`; remote mutations still use the original server-scoped repository.
- Semantic collision grounding always uses the unified playable catalog and never returns an LLM-only song that is absent from the real catalog.
- Local file identities may pass Agent entity validation, but identities belonging to a different saved server remain rejected.

This layer intentionally does not turn local files into a fake server and does not change the playback engines introduced before PR3.
