# Manual validation

Items below are intentionally marked `MANUAL-VERIFY`; they require the real device, audio route, network and server. Automated tests validate state machines and calculations, not audible continuity or iOS background policy.

## Playback lifecycle

- [ ] `MANUAL-VERIFY` Start playback, pause, resume, seek and stop from the app.
- [ ] `MANUAL-VERIFY` Continue through at least 30 queue items without duplicate or skipped transitions.
- [ ] `MANUAL-VERIFY` Background the app for 30 minutes; verify uninterrupted audio and correct lock-screen metadata.
- [ ] `MANUAL-VERIFY` Lock the device and use play/pause/previous/next/seek from Control Center.
- [ ] `MANUAL-VERIFY` Force-quit after pausing; relaunch and verify queue/current item/progress restore without auto-playing.
- [ ] `MANUAL-VERIFY` Repeat One, Repeat All, queue-end Off and Shuffle at the first/middle/last item.
- [ ] `MANUAL-VERIFY` Sleep timer: minutes, current track, current album and current queue.

## Interruptions and routes

- [ ] `MANUAL-VERIFY` Incoming call/Siri interruption pauses; resume only when iOS supplies `shouldResume`.
- [ ] `MANUAL-VERIFY` Unplug wired headphones and disconnect AirPods; audio pauses instead of moving unexpectedly to speakers.
- [ ] `MANUAL-VERIFY` Switch speaker, wired, AirPods/Bluetooth and AirPlay routes while foregrounded and backgrounded.

## Network and recovery

- [ ] `MANUAL-VERIFY` Wi-Fi to cellular and cellular to Wi-Fi during playback.
- [ ] `MANUAL-VERIFY` LAN endpoint failure falls back to WAN without duplicate playback starts.
- [ ] `MANUAL-VERIFY` Stop the NAS mid-track, restore it, and verify bounded recovery/error behaviour.
- [ ] `MANUAL-VERIFY` Restart Navidrome and verify expired stream URLs refresh once and recover.
- [ ] `MANUAL-VERIFY` Play a downloaded local item while the NAS is unavailable.
- [ ] `MANUAL-VERIFY` Download several items while another remote/local item is playing.

## Seamless transitions

- [ ] `MANUAL-VERIFY` Same-codec local FLAC live album, continuous classical movements, DJ mix and concept album.
- [ ] `MANUAL-VERIFY` Same scenarios over untranscoded LAN streaming.
- [ ] `MANUAL-VERIFY` WAN/transcoded streams; record any audible boundary as best-effort limitation.
- [ ] `MANUAL-VERIFY` Edit/reorder/remove the next queue item immediately before a boundary.
- [ ] `MANUAL-VERIFY` Manual Next during prebuffer, Shuffle and Repeat changes during prebuffer.
- [ ] `MANUAL-VERIFY` Confirm there is no crossfade or overlapping audio.

## ReplayGain

- [ ] `MANUAL-VERIFY` Off is bit-for-bit behaviourally unchanged apart from normal player volume.
- [ ] `MANUAL-VERIFY` Track mode evens loudness between tagged tracks.
- [ ] `MANUAL-VERIFY` Album mode preserves relative dynamics within one tagged album.
- [ ] `MANUAL-VERIFY` Untagged tracks are not normalized.
- [ ] `MANUAL-VERIFY` Peak protection prevents clipping on a tagged positive-gain test track.
- [ ] `MANUAL-VERIFY` Compare local file and remote stream of the same track.

## UI and memory while playing

- [ ] `MANUAL-VERIFY` Rapidly scroll Home and Library during playback; no audio interruption or sustained frame drop.
- [ ] `MANUAL-VERIFY` Open/close Now Playing, Lyrics and Queue repeatedly; observers/timers do not multiply.
- [ ] `MANUAL-VERIFY` Run for two hours and inspect memory pressure, artwork cache eviction and playback continuity.
