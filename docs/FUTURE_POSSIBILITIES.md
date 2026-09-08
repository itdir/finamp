# Future possibilities (Finamp fork)

Ideas that are **not** committed to current sideload OTA / Profile work.
Capture here so they are not lost; promote into an active topic branch when
scheduled.

## Index

| Item | Status | Detail |
|------|--------|--------|
| Self-hosted iOS signing, sideload, and provisioning-refresh | Design / planning (2026-08-16) | [future/self-hosted-ios-signing-handoff.json](future/self-hosted-ios-signing-handoff.json) |
| Stable / development update channel picker | Mentioned in [SIDELOAD_OTA.md](SIDELOAD_OTA.md); must keep integer build downgrade guard | — |
| iOS plugins → Swift Package Manager | Deferred — CocoaPods until Flutter hard-errors or all deps support SPM | Standing policy: [IOS_FLUTTER_WARNINGS.md](IOS_FLUTTER_WARNINGS.md) §2 |
| Roku OS as a Flutter target | Exploratory — not scheduled | See § Roku OS below |

## Self-hosted iOS development & distribution

Zero-cost Personal Team architecture: MacBook develop → Linux CI orchestrate →
always-on Mac mini Xcode sign → NAS artifacts → Tailscale private IPA source →
AltStore-compatible install/refresh. Automate Apple’s free provisioning
lifecycle; do **not** try to bypass signing or 7-day expiration.

Full engineering handoff (JSON):  
[future/self-hosted-ios-signing-handoff.json](future/self-hosted-ios-signing-handoff.json)

Related today: [SIDELOAD_OTA.md](SIDELOAD_OTA.md), [MOBILE_INSTALLERS.md](MOBILE_INSTALLERS.md),
[IOS_SIDELOAD_DEBUG.md](IOS_SIDELOAD_DEBUG.md).

## Roku OS (exploratory)

**Intent:** try adding **Roku OS** as a target for this Flutter Finamp fork.

**Status:** not scheduled — research spike only. No `roku/` platform folder or
CI yet.

**Agent caveat:** Flutter does **not** officially support Roku. Roku apps use
BrightScript / SceneGraph. Do **not** assume `flutter create`, stock plugins,
or a normal multi-platform fold-in will work. A spike may conclude: custom
embedder (unlikely short-term), a **separate** Roku client outside Flutter, or
abandon. Document findings here before writing production code.
