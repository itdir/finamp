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
