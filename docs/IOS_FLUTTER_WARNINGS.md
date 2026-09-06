# iOS Flutter CLI warnings (standing policy)

**Status:** in force until the retirement criteria below are met.  
**Audience:** humans and all coding agents working in this Finamp fork.  
**Canonical:** this file. Agent surfaces (`AGENTS.md`, `rules/project/`,
`.cursor/rules/`) must point here — do not invent a divergent policy.

## Summary (read this first)

| Flutter / Xcode message | Blocks launch / OTA today? | Agent action |
|-------------------------|----------------------------|--------------|
| UIScene lifecycle will soon be required | **No** — this fork already adopted UIScene | Do **not** “fix” by disabling scenes or treating the warning as a build failure. Verify device launch; optionally silence CLI only. |
| Plugins do not support Swift Package Manager (SPM) | **No** — CocoaPods still works | Do **not** flip the iOS project to SPM-only while listed plugins lack SPM. Track upstream / forks on Flutter upgrades. |

Neither warning explains MagicDNS, Embedded Tailscale, or Music Finder failures.
Do not derail feature work to “clear” these logs unless a **new** Flutter/Xcode
upgrade turns a warning into a hard error.

Upstream Flutter guide: [UIScene migration](https://flutter.dev/to/uiscene-migration).

---

## 1. UIScene lifecycle warning

### What Apple / Flutter mean

After iOS 26’s follow-on release, UIKit apps built with the latest SDK that have
**not** adopted UIScene will fail to launch. Flutter 3.38+ defaults to UIScene
and warns when auto-migration cannot prove a stock template.

### What this fork already has

- `UIApplicationSceneManifest` in `Info-Debug.plist`, `Info-Profile.plist`,
  `Info-Release.plist`
- `AppDelegate` conforms to `FlutterImplicitEngineDelegate` and registers
  plugins in `didInitializeImplicitFlutterEngine` (not a second headless
  engine’s `GeneratedPluginRegistrant` for phone UI)
- Phone window: `SceneDelegate` subclasses `FlutterSceneDelegate`
  (`ios/Runner/SceneDelegate.swift`)
- Release CarPlay: separate scene role + `flutter_carplay.FlutterCarPlaySceneDelegate`
  (see [IOS_SIDELOAD_DEBUG.md](IOS_SIDELOAD_DEBUG.md) § UIScene)

Flutter still prints the nag when `AppDelegate` / CarPlay setup is customized.
That is expected tooling noise, not proof that UIScene is missing.

### Required agent / human behavior

1. **Prefer device verification** over silencing: Debug/Profile/Release must
   launch; phone + (Release) CarPlay scenes must behave.
2. **Do not** disable UIScene by renaming the manifest key to
   `_UIApplicationSceneManifest` (Flutter’s temporary escape hatch) on
   builds you care about shipping or sideloading.
3. **Do not** reintroduce a second `FlutterEngine.run()` /
   `GeneratedPluginRegistrant` on a headless engine for phone UI — that
   steals `MPRemoteCommandCenter` from `audio_service` (Bluetooth / car skip).
4. Optional CLI quiet only (does **not** turn off UIScene):

```yaml
# pubspec.yaml — only if log spam is the problem
flutter:
  config:
    enable-uiscene-migration: false
```

5. When editing iOS launch / scenes, keep alignment with
   [flutter.dev/to/uiscene-migration](https://flutter.dev/to/uiscene-migration)
   and the CarPlay notes in [IOS_SIDELOAD_DEBUG.md](IOS_SIDELOAD_DEBUG.md).

---

## 2. Swift Package Manager (SPM) plugin warning

### What Flutter means

Flutter is moving iOS plugin integration toward SPM. Plugins that ship only
CocoaPods pods will eventually fail the build. Today the message is a
**warning**; builds still use CocoaPods (`ios/Podfile`, `use_frameworks!`).

### Plugins called out on this fork (as of 2026-09)

| Plugin | Role in Finamp |
|--------|----------------|
| `flutter_secure_storage` | Auth keys / secrets (Embedded Tailscale) |
| `flutter_carplay` | CarPlay (git fork) |
| `isar_flutter_libs` | Isar native libs (git fork) |
| `flutter_to_airplay` | AirPlay |
| `flutter_discord_rpc` | Discord RPC (multi-platform; iOS path warned) |

### Required agent / human behavior

1. **Do not** convert the Runner iOS project to SPM-only while any of the
   plugins above (or others Finamp depends on) lack SPM support — that would
   turn today’s warning into an immediate break.
2. On Flutter upgrades: re-read the build log; if SPM becomes a **hard error**,
   treat it as a blocking topic branch (`fix/` / `chore/`) — prefer upstream
   plugin releases, then update our git forks (`flutter_carplay`,
   `isar_flutter_libs`) to add SPM when needed.
3. Do not “fix” the warning by removing `flutter_secure_storage` or other
   critical plugins without an explicit, tested replacement.
4. CocoaPods remains the supported install path until retirement criteria
   (below) are met.

---

## Retirement criteria (when this policy may be deleted)

Delete or archive this doc **and** remove the matching agent rules only when
**all** of the following are true:

1. **UIScene:** Flutter no longer warns for this project’s customized
   AppDelegate/CarPlay setup **or** Apple’s requirement is irrelevant because
   the project’s minimum toolchain already requires UIScene and CI/device
   builds prove launch without the nag — and agents are not tempted to disable
   the scene manifest.
2. **SPM:** Every iOS plugin Finamp depends on supports SPM **and** the
   project has successfully built iOS with Flutter’s SPM path (or Flutter has
   abandoned the SPM mandate — update this doc if that happens).

Until then: keep this file, keep `AGENTS.md` / `rules/project/` /
`.cursor/rules/` pointers, and keep `alwaysApply` (or equivalent) on the agent
rule so new sessions inherit the policy.

---

## Related

- [IOS_SIDELOAD_DEBUG.md](IOS_SIDELOAD_DEBUG.md) — Profile sideload, CarPlay, UIScene engine rules
- [SIDELOAD_OTA.md](SIDELOAD_OTA.md) — OTA / remote-command note → UIScene
- [EMBEDDED_TAILSCALE.md](EMBEDDED_TAILSCALE.md) — secure storage for auth keys
- Flutter: [UIScene migration](https://flutter.dev/to/uiscene-migration)
