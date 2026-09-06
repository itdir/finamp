# Finamp fork — agent instructions

> **AI agents:** Read this file and **`rules/`** (including **`rules/project/`**)
> before substantive edits in this repository.

## First session / new agent

1. Read **`rules/project/ios-flutter-warnings.md`** — standing UIScene + SPM policy
   (also [docs/IOS_FLUTTER_WARNINGS.md](docs/IOS_FLUTTER_WARNINGS.md)).
2. For iOS sideload / Profile / CarPlay: [docs/IOS_SIDELOAD_DEBUG.md](docs/IOS_SIDELOAD_DEBUG.md).
3. For Embedded Tailscale / MagicDNS: [docs/EMBEDDED_TAILSCALE.md](docs/EMBEDDED_TAILSCALE.md).
4. For OTA publishing: [docs/SIDELOAD_OTA.md](docs/SIDELOAD_OTA.md).

## Rule book (this fork)

| Path | Topic |
|------|--------|
| `rules/project/ios-flutter-warnings.md` | UIScene CLI nag + CocoaPods/SPM — do not “fix” incorrectly |
| `docs/IOS_FLUTTER_WARNINGS.md` | Full policy + retirement criteria |

Cursor loads the same policy via `.cursor/rules/ios-flutter-warnings.mdc`
(`alwaysApply: true`) until retirement criteria in the doc are met.

## Branching (this fork)

- Work on topic branches (`feat/`, `fix/`, `wip/`, `docs/`, `chore/`).
- Do not commit on the default branch without an explicit request.
- After substantive edits on a topic branch: commit and push unless the user
  says not to. Never merge to the default branch unless explicitly asked.

## Do not commit

- `ios/Flutter/Local.xcconfig`, `*.bak`, unrelated `Podfile.lock` / SPM
  `Package.resolved` churn unless the change-set intentionally updates iOS deps.
- Secrets, keystores, auth keys, OAuth client secrets.

## Org standards

This personal Finamp fork may not vendor the full highgearme/dev-standards
book. When editing **other** HighGear / LCT repos in the same workspace, follow
**that** repo’s `AGENTS.md` / `rules/` — not this file alone.
