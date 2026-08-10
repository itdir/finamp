# Mobile installers (personal builds)

Build sideload packages for Android phones and iPhones from this fork.

## One-command build

```bash
# Dev MacBook — Finamp repo root
cd /Users/macadmin/Development/finamp
./scripts/build-mobile-installers.sh
```

Outputs land in `dist/` (gitignored):

| Artifact | Purpose |
|----------|---------|
| `finamp-android-debug.apk` | Installs **alongside** Play Store / F-Droid Finamp (`…finamp.debug`) |
| `finamp-ios-development.ipa` | Development IPA for your Apple ID (requires Xcode signed in + device registered) |

Options:

```bash
SKIP_IOS=1 ./scripts/build-mobile-installers.sh              # Android only
SKIP_ANDROID=1 ./scripts/build-mobile-installers.sh          # iOS only
ANDROID_MODE=release ./scripts/build-mobile-installers.sh    # release APK (local keystore)
IOS_BUNDLE_ID=com.brianperkins.finamp IOS_TEAM_ID=F3E25E64U6 ./scripts/build-mobile-installers.sh
```

## Prerequisites

- Flutter 3.24.x (`flutter doctor` green for Android + Xcode)
- **JDK 17** for Android (`brew install openjdk@17`) — this project’s Gradle 7.6 does not support JDK 21/22
- Android SDK at `~/Library/Android/sdk` (script / `flutter config --android-sdk` sets this)
- Xcode 16.x with CocoaPods

## Install Android (Pixel / any device)

```bash
# Dev MacBook — USB debugging enabled on the phone
adb install -r dist/finamp-android-debug.apk
```

Or copy the APK to the phone and open it (allow install from that source).

## Install iPhone

### 1. Sign into Xcode (required once)

Xcode must have a valid Apple ID session. If `xcodebuild` reports `missing Xcode-Token` or **No Accounts**:

1. Open **Xcode → Settings → Accounts**
2. Add / re-authenticate **perkinsfam.bp@gmail.com** (Brian Perkins team `F3E25E64U6`)
3. Plug in **iPhone XS** via USB, trust the computer, and let Xcode register the device

### 2. Build the IPA

```bash
SKIP_ANDROID=1 ./scripts/build-mobile-installers.sh
```

The script temporarily overrides the upstream Finamp team/bundle id to:

- Team: `F3E25E64U6`
- Bundle ID: `com.brianperkins.finamp`

then restores `ios/Runner.xcodeproj/project.pbxproj` afterward.

### 3. Install the IPA

- Xcode → **Window → Devices and Simulators** → select iPhone → **+** under Installed Apps → choose `dist/finamp-ios-development.ipa`
- Or Apple Configurator 2 → Add → that IPA
- On iPhone: **Settings → General → VPN & Device Management** → trust the developer certificate

### Alternative: install directly over USB

```bash
flutter devices   # note the iPhone id
flutter run --release -d <iphone-device-id>
```

## Local signing overrides

`ios/Flutter/Local.xcconfig` is gitignored (see `Local.xcconfig.example`).  
`android/key.properties` + `*.jks` are already gitignored; release mode generates a local keystore automatically.
