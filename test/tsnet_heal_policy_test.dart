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
}
