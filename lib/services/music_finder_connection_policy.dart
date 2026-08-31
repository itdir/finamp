/// Pure helpers for Music Finder connection UX.
///
/// The saved server URL is dual-written to Hive (survives sideload OTA) and
/// Keychain/Keystore. A failed health check or search must never clear it —
/// only an explicit successful reconnect with a new URL should overwrite it.
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

/// Pick one canonical URL and mirror it to both stores.
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
