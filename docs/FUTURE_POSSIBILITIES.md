# Future possibilities (Finamp fork)

Ideas that are **not** committed to current sideload OTA / Profile work.
Capture here so they are not lost; promote into an active topic branch when
scheduled.

## Index

| Item | Status | Detail |
|------|--------|--------|
| Self-hosted iOS signing, sideload, and provisioning-refresh | Design / planning (2026-08-16) | [future/self-hosted-ios-signing-handoff.json](future/self-hosted-ios-signing-handoff.json) |
| Stable / development update channel picker | Mentioned in [SIDELOAD_OTA.md](SIDELOAD_OTA.md); must keep integer build downgrade guard | — |

## Self-hosted iOS development & distribution

Zero-cost Personal Team architecture: MacBook develop → Linux CI orchestrate →
always-on Mac mini Xcode sign → NAS artifacts → Tailscale private IPA source →
AltStore-compatible install/refresh. Automate Apple’s free provisioning
lifecycle; do **not** try to bypass signing or 7-day expiration.

Full engineering handoff (JSON):  
[future/self-hosted-ios-signing-handoff.json](future/self-hosted-ios-signing-handoff.json)

Related today: [SIDELOAD_OTA.md](SIDELOAD_OTA.md), [MOBILE_INSTALLERS.md](MOBILE_INSTALLERS.md),
[IOS_SIDELOAD_DEBUG.md](IOS_SIDELOAD_DEBUG.md).
