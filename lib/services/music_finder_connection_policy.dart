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
