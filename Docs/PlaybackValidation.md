# Playback validation

## Architecture and guarantees

- `AVFoundationPlaybackEngine` owns one `AVQueuePlayer`, one current item and at most one prepared next item.
- Queue edits, shuffle, repeat and sleep-timer changes invalidate and recompute that prepared item.
- A prepared transition updates `AuralisAppModel` and Now Playing state without calling `play(track:)` again.
- Manual previous/next, a stale stream URL and a queue change at the item boundary still use the normal guarded playback path.
- End, failure, stall and time-control callbacks are scoped to a playback generation. A delayed callback from a replaced item cannot mutate the new item.
- Interruption and route observers replace any prior observer. Remote command targets are registered once.

### Gapless classification

The implementation is **best-effort seamless**. It removes Auralis-created delays, pre-creates the next `AVPlayerItem`, lets `AVQueuePlayer` buffer it, and does not tear down the player at a prepared boundary. It is not described as sample-perfect true gapless: remote HTTP behaviour, server transcoding, codec/container priming and AVFoundation can still introduce an audible boundary. No crossfade is applied.

Local compatible files and untranscoded streams are the strongest candidates for an inaudible transition. The true-device listening matrix remains `MANUAL-VERIFY`.

## ReplayGain

The client decodes the OpenSubsonic `Child.replayGain` values `trackGain`, `albumGain`, `trackPeak`, `albumPeak`, `baseGain` and `fallbackGain`. Modes are Off (default), Track and Album. Conversion uses `10^(dB/20)`; optional preamp is limited to -12...+12 dB and peak protection caps the multiplier to `1 / peak`.

Missing or invalid metadata produces unity gain. It is never replaced with generic normalization. `AVPlayer.volume` applies attenuation exactly and positive gain only within available volume headroom; Auralis does not claim a DSP boost beyond full scale.

Reference: [OpenSubsonic ReplayGain response](https://opensubsonic.netlify.app/docs/responses/replaygain/).

## Automated coverage

- ReplayGain off, track, album, fallback, missing/invalid, zero gain, preamp and peak protection.
- OpenSubsonic ReplayGain decoding into `Track.sourceInfo`.
- Linear next-item preparation.
- Invalidation for shuffle, repeat-one and sleep-after-current-track.
- Prepared transition updates model and prepares the following track without a second `play(track:)` call.
- Existing repeat-one/repeat-all, scrobble, failure recovery, remote command and queue tests remain regression coverage.

## True-device validation

Run the matrix in `Docs/ManualValidation.md` on an iPhone/iPad with the real NAS, wired/Bluetooth/AirPlay outputs and both LAN/WAN paths. Record OS build, server version, codec/container, source (local/remote/transcoded), observed gap and diagnostics. Listening results cannot be certified by unit tests or a simulator.
