# Contributing to Auralis

Auralis welcomes reviewable improvements to the complete source tree. The project source is
licensed under `GPL-3.0-only`; see [`LICENSE`](LICENSE). There is no private core or separate
implementation withheld from the repository.

## Before opening a pull request

1. Fork the repository and create a focused branch from the current `main`.
2. Read the relevant module documentation and keep unrelated local changes out of the patch.
3. Preserve the existing architecture unless a change has a clear engineering benefit. In
   particular, playback must remain independent from optional AI and haptic analysis work.
4. Run the applicable SwiftPM tests, app builds, Android tests/builds, localization checks, and
   secret checks. Record commands and any environment-dependent gaps in the pull request.
5. Keep commits focused and describe behavior changes, compatibility impact, and follow-up work.

## Code and review expectations

- Use the existing Swift, SwiftUI, Kotlin, and project formatting conventions.
- Add regression coverage for player, library, Agent, or haptics behavior that changes.
- Keep audio playback higher priority than haptic analysis. Haptic errors must remain isolated
  from the audio thread, AudioSession, and main-thread responsiveness.
- Do not add artificial limits that reduce the existing Agent tool registry, dynamic tool loading,
  context recovery, playlist operations, search, or library capabilities.
- Explain platform-specific behavior and distinguish local build evidence from device or live
  service evidence.

## Content and licensing rules

Contributors must have the right to submit every part of their contribution and agree that the
contribution is released under `GPL-3.0-only`. Do not submit:

- API keys, passwords, bearer tokens, private certificates, signing keys, provisioning profiles,
  exported Keychain data, cookies, or authenticated URLs;
- user data, private server data, internal network details, or personal absolute paths;
- commercial music, album artwork, artist photographs, fonts, illustrations, or sound effects
  without a clear right to redistribute them;
- code copied from another project when its license is absent, incompatible, or its required
  attribution has not been preserved.

When adding third-party code or a dependency, record its exact source, version, license, notices,
and distribution obligations in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). Do not change
another project's copyright or license header. Do not add a dependency that requires a private
repository or a contributor's personal credential for ordinary fork CI.

The project does not require a blanket CLA or copyright assignment at this time. A future
commercial dual-license program would need a separate, explicit rights arrangement for code whose
copyright is held by other contributors; submitting a GPL contribution alone does not silently
grant that additional right.

## Issues and pull requests

Use issues for reproducible bugs, feature proposals, and documentation gaps. A pull request
should include a concise summary, affected platforms, verification commands, known limitations,
and any security, privacy, media-rights, or third-party-license implications. Never disclose a
secret or private user data in a public issue; use [`SECURITY.md`](SECURITY.md) for vulnerabilities.
