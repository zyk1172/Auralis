# Android UI parity with iOS PR #67

Source: https://github.com/zyk1172/Auralis/pull/67 (reviewed head `d0e9eac`).
Android branch: `feat/android-ios67-ui-parity`, based on `main` at `9527766`.
This branch contains Android changes only; the iOS corrections were pushed to PR #67 separately.

## UI mapping

| iOS change | Android implementation |
| --- | --- |
| 60pt Home title follows upward scrolling and clips before the status bar | `AppleParityHomeScreen` title overlay, fixed content reservation and tested `HomeTopHeaderPolicy` |
| Unified Library / Assistant titles | Fixed 60dp Library header and Assistant title with provider status below it |
| Full-screen Now Playing with dismiss handle | Existing full-screen shell overlay, accessible 44dp dismiss target and downward drag |
| Landscape artwork left, controls / lyrics / queue right | `NowPlayingChromeLayout` uses the actual window constraints; rotation preserves pager state |
| Bottom lyrics / queue toggles return to artwork on second tap | `PlayerBottomNavigation`, selected semantics, horizontal pager and native Android audio route chooser |
| Playing artwork expands; paused artwork shrinks | Animated 1.0 / 0.82 scale without changing measured bounds |
| Lyrics hides chrome after five seconds or an upward swipe; downward swipe / tap reveals it | Local activity timer and observation of unconsumed pointer events |
| Active lyrics characters emphasize progress between adjacent line timestamps | A local 30fps clock, grapheme-safe character flow, no fabricated word timestamps and static reduced-motion presentation |
| Stable scroll viewport while Dock animates | Maximum fixed Dock reservation, 500ms terminal animation, Assistant composer moves with an offset |
| 24-song random batches and 50-song recent playback | Domain batch constant, Home and recent detail queries |

Transport buttons now use the same `PlaybackCapabilities` as the shell, including repeat-mode navigation. Seeking state resets when track identity changes.

## PR #67 review corrections

- Preserve shuffle history when a provisional logical queue becomes a full queue with new occurrence UUIDs; add a regression test proving all occurrences play exactly once.
- Supply local silent WAV audio for the Now Playing UI smoke fixture. Transport actions previously entered the production missing-stream error path and could raise an alert over the player.
- Pause and seek before testing Previous, so the test checks queue navigation rather than the intentional restart-after-three-seconds behavior.
- Gate Dock endpoint decisions on an interacting scroll phase, excluding idle layout changes and deceleration settling.

## Validation

```sh
cd android
./gradlew testDebugUnitTest :app-mobile:assembleDebug :app-tv:assembleDebug
./gradlew :app-mobile:assemblePerf :app-tv:assemblePerf
```

The full Debug run passed 242 tests across 41 suites, including four Robolectric Compose UI tests for portrait controls, landscape geometry, immersive lyrics and bottom-button toggles. Debug and R8-optimized `perf` APKs for mobile and TV built successfully, including release lint checks.

The managed cloud session needs its proxy and CA settings passed to forked Robolectric JVMs as well as Gradle. Its local init script is `/workspace/.onboarding/auralis/test-network.init.gradle`; this is environment configuration, not an application change.

A pre-existing Anthropic cancellation test was made deterministic with `SocketPolicy.NO_RESPONSE`, retaining the 300ms coroutine deadline and five-second recovery / connection-close assertions. A delayed response could otherwise race cancellation on a busy CI runner.

The Home invalidation regression now waits for the favorite emission before recording a play. Room may coalesce adjacent writes, so expecting one emission per unobserved write made the existing test race on CI.

Apple validation passed in PR #67's Xcode CI, including the iOS UI smoke suite; this Linux environment has no Apple toolchain. Hardware audio routing and haptics still require device validation.
