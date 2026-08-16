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
  });
}
