import 'package:finamp/services/diagnostics_summary.dart';
import 'package:finamp/services/environment_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

/// The metadata block prepended to every export was never passed through
/// [CensoredMessage], unlike the log records below it. These tests pin the
/// report-facing variants so identifying details cannot creep back in.
void main() {
  final deviceInfo = DeviceInfo(
    deviceName: "BP's iPhone",
    deviceModel: 'iPhone11,2',
    osVersion: '18.7.9',
    platform: 'iOS',
  );

  final appInfo = AppInfo(
    appName: 'Finamp',
    packageName: 'com.anonymous.finamp',
    source: 'com.apple.testflight',
    version: '0.9.25-sideload.7',
    buildNumber: '133',
    installTime: DateTime.parse('2026-08-12 14:13:01.673'),
    updateTime: null,
    versionHistory: ['0.9.25 (132)', '0.9.25 (133)'],
  );

  final serverInfo = ServerInfo(
    serverAddressType: 'domainWithTld',
    serverPort: 8096,
    serverProtocol: 'http',
    serverVersion: '10.11.11',
  );

  group('metadata redaction', () {
    test('device name is dropped but the model is kept', () {
      expect(deviceInfo.pretty, contains("BP's iPhone"));
      expect(deviceInfo.prettyForReport, isNot(contains("BP's iPhone")));
      expect(deviceInfo.prettyForReport, contains('iPhone11,2'));
      expect(deviceInfo.prettyForReport, contains('18.7.9'));
    });

    test('package name is dropped but version and build are kept', () {
      expect(appInfo.pretty, contains('com.anonymous.finamp'));
      expect(appInfo.prettyForReport, isNot(contains('com.anonymous.finamp')));
      expect(appInfo.prettyForReport, contains('0.9.25-sideload.7'));
      expect(appInfo.prettyForReport, contains('133'));
    });

    test('full block drops both while keeping server info', () {
      final metadata = EnvironmentMetadata(deviceInfo: deviceInfo, appInfo: appInfo, serverInfo: serverInfo);

      expect(metadata.prettyForReport, isNot(contains("BP's iPhone")));
      expect(metadata.prettyForReport, isNot(contains('com.anonymous.finamp')));
      expect(metadata.prettyForReport, contains('10.11.11'));
      expect(metadata.prettyForReport, contains('domainWithTld'));
    });

    test('server address type is a class, never a hostname', () {
      // ServerInfo.fromServer only ever stores the class, so the report can
      // include it verbatim.
      expect(serverInfo.pretty, isNot(contains('jellyfin')));
      expect(serverInfo.pretty, contains('domainWithTld'));
    });
  });

  group('DiagnosticsSummary', () {
    const summary = DiagnosticsSummary(
      appVersion: '0.9.25-sideload.7',
      buildNumber: '133',
      platform: 'iOS',
      osVersion: '18.7.9',
      deviceModel: 'iPhone11,2',
      embeddedTailscale: 'running (ipv4+ipv6)',
      playbackAddress: 'public via loopback proxy',
      verboseLogging: false,
      server: 'Jellyfin 10.11.11 · domainWithTld · http · port 8096',
    );

    test('states the build number, which was previously only in an auth header', () {
      expect(summary.render(), contains('0.9.25-sideload.7 (133)'));
    });

    test('states how playback reaches the server', () {
      expect(summary.render(), contains('Playback address: public via loopback proxy'));
    });

    test('warns when verbose logging is off, since Profile builds cap at INFO', () {
      expect(summary.render(), contains('Verbose logging: off'));
    });

    test('fits in a chat message', () {
      expect(summary.render().split('\n').length, 5);
    });
  });
}
