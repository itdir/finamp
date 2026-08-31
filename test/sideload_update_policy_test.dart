import 'package:finamp/services/sideload_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sideload build policy', () {
    test('identifies an older feed build as a downgrade', () {
      expect(
        sideloadBuildRelation(remoteBuild: 133, localBuild: 134),
        SideloadBuildRelation.older,
      );
    });

    test('allows the same build only to be handled explicitly', () {
      expect(
        sideloadBuildRelation(remoteBuild: 134, localBuild: 134),
        SideloadBuildRelation.same,
      );
      expect(
        sideloadBuildCanInstall(
          remoteBuild: 134,
          localBuild: 134,
          allowSameBuild: false,
        ),
        isFalse,
      );
      expect(
        sideloadBuildCanInstall(
          remoteBuild: 134,
          localBuild: 134,
          allowSameBuild: true,
        ),
        isTrue,
      );
    });

    test('identifies a newer feed build as an update', () {
      expect(
        sideloadBuildRelation(remoteBuild: 135, localBuild: 134),
        SideloadBuildRelation.newer,
      );
      expect(
        sideloadBuildCanInstall(
          remoteBuild: 135,
          localBuild: 134,
          allowSameBuild: false,
        ),
        isTrue,
      );
    });

    test('never allows an older feed build', () {
      for (final allowSameBuild in [false, true]) {
        expect(
          sideloadBuildCanInstall(
            remoteBuild: 133,
            localBuild: 134,
            allowSameBuild: allowSameBuild,
          ),
          isFalse,
        );
      }
    });

    test('downgrade message identifies both builds and remediation', () {
      final message = sideloadDowngradeBlockedMessage(
        remoteBuild: 133,
        localBuild: 134,
      );

      expect(message, contains('feed has build 133'));
      expect(message, contains('build 134 is installed'));
      expect(message, contains('Publish build 134 or newer'));
    });

    test('ahead-of-feed message is reassuring, not a downgrade warning', () {
      final message = sideloadAheadOfFeedMessage(
        localBuild: 136,
        manifest: SideloadManifest(
          version: '0.9.25-sideload.9',
          build: 135,
          upstreamVersion: '0.9.25',
          publishedAt: '2026-08-17T00:00:00Z',
          notes: '',
          androidApkUrl: '',
          androidSha256: '',
          androidSizeBytes: 0,
        ),
      );

      expect(message, contains('Up to date on this device'));
      expect(message, contains('build 136'));
      expect(message, contains('build 135'));
      expect(message, contains('nothing to download'));
      expect(message, isNot(contains('newer than')));
    });
  });
}
