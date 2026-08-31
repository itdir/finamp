/// Pure helpers for Music Finder connection UX.
///
/// The saved server URL lives in [FinampSecrets] (Keychain / Keystore). A failed
/// health check or search must never clear that secret — only an explicit
/// successful reconnect with a new URL should overwrite it.
String? musicFinderUrlAfterUnreachable({
  required String? inMemoryUrl,
  required String? secureStorageUrl,
}) {
  final saved = secureStorageUrl?.trim();
  if (saved != null && saved.isNotEmpty) {
    return saved;
  }
  final memory = inMemoryUrl?.trim();
  if (memory != null && memory.isNotEmpty) {
    return memory;
  }
  return null;
}

bool musicFinderShouldShowChangeServer({
  required bool isConnected,
  required String? inMemoryUrl,
  required String? secureStorageUrl,
}) {
  if (isConnected) return true;
  return musicFinderUrlAfterUnreachable(
        inMemoryUrl: inMemoryUrl,
        secureStorageUrl: secureStorageUrl,
      ) !=
      null;
}
