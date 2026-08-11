# External music data

## Scope

Auralis uses open MetaBrainz services only to enrich a single song when the user opens **歌曲信息** or invokes **歌曲鉴赏**. It never scans the whole library at launch and does not build accounts, social features, public comments or rankings.

## Persistent identity

`ExternalMusicIdentity` is stored in `catalog.sqlite` and keyed by the full server-scoped `GlobalID`. It can preserve recording, release, release-group and artist MBIDs, ISRC, match method, confidence and verification date. This avoids collisions when two servers reuse the same remote track ID.

Matching order is:

1. an already-bound recording MBID;
2. a stored ISRC;
3. title + artist + duration;
4. album/version metadata;
5. conservative fuzzy similarity.

Version markers such as Live, Remaster, Deluxe, Instrumental and Cover reduce confidence when they disagree. Confidence `>= 0.90` may bind automatically; `0.65 ..< 0.90` is retained only as a candidate; lower results are ignored. An identity imported by a future server metadata adapter can be seeded with MBID or ISRC without changing this pipeline.

## Sources and meanings

Every provider is persisted and displayed separately. Auralis does not manufacture a combined score.

- **MusicBrainz**: recording rating and vote count.
- **CritiqueBrainz**: release-group average rating, rating count and review count.
- **ListenBrainz**: release-group listen count and listener count when the endpoint supplies it.
- **我的评分**: remains private LocalCatalog/track state and is never presented as a community value.

Last.fm is only a possible future provider and is not a dependency.

## Fetching, caching and failures

- Successful and confirmed no-data responses are cached in SQLite for 14 days (within the required 7–30 day window).
- Rate-limit results retry only after a short cache window; network/timeout failures use a shorter five-minute window.
- Requests are cancellable, have a 15-second timeout and a meaningful `Auralis/<version>` User-Agent.
- MusicBrainz requests are serialized to an average interval of at least 1.05 seconds.
- HTTP, rate-limit, timeout, cancellation, network and decoding failures are classified. A provider failure never blocks playback or fabricates a value.

The song information sheet shows a loading state only for an explicit open. The Agent receives provider-specific Evidence with entity ID and verification date. If no source is verifiable, the required output is exactly: `暂无可核验的大众评价数据。`

## Privacy and limitations

Only the selected song's title, artist, album and duration, or an already stored MBID/ISRC, are used for matching. Stream URLs, credentials, lyrics, the whole catalog, listening history and local paths are not sent to these providers.

Public databases are incomplete and can contain ambiguous releases. Medium-confidence matches are intentionally not bound. Listen and rating figures describe different populations and times, so cross-provider comparison is informational rather than statistical equivalence.

## Automated coverage

- SQLite identity, candidate and provider-metric round trips with server isolation.
- High-confidence metadata match and 14-day cache reuse.
- Medium-confidence candidate retention without automatic binding.
- ISRC-first resolution.
- Provider separation, meaningful User-Agent and source-specific counts.

## Manual verification

Real public endpoints and their current datasets require the `外部音乐数据真机验证` item in `Docs/ManualValidation.md`. Automated fixtures verify contracts but cannot certify that a specific public recording currently has ratings or listener statistics.
