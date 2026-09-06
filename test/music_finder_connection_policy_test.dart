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

  group('Music Finder timeout policy', () {
    test('tailnet dials get the same 15s budget as the Jellyfin ping', () {
      expect(
        musicFinderConnectionTimeout(tailnet: true),
        const Duration(seconds: 15),
      );
      expect(
        musicFinderConnectionTimeout(tailnet: false),
        const Duration(seconds: 10),
      );
    });

    test('tailnet health check outlasts tsnet resume + heal + retry', () {
      expect(
        musicFinderRequestTimeout(tailnet: true),
        const Duration(seconds: 30),
      );
      expect(
        musicFinderRequestTimeout(tailnet: false),
        const Duration(seconds: 15),
      );
    });

    test('outer budget always exceeds the dial it wraps', () {
      for (final tailnet in [true, false]) {
        expect(
          musicFinderRequestTimeout(tailnet: tailnet),
          greaterThan(musicFinderConnectionTimeout(tailnet: tailnet)),
        );
        expect(
          musicFinderPostTimeout(tailnet: tailnet),
          greaterThan(musicFinderRequestTimeout(tailnet: tailnet)),
        );
      }
    });
  });

  group('musicFinderShouldSoftHeal', () {
    final now = DateTime(2026, 9, 6, 12);

    test('heals before a first tailnet dial', () {
      expect(
        musicFinderShouldSoftHeal(
          tailnet: true,
          embeddedTailscaleEnabled: true,
          now: now,
        ),
        isTrue,
      );
    });

    test('never heals for a LAN url', () {
      expect(
        musicFinderShouldSoftHeal(
          tailnet: false,
          embeddedTailscaleEnabled: true,
          now: now,
        ),
        isFalse,
      );
    });

    test('never heals when Embedded Tailscale is off', () {
      expect(
        musicFinderShouldSoftHeal(
          tailnet: true,
          embeddedTailscaleEnabled: false,
          now: now,
        ),
        isFalse,
      );
    });

    test('screen pre-verify and client request heal once, not twice', () {
      expect(
        musicFinderShouldSoftHeal(
          tailnet: true,
          embeddedTailscaleEnabled: true,
          now: now.add(const Duration(milliseconds: 200)),
          lastSoftHealAt: now,
        ),
        isFalse,
      );
    });

    test('heals again once the dedup window has passed', () {
      expect(
        musicFinderShouldSoftHeal(
          tailnet: true,
          embeddedTailscaleEnabled: true,
          now: now.add(const Duration(seconds: 10)),
          lastSoftHealAt: now,
        ),
        isTrue,
      );
    });
  });
}
