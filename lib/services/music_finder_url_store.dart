import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'finamp_secrets.dart';
import 'finamp_settings_helper.dart';
import 'music_finder_connection_policy.dart';

/// Durable Music Finder base URL.
///
/// Hive is the live store (same as other settings). A plaintext
/// SharedPreferences copy is the Android-safe backup. Keychain/Keystore is
/// **not** written for this URL — EncryptedSharedPreferences can hang or drop
/// values, which blocked Hive writes and made the URL look unsaved.
class MusicFinderUrlStore {
  MusicFinderUrlStore._();

  static final _log = Logger('MusicFinderUrlStore');

  static const prefsKey = 'music_finder_server_url';

  static String? _prefsCache;

  static String? get _hiveUrl {
    try {
      return FinampSettingsHelper.finampSettings.musicFinderServerUrl;
    } catch (_) {
      return null;
    }
  }

  static String? get current => musicFinderUrlAfterUnreachable(
        inMemoryUrl: _prefsCache,
        secureStorageUrl: FinampSecrets.musicFinderServerUrl,
        hiveUrl: _hiveUrl,
      );

  static bool get hasServer => current != null;

  static Future<void> save(String? url) async {
    final value = musicFinderNonEmptyUrl(url);

    // Hive first — never wait on Keystore/Keychain to persist this.
    FinampSetters.setMusicFinderServerUrl(value);
    _log.info(
      value == null
          ? 'Music Finder URL cleared from Hive'
          : 'Music Finder URL saved to Hive',
    );

    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(prefsKey);
        _prefsCache = null;
      } else {
        await prefs.setString(prefsKey, value);
        _prefsCache = value;
      }
    } catch (e, st) {
      _log.warning('SharedPreferences Music Finder URL write failed: $e', e, st);
    }
  }

  static Future<void> reconcileOnStartup() async {
    String? prefsUrl;
    try {
      final prefs = await SharedPreferences.getInstance();
      prefsUrl = musicFinderNonEmptyUrl(prefs.getString(prefsKey));
      _prefsCache = prefsUrl;
    } catch (e, st) {
      _log.warning('SharedPreferences Music Finder URL read failed: $e', e, st);
    }

    // Leftover Keychain copy from the old store; do not wait long.
    String? keychainUrl;
    try {
      await FinampSecrets.ensureInitialized().timeout(
        const Duration(seconds: 2),
      );
      keychainUrl = musicFinderNonEmptyUrl(FinampSecrets.musicFinderServerUrl);
    } catch (e, st) {
      _log.warning('Skipping Keychain Music Finder URL: $e', e, st);
    }

    final canonical = musicFinderUrlAfterUnreachable(
      inMemoryUrl: prefsUrl,
      secureStorageUrl: keychainUrl,
      hiveUrl: _hiveUrl,
    );
    if (canonical == null) {
      _log.info('Music Finder URL not set');
      return;
    }

    if (musicFinderNonEmptyUrl(_hiveUrl) != canonical) {
      FinampSetters.setMusicFinderServerUrl(canonical);
      _log.info('Restored Music Finder URL into Hive');
    }
    if (prefsUrl != canonical) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefsKey, canonical);
        _prefsCache = canonical;
        _log.info('Restored Music Finder URL into SharedPreferences');
      } catch (e, st) {
        _log.warning(
          'SharedPreferences Music Finder URL restore failed: $e',
          e,
          st,
        );
      }
    }
  }
}
