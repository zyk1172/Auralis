# Auralis open-source audit

## Scope and conclusion

This repository contains the complete Auralis application source, including the Apple apps,
the local `AuralisCore` Swift package, tests, Agent runtime, playlist/library tools, Music Haptics
implementation, and the Android implementation under `android/`. There is no source-only split,
binary core, or private dependency required to build the project.

The local Swift package boundaries remain because they provide useful compile-time ownership,
dependency direction, test isolation, and platform separation. They are engineering modules in
this repository, not a license boundary or a second repository.

The project source is licensed under `GPL-3.0-only`. This file is an engineering inventory, not
legal advice; the exact rights and obligations are in [`LICENSE`](../LICENSE) and in each
dependency's own license.

## Source and platform inventory

| Area | Location | Distribution status |
| --- | --- | --- |
| Apple app targets | `Apps/` and `Auralis.xcodeproj` | Project source; local signing team is selected by each developer |
| Swift package modules | `Packages/AuralisCore/` | Complete project source, including Agent, library, playback, and haptics modules |
| Swift package tests | `Packages/AuralisCore/Tests/` | Complete project tests and checked-in test fixtures |
| Android implementation | `android/` | Project source; dependencies are resolved from public Maven repositories |
| Build and audit scripts | `Scripts/`, `.github/workflows/` | Project-owned automation; no private credential is required for normal CI |
| Brand assets | `Apps/Shared/AppIcon.icon/`, app icon asset catalogs | Kept as official project assets, separate from source-code licensing; see `TRADEMARKS.md` |

## License and copyright checks

- `LICENSE` is the unmodified GNU General Public License, version 3, 29 June 2007.
- Repository declarations use `GPL-3.0-only`; the project does not add a non-commercial or
  anti-commercial restriction.
- Project-owned source files carry `SPDX-License-Identifier: GPL-3.0-only` where a header is
  appropriate. Generated provenance, dependency wrappers, platform metadata, and third-party
  material are excluded from mechanical header insertion.
- The current Git history is authored under the repository owner identity in the local audit.
  That is useful evidence for a future rights review, but it is not a legal chain-of-title
  opinion. Contributors and copied material still need individual provenance checks.
- A future commercial license can cover only code for which the licensing party has the necessary
  rights. Contributions accepted under GPL alone do not silently grant a separate commercial
  relicensing right; see `CONTRIBUTING.md`.

## Dependencies and intake rule

The Swift Package Manager manifest has no external Swift package dependency. Apple SDKs are
platform dependencies, not project-owned source. The Android direct dependencies and their
licenses are recorded in [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

Before adding a dependency, record its exact version, source URL, license text or authoritative
license link, transitive obligations, modifications, binary provenance, security advisories,
platform requirements, and removal plan. Preserve upstream copyright and license notices. A
dependency must not require a private repository or a maintainer's personal credential for an
ordinary fork to resolve, build, and test.

## Runtime services and data

OpenSubsonic/Navidrome is an interoperability protocol and remote service, not copied source in
this repository. AI providers, server content, album artwork, lyrics, and user music are external
data or services and must be handled under their own terms. The repository must not include
authenticated URLs, user libraries, commercial music, or remote artwork as test assets.

The checked-in FLAC fixture used by Music Haptics tests is a short project test fixture without
album artwork or artist metadata. It must remain a redistributable test asset and must not be
replaced with a commercial recording.

## Ongoing release checks

Before changing repository visibility or making an official release, repeat the current-tree and
history secret scan, dependency inventory, media review, Apple signing/entitlement review, and
the build/test matrix. Keep the generated Xcode project synchronized with `project.yml`, and
review any generated provenance changes separately from authored source changes.
