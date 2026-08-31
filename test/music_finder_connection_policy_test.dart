import 'package:finamp/services/music_finder_connection_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('musicFinderUrlAfterUnreachable', () {
    test('prefers secure storage over cleared in-memory url', () {
      expect(
        musicFinderUrlAfterUnreachable(
          inMemoryUrl: null,
          secureStorageUrl: 'http://downloads.local:8088',
        ),
        'http://downloads.local:8088',
      );
    });

    test('keeps in-memory url when secure storage is empty', () {
      expect(
        musicFinderUrlAfterUnreachable(
          inMemoryUrl: 'http://downloads.local:8088',
          secureStorageUrl: null,
        ),
        'http://downloads.local:8088',
      );
    });

    test('prefers secure storage when both are set', () {
      expect(
        musicFinderUrlAfterUnreachable(
          inMemoryUrl: 'http://old.local:8088',
          secureStorageUrl: 'http://downloads.local:8088',
        ),
        'http://downloads.local:8088',
      );
    });

    test('returns null when nothing is saved', () {
      expect(
        musicFinderUrlAfterUnreachable(
          inMemoryUrl: null,
          secureStorageUrl: '   ',
        ),
        isNull,
      );
    });

    test('prefers Hive over Keychain so sideload OTA cannot drop the URL', () {
      expect(
        musicFinderUrlAfterUnreachable(
          inMemoryUrl: null,
          secureStorageUrl: 'http://stale-keychain.local:8088',
          hiveUrl: 'http://downloads.local:8088',
        ),
        'http://downloads.local:8088',
      );
    });

    test('falls back to Keychain when Hive is empty', () {
      expect(
        musicFinderUrlAfterUnreachable(
          inMemoryUrl: null,
          secureStorageUrl: 'http://downloads.local:8088',
          hiveUrl: null,
        ),
        'http://downloads.local:8088',
      );
    });
  });

  group('musicFinderReconcilePersistedUrls', () {
    test('mirrors Hive into Keychain', () {
      expect(
        musicFinderReconcilePersistedUrls(
          keychain: null,
          hive: 'http://downloads.local:8088',
        ),
        (keychain: 'http://downloads.local:8088', hive: 'http://downloads.local:8088'),
      );
    });

    test('mirrors Keychain into Hive when Hive is empty', () {
      expect(
        musicFinderReconcilePersistedUrls(
          keychain: 'http://downloads.local:8088',
          hive: null,
        ),
        (keychain: 'http://downloads.local:8088', hive: 'http://downloads.local:8088'),
      );
    });

    test('Hive wins when the two stores disagree', () {
      expect(
        musicFinderReconcilePersistedUrls(
          keychain: 'http://old.local:8088',
          hive: 'http://downloads.local:8088',
        ),
        (keychain: 'http://downloads.local:8088', hive: 'http://downloads.local:8088'),
      );
    });
  });

  group('musicFinderShouldShowChangeServer', () {
    test('always when connected', () {
      expect(
        musicFinderShouldShowChangeServer(
          isConnected: true,
          inMemoryUrl: null,
          secureStorageUrl: null,
        ),
        isTrue,
      );
    });

    test('when offline but a url is still saved', () {
      expect(
        musicFinderShouldShowChangeServer(
          isConnected: false,
          inMemoryUrl: null,
          secureStorageUrl: 'http://downloads.local:8088',
        ),
        isTrue,
      );
    });

    test('hidden when offline and never configured', () {
      expect(
        musicFinderShouldShowChangeServer(
          isConnected: false,
          inMemoryUrl: null,
          secureStorageUrl: null,
        ),
        isFalse,
      );
    });
  });
}
