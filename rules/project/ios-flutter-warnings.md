# iOS Flutter warnings — agent standing policy

Canonical detail: [docs/IOS_FLUTTER_WARNINGS.md](../../docs/IOS_FLUTTER_WARNINGS.md).

**In force until** the retirement criteria in that doc are satisfied. Do not
delete this rule early.

## Non-negotiable

When Flutter/Xcode prints:

1. **UIScene lifecycle will soon be required**  
   - This fork **already** uses UIScene (`SceneDelegate`, scene manifests,
     `FlutterImplicitEngineDelegate`).  
   - **Do not** treat the warning as a missing migration or build failure.  
   - **Do not** disable UIScene via `_UIApplicationSceneManifest`.  
   - **Do not** register plugins on a second headless `FlutterEngine` for phone
     UI (steals `MPRemoteCommandCenter` / skip buttons).  
   - Optional: silence CLI only with `flutter.config.enable-uiscene-migration:
     false` — that does **not** turn off UIScene.

2. **Plugins do not support Swift Package Manager**  
   - Warning only while CocoaPods works (`ios/Podfile`).  
   - **Do not** switch the iOS project to SPM-only while
     `flutter_secure_storage`, `flutter_carplay`, `isar_flutter_libs`,
     `flutter_to_airplay`, `flutter_discord_rpc` (or other Finamp iOS deps)
     lack SPM.  
   - On Flutter upgrade, if SPM becomes a **hard error**, open a dedicated
     fix branch; prefer upstream/fork SPM adoption over removing critical
     plugins.

3. **Do not** blame MagicDNS / Embedded Tailscale / Music Finder bugs on these
   warnings, and do not block feature OTA on “clearing” them.

## When editing iOS

Re-read [docs/IOS_FLUTTER_WARNINGS.md](../../docs/IOS_FLUTTER_WARNINGS.md) and
[docs/IOS_SIDELOAD_DEBUG.md](../../docs/IOS_SIDELOAD_DEBUG.md) § UIScene before
changing `AppDelegate`, scene manifests, or Podfile/SPM settings.
