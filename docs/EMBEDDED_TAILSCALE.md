# Embedded Tailscale (tsnet)

Fork-only feature: Finamp can join your tailnet **in-process** via
[`package:tailscale`](https://pub.dev/packages/tailscale) (upstream Go `tsnet`).
This is **not** a system VPN, so it can coexist with ExpressVPN on iOS/Android.

## Why

iOS and Android allow only one system VPN profile at a time. The official
Tailscale app and ExpressVPN cannot both be active. Userspace `tsnet` speaks
WireGuard-over-UDP from inside Finamp and leaves the OS routing table alone.

## User flow

1. Settings → **Embedded Tailscale**
2. Paste a Tailscale **auth key** (`tskey-auth-…` from the admin console).
   On **iOS/Android**, an auth key is **required** — interactive browser login
   is disabled (it can abort the app via an empty `NSUserActivity` / autofill
   path). Prefer a reusable / tagged key.
3. Enable **Connect via embedded Tailscale** (or tap Connect). First connect
   uses the auth key (and briefly sets `TSNET_FORCE_LOGIN=1` so tsnet does not
   ignore the key on `NoState`). Later app launches **resume from disk without
   re-submitting the key** — that is what makes MagicDNS work immediately
   without opening Settings.
4. Status should become **Running** with a tailnet IP. Until then MagicDNS
   names like `*.ts.net` will fail lookup and downloads may pause
   (“Connection interrupted”).
5. Set the Jellyfin server URL to a MagicDNS name, e.g.
   `https://jellyfin.tailnet.ts.net:8096`
   (the login screen still normalizes the common `jellyfin@tailnet` typo)
6. Jellyfin API calls (Chopper), library `getItems`, cover-art cache downloads,
   **Music Finder** health/search/add, and **Network → Test both connections**
   go through `FinampHttpClient` / tsnet when embedded Tailscale is Running.

Library browsing uses a background isolate with a plain `IOClient` when
Tailscale is **off**. When Embedded Tailscale is on (or the active URL is
MagicDNS / `100.x`), those calls stay on the **main isolate** so they use
`FinampHttpClient`. Otherwise you can pass Network Test while albums fail to
load.

**Not routed through FinampHttpClient** (OS / media stacks): streaming playback
(`just_audio` → native AVPlayer / ExoPlayer HTTP) and `background_downloader`
file downloads. Those stacks cannot use the Dart userspace Tailscale client, so
MagicDNS hostnames often fail with DNS errors (`-1003` on iOS) even while
Chopper API calls succeed through tsnet.

**Streaming while Embedded Tailscale is enabled:** Finamp builds remote
`AudioSource` URIs from the **Public** Jellyfin address (`publicAddress`), not
from `baseURL` (which may still prefer Local/MagicDNS for API).

When that address is tailnet-only (`*.ts.net` or `100.64.0.0/10`), the URI is
rewritten to a **loopback media proxy** — `TailscaleMediaProxy` binds an HTTP
server on `127.0.0.1` (random port, random per-run secret path segment) and
replays each request over `Tailscale.instance.http.client`. `Range` headers and
`206` responses pass through unchanged so seeking works, and HLS playlists
returned for transcoded streams are rewritten so their segment URLs point back
at the proxy. Requests are only replayed when the upstream host is tailnet-only
and the secret matches; the proxy stops when the toggle is turned off.

A plain internet-reachable Public URL (reverse proxy / tunnel hostname) skips
the proxy and is handed to the player directly. Downloaded tracks continue to
play from disk. Already-loaded remote queues rebuild when the effective playback
address class changes (Tailscale toggle, public address, or base URL).

Exported logs record the chosen path at `INFO` — look for
`Stream audio source: loopback proxy for tailnet public address` or
`Stream audio source: direct public address`. The URL and token are never
logged. Profile/Release builds drop `FINE`, so diagnostics for this path must
be logged at `INFO` or above.

When the toggle is on, app launch starts `EmbeddedTailscaleService.up()` in the
background so a slow control-plane connection cannot delay the first screen.
Persisted credentials resume first; the stored auth key is used only if resume
fails or returns `needsLogin`. All callers share one in-flight `up()` operation
so startup and connectivity events cannot race into duplicate enrollment.

Toggle off to use the normal LAN / public HTTP client again.

### Network settings vs Tailscale

| Field | Typical value | Wi‑Fi at home | Cellular |
|-------|---------------|---------------|----------|
| **Local** | LAN IP / `.local` | Should pass | Fails (expected — not on LAN) |
| **Public** | MagicDNS `*.ts.net` (or `100.x` CGNAT) | Passes when tsnet Running | Passes when tsnet Running |

The public URL is saved on keyboard submit, unfocus, Test, and when you leave
the screen. Older builds only saved on the keyboard **Done** key, so leaving
Network settings discarded a typed MagicDNS name and showed the login/LAN
address again — Test on cellular then pinged LAN and both checks failed.

**Cellular:** Local failing is expected. Public should pass if Embedded
Tailscale is **Running** and the public field is actually `*.ts.net` (not the
LAN IP). After a radio switch, Finamp resumes tsnet and allows up to 15s for
the public ping (LAN pings stay at 3s).

If Public still fails while Embedded Tailscale shows Running, confirm the
public field is MagicDNS, then rebuild. Older builds used a plain `IOClient`
for that test and always failed MagicDNS.

## Build requirements

- Flutter with **Dart ≥ 3.10.4** (this branch bumps `sdk: ^3.10.4`)
- **Go 1.25+** on `PATH` (Go 1.26 recommended). The first build compiles the
  native tsnet asset; later builds are cached.
- **Rust / rustup** on `PATH` (Finamp’s `flutter_discord_rpc` builds via Cargokit;
  iOS needs `rustup target add aarch64-apple-ios`)
- Xcode (iOS/macOS) / Android NDK via Flutter
- On **Xcode 16.2** (iOS 18.2 SDK), keep plugin caps in `pubspec.yaml` so the
  tree does not pull iOS 26-only APIs that still support Finamp’s **iOS 14+**
  deployment target:
  - `device_info_plus: ">=12.1.0 <12.4.0"`
  - `connectivity_plus: ">=7.0.0 <7.3.0"`

```bash
# Dev MacBook — Finamp repo
go version   # expect go1.25+
rustc --version
flutter pub get
flutter run
```

## Security notes

- Node WireGuard private key lives under application support
  (`…/embedded_tailscale/`). On iOS, `AppDelegate` excludes the application
  support directory from iCloud backup using `URLResourceValues`.
- **Auth keys** and the **Music Finder server URL** are stored with
  `flutter_secure_storage` (iOS/macOS Keychain, Android EncryptedSharedPreferences /
  Keystore)—not Hive or plain SharedPreferences. Older plaintext copies are
  migrated once at startup and deleted.
- Prefer short-lived or tagged auth keys from the Tailscale admin console.
- Use **Log out / reset node** before handing a device away.

## Scope / non-goals

- This stacked branch includes Music Finder + External Search. Hive
  `useEmbeddedTailscale` is `@HiveField(154)`; legacy plaintext
  `musicFinderServerUrl` was `@HiveField(155)` and is cleared after migration
  into secure storage. Music Finder HTTP uses `FinampHttpClient` (tsnet).
- Audio streaming uses the platform HTTP stack. With Embedded Tailscale on,
  streams use the Public address, replayed through the loopback media proxy
  (`lib/services/tailscale_media_proxy.dart`) when that address is tailnet-only.
  The proxy runs on the main isolate because tsnet's `http.Client` is not usable
  from background isolates.
- `background_downloader` file downloads still use the OS stack directly and are
  not proxied, so downloads from a tailnet-only host remain unsupported.
- Not proposed to upstream until device-tested and package:tailscale reviewed
  for key storage.

## Related

- Copilot task: https://github.com/itdir/finamp/tasks/5fd20a6a-e3ee-44ab-82d3-8a34c7646131
- Plan: `~/.cursor/plans/finamp_embedded_tsnet_5fd20a6a.plan.md`
- Personal-team device installs: prefer `flutter run --profile` — see [IOS_SIDELOAD_DEBUG.md](IOS_SIDELOAD_DEBUG.md)
