# Sideload OTA (fork)

Self-hosted updates for personal Profile builds via GitHub Releases on
`itdir/finamp`. **Android** can silent-install after one-time setup. **iOS**
(personal team) can only notify and point at SideStore / USB — never silent
install without a paid Apple program.

## Versioning

`pubspec.yaml` uses upstream base + channel suffix:

| Example | Meaning |
|---------|---------|
| `0.9.25-sideload.1+127` | Upstream `0.9.25`, first sideload revision, build `127` |
| `0.9.25-sideload.2+128` | Another fork-only drop |
| `0.9.26-sideload.1+141` | After sync to upstream `0.9.26+140` |

OTA compares the **integer** after `+` only (`latest.json` → `build`).

## Publish (Dev MacBook)

```bash
cd /Users/macadmin/Development/finamp
# Optional: bump -sideload.N and +build
BUMP=1 ./scripts/publish-sideload-release.sh

# Or publish current pubspec version:
./scripts/publish-sideload-release.sh
```

Produces under `dist/` (gitignored):

- `finamp-android-profile.apk` (`applicationId` `…finamp.profile` — not `.debug`)
- `finamp-ios-profile.ipa`
- `latest.json`
- `sideload-source.json` (SideStore)

Uploads a version tag (`v0.9.25-sideload.1+127`) **and** refreshes floating
release/tag **`sideload-latest`** so the app’s baked URL stays stable:

`https://github.com/itdir/finamp/releases/download/sideload-latest/latest.json`

Useful flags: `SKIP_IOS=1`, `SKIP_ANDROID=1`, `SKIP_UPLOAD=1`, `NOTES='…'`,
`GITHUB_REPO=itdir/finamp`.

Also see [MOBILE_INSTALLERS.md](MOBILE_INSTALLERS.md) for USB bootstrap /
emergency `adb install -r`.

## Android signing key (critical)

Silent update only works if every OTA APK is signed with the **same** key as
the installed app.

- Local (gitignored): `android/upload-keystore.jks` + `android/key.properties`
- **Backup:** Bitwarden / Vaultwarden Secure Note named  
  **`Finamp sideload Android keystore`**  
  Attach the `.jks`, and store `storePassword`, `keyPassword`, `keyAlias`, plus
  a one-line reminder of `applicationId` (`com.unicornsonlsd.finamp.profile`
  for Profile).
- Do **not** commit the keystore or `key.properties`.
- Mixing `adb` debug signing vs this keystore → `UPDATE_INCOMPATIBLE` /
  full uninstall.

The publish script generates a local keystore if missing; copy it into Bitwarden
immediately.

## In-app Settings → Updates

- **Automatic** (default): at configured local time (default **3:33 AM**),
  fetch manifest; on Android download + silent `PackageInstaller` when allowed.
- **Manual:** Check now only.
- Wi‑Fi / unmetered by default; optional cellular.
- Defers silent install while music is playing; catch-up on next launch if the
  alarm was deferred (Doze does not promise second-accurate delivery).

### One-time Android setup

1. Turn on **Allow Finamp to install updates** if asked.
2. Tap **Finish setup (one time)**. The app downloads the published APK even if
   you are already on that version, then Android asks you to tap **Install**.
   (USB/`adb` installs do not make Finamp the installer of record — this step
   does. Needed once so later overnight updates can install quietly.)
3. After that, overnight automatic updates can run quietly.

The published manifest must be the **same build or newer** than the installed
app before step 2 can download or install anything. An older feed is blocked
with both build numbers shown. This also protects deferred APKs that were
downloaded before a newer build was installed by USB. This guard ships in
**0.9.25-sideload.9+135** and later.

Normal automatic/manual updates require a strictly newer build. Only
**Finish setup** may reinstall the same build, because that one confirmation is
what makes Finamp the installer of record. A future stable/development channel
picker may choose a different manifest, but it must keep this integer build
guard; selecting a channel must never authorize a downgrade.

Emergency: `adb install -r dist/finamp-android-profile.apk` may require
finishing setup again (step 2).

## iOS (personal team)

Same check / notify UX. Auto does **not** install the IPA.

### Recommended: USB from a Mac

1. Plug the iPhone into the Mac.
2. From the Finamp repo:

```bash
./scripts/install-ios-profile.sh
```

That builds Profile (unless `SKIP_BUILD=1`) and upgrades **in place** so Trust
usually stays. Do **not** use `flutter install` (it uninstalls first and can
drop the personal-team Trust profile).

In **Settings → Updates** the phone shows these steps and a button to copy the
script command.

### Optional: SideStore

Only if you already use SideStore. Publish must include a real
`finamp-ios-profile.ipa` so `latest.json` has non-empty `ios.sha256` /
`sizeBytes` and `sideload-source.json` lists the app. The in-app SideStore
button appears only then — it is not a setup guide for SideStore itself.

Weekly / 7-day personal cert refresh is still required; version OTA does not
refresh code signing.

## Troubleshooting

### “Update check already running”

A previous check started and never finished. Until build **134**, that could
happen forever: the APK body download had no stall timeout, and
`PackageInstaller` status waits had no deadline, so the in-memory busy lock
never cleared.

**Immediate recovery on an older build:** force-quit Finamp (swipe away from
recents), reopen, then tap **Check for updates** again on Wi‑Fi. The lock is
in memory only.

From **0.9.25-sideload.8+134** onward: a stalled download fails after 60s
without progress, installs time out after 5 minutes, and a stale busy lock
is cleared after 40 minutes. The Updates screen also shows download percent
for the large Profile APK.

## Public fork + Release assets

`itdir/finamp` is a **public** fork of `finamp-app/finamp`. Phones can download
Release assets over HTTPS without a GitHub token once you publish
`sideload-latest`.

## Private GitHub repos (if you ever go private)

Phones cannot download **private** Release assets without auth. Prefer:

- Keep the fork (or a sibling artifacts repo) **public** for releases, **or**
- Optional read-only token in secure storage (never commit secrets). Document
  any token-based download if you enable it later.

## Manifest shape

See `dist/latest.json` after a publish. Fields used by the app:

- `version` (display), `build` (int compare), `notes`
- `android.apkUrl` / `sha256` / `sizeBytes`
- `ios.ipaUrl` / `sha256` / `sideStoreSourceUrl`
