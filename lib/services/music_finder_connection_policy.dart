import 'dart:async';

/// Pure helpers for Music Finder connection UX.
///
/// The saved server URL lives in Hive (plus SharedPreferences backup). A failed
/// health check or search must never clear it — only an explicit successful
/// reconnect with a new URL should overwrite it. Leftover Keychain values are
/// still accepted as a one-time migration source.
String? musicFinderNonEmptyUrl(String? url) {
  final trimmed = url?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

String? musicFinderUrlAfterUnreachable({
  required String? inMemoryUrl,
  required String? secureStorageUrl,
  String? hiveUrl,
}) {
  return musicFinderNonEmptyUrl(hiveUrl) ??
      musicFinderNonEmptyUrl(secureStorageUrl) ??
      musicFinderNonEmptyUrl(inMemoryUrl);
}

/// Pick one canonical URL across Hive and any leftover Keychain copy.
///
/// Hive wins when both are set: app documents survive personal-team sideload
/// upgrades, while iOS Keychain is often empty after an IPA replace.
({String? keychain, String? hive}) musicFinderReconcilePersistedUrls({
  required String? keychain,
  required String? hive,
}) {
  final canonical =
      musicFinderNonEmptyUrl(hive) ?? musicFinderNonEmptyUrl(keychain);
  return (keychain: canonical, hive: canonical);
}

bool musicFinderShouldShowChangeServer({
  required bool isConnected,
  required String? inMemoryUrl,
  required String? secureStorageUrl,
  String? hiveUrl,
}) {
  if (isConnected) return true;
  return musicFinderUrlAfterUnreachable(
        inMemoryUrl: inMemoryUrl,
        secureStorageUrl: secureStorageUrl,
        hiveUrl: hiveUrl,
      ) !=
      null;
}

/// Dial / first-byte timeout for a Music Finder health check.
///
/// Handed to [FinampHttpClient] as `connectionTimeout`. On the tsnet path that
/// value is applied to the whole `send()` future (time-to-first-byte), not only
/// TCP connect — tsnet's client has no real connectionTimeout.
///
/// Tailnet health checks get the same 15s Jellyfin's tailnet ping uses.
Duration musicFinderConnectionTimeout({required bool tailnet}) =>
    tailnet ? const Duration(seconds: 15) : const Duration(seconds: 10);

/// End-to-end budget for a Music Finder GET (health check).
///
/// A tailnet request can spend up to ~8s in `ensureRunning`, then a dial, then
/// a forced heal + one retry inside `FinampHttpClient`. The old flat 15s cap
/// aborted before that recovery finished, so Android reported "unreachable"
/// for a MagicDNS URL that worked on iOS.
Duration musicFinderRequestTimeout({required bool tailnet}) =>
    tailnet ? const Duration(seconds: 30) : const Duration(seconds: 15);

/// End-to-end budget for a Music Finder POST (search / add).
///
/// Search scrapes upstream torrent sites synchronously before the HTTP
/// response starts, so this budget must cover TTFB, not just body download.
Duration musicFinderPostTimeout({required bool tailnet}) =>
    tailnet ? const Duration(seconds: 75) : const Duration(seconds: 60);

/// `FinampHttpClient` send / TTFB timeout for a Music Finder request.
///
/// Health checks stay short. Search/add must use the full post budget —
/// otherwise a still-running scrape hits the 15s send timeout, FinampHttpClient
/// force-heals tsnet and retries, and the UI shows a cascade of timeouts.
Duration musicFinderSendTimeout({
  required bool tailnet,
  required bool longRunning,
}) =>
    longRunning
        ? musicFinderPostTimeout(tailnet: tailnet)
        : musicFinderConnectionTimeout(tailnet: tailnet);

/// Whether a soft tsnet heal should run before dialing [tailnet].
///
/// Mirrors `JellyfinApiHelper.pingPublicServer`: resume a down node before the
/// request instead of relying only on heal-after-failure. [lastSoftHealAt]
/// collapses the screen's pre-verify heal and the client's own heal into one.
bool musicFinderShouldSoftHeal({
  required bool tailnet,
  required bool embeddedTailscaleEnabled,
  required DateTime now,
  DateTime? lastSoftHealAt,
  Duration window = const Duration(seconds: 3),
}) {
  if (!tailnet || !embeddedTailscaleEnabled) return false;
  if (lastSoftHealAt == null) return true;
  return now.difference(lastSoftHealAt) >= window;
}

/// User-visible detail when a Music Finder health check fails.
///
/// Prefer the underlying [http.ClientException] / timeout text over a generic
/// "could not connect" — MagicDNS failures are usually "Embedded Tailscale is
/// not connected", not a wrong URL.
String musicFinderHealthFailureDetail(Object error) {
  if (error is TimeoutException) {
    return 'Timed out reaching the Music Finder server. '
        'If this is a Tailscale URL, open Settings → Embedded Tailscale and '
        'confirm the node is Running, then try again.';
  }
  var text = error.toString().trim();
  const prefixes = [
    'Exception: ',
    'ClientException: ',
    'HttpException: ',
    'SocketException: ',
  ];
  var stripped = true;
  while (stripped) {
    stripped = false;
    for (final prefix in prefixes) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length).trim();
        stripped = true;
        break;
      }
    }
  }
  // ClientException appends ", uri=…" — keep the human message only.
  final uriIdx = text.lastIndexOf(', uri=');
  if (uriIdx > 0) {
    text = text.substring(0, uriIdx).trim();
  }
  if (text.isEmpty) {
    return 'Could not connect to Music Finder server';
  }
  return text;
}

/// True when a forced tsnet rebuild should run after a soft heal still left
/// the node down (Android cold start / stale Running-but-dead path).
bool musicFinderShouldForceHealAfterSoftMiss({
  required bool tailnet,
  required bool embeddedTailscaleEnabled,
  required bool isRunning,
  required bool isAndroid,
}) {
  return isAndroid &&
      tailnet &&
      embeddedTailscaleEnabled &&
      !isRunning;
}

/// Offer a deep-link to Embedded Tailscale settings when MagicDNS is the likely
/// failure mode (URL is tailnet and tsnet is not Running, or the error text
/// already names Embedded Tailscale).
bool musicFinderShouldOfferEmbeddedTailscaleSettings({
  required bool tailnetUrl,
  required bool tsnetRunning,
  String? failureDetail,
}) {
  if (!tailnetUrl) return false;
  if (!tsnetRunning) return true;
  final d = (failureDetail ?? '').toLowerCase();
  return d.contains('embedded tailscale') ||
      d.contains('not connected') ||
      d.contains('needs login') ||
      d.contains('needs an auth key');
}
