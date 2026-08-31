import 'package:logging/logging.dart';

import 'finamp_secrets.dart';
import 'finamp_settings_helper.dart';
import 'music_finder_connection_policy.dart';

/// Durable Music Finder base URL: Hive + Keychain, Hive is source of truth.
///
/// Last night's Keychain-only store is wiped by iOS personal-team sideload
/// and some Keychain accessibility misses. Jellyfin login lives in Hive, which
/// is why playback still works when this URL disappears.
class MusicFinderUrlStore {
  MusicFinderUrlStore._();

  static final _log = Logger('MusicFinderUrlStore');

  static String? get _hiveUrl {
    try {
      return FinampSettingsHelper.finampSettings.musicFinderServerUrl;
    } catch (_) {
      return null;
    }
  }

  static String? get current => musicFinderUrlAfterUnreachable(
        inMemoryUrl: null,
        secureStorageUrl: FinampSecrets.musicFinderServerUrl,
        hiveUrl: _hiveUrl,
      );

  static bool get hasServer => current != null;

  static Future<void> save(String? url) async {
    final value = musicFinderNonEmptyUrl(url);
    try {
      await FinampSecrets.setMusicFinderServerUrl(value);
    } catch (e, st) {
      _log.warning('Keychain Music Finder URL write failed: $e', e, st);
    }
    FinampSetters.setMusicFinderServerUrl(value);
    _log.info(
      value == null
          ? 'Music Finder URL cleared from Hive and Keychain'
          : 'Music Finder URL saved to Hive and Keychain',
    );
  }

  static Future<void> reconcileOnStartup() async {
    await FinampSecrets.ensureInitialized();
    final result = musicFinderReconcilePersistedUrls(
      keychain: FinampSecrets.musicFinderServerUrl,
      hive: _hiveUrl,
    );
    final canonical = result.hive;
    if (canonical == null) {
      _log.info('Music Finder URL not set (Hive and Keychain empty)');
      return;
    }

    final keychainNow = musicFinderNonEmptyUrl(FinampSecrets.musicFinderServerUrl);
    final hiveNow = musicFinderNonEmptyUrl(_hiveUrl);

    if (keychainNow != canonical) {
      try {
        await FinampSecrets.setMusicFinderServerUrl(canonical);
        _log.info('Restored Music Finder URL into Keychain from Hive');
      } catch (e, st) {
        _log.warning('Keychain Music Finder URL restore failed: $e', e, st);
      }
    }
    if (hiveNow != canonical) {
      FinampSetters.setMusicFinderServerUrl(canonical);
      _log.info('Restored Music Finder URL into Hive from Keychain');
    }
  }
}
