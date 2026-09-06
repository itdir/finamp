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

/// Dial timeout handed to the underlying HTTP client.
///
/// Tailnet dials get the same 15s Jellyfin's tailnet ping uses: tsnet has to
/// resume the node and pick a path before the first packet moves, which is
/// slower on Android (host interface snapshot is only taken at node start).
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
/// Search and add do real server-side work, so the LAN budget is already
/// generous; tailnet only adds room for the heal + retry path.
Duration musicFinderPostTimeout({required bool tailnet}) =>
    tailnet ? const Duration(seconds: 75) : const Duration(seconds: 60);

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
