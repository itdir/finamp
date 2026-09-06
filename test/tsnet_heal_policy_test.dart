import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:finamp/services/embedded_tailscale_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sideloadTsnetHealAction', () {
    test('resumes when the node is not running', () {
      expect(
        sideloadTsnetHealAction(
          isRunning: false,
          isHealthy: false,
          forceRestart: false,
        ),
        SideloadTsnetHealAction.resume,
      );
    });

    test('restarts when forceRestart is set even if healthy', () {
      expect(
        sideloadTsnetHealAction(
          isRunning: true,
          isHealthy: true,
          forceRestart: true,
        ),
        SideloadTsnetHealAction.restart,
      );
    });

    test('restarts when Running but unhealthy', () {
      expect(
        sideloadTsnetHealAction(
          isRunning: true,
          isHealthy: false,
          forceRestart: false,
        ),
        SideloadTsnetHealAction.restart,
      );
    });

    test('leaves a healthy Running node alone without forceRestart', () {
      expect(
        sideloadTsnetHealAction(
          isRunning: true,
          isHealthy: true,
          forceRestart: false,
        ),
        SideloadTsnetHealAction.none,
      );
    });
  });

  group('sideloadConnectivityLooksUsable', () {
    test('wifi and mobile are usable', () {
      expect(sideloadConnectivityLooksUsable([ConnectivityResult.wifi]), isTrue);
      expect(sideloadConnectivityLooksUsable([ConnectivityResult.mobile]), isTrue);
    });

    test('none is not usable', () {
      expect(sideloadConnectivityLooksUsable([ConnectivityResult.none]), isFalse);
    });
  });

  group('sideloadTsnetHealShouldIgnoreCooldown', () {
    test('wifi to mobile ignores cooldown', () {
      expect(
        sideloadTsnetHealShouldIgnoreCooldown(
          previousSignature: sideloadConnectivitySignature([ConnectivityResult.wifi]),
          currentSignature: sideloadConnectivitySignature([ConnectivityResult.mobile]),
        ),
        isTrue,
      );
    });

    test('same radio keeps cooldown', () {
      expect(
        sideloadTsnetHealShouldIgnoreCooldown(
          previousSignature: sideloadConnectivitySignature([ConnectivityResult.wifi]),
          currentSignature: sideloadConnectivitySignature([ConnectivityResult.wifi]),
        ),
        isFalse,
      );
    });

    test('first event does not ignore cooldown', () {
      expect(
        sideloadTsnetHealShouldIgnoreCooldown(
          previousSignature: null,
          currentSignature: sideloadConnectivitySignature([ConnectivityResult.wifi]),
        ),
        isFalse,
      );
    });
  });
}
