import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/embedded_tailscale_service.dart';
import 'package:finamp/services/environment_metadata.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/tailscale_media_proxy.dart';

/// Short, paste-able statement of what the app is and how it is reaching the
/// server.
///
/// Every field here was asked for at least once while diagnosing the iOS
/// playback and Tailscale latency problems: the build number was only
/// recoverable from an HTTP auth header, and whether streams went direct or
/// through the loopback proxy could not be told from the log at all.
///
/// Deliberately excludes the hostname, token, user id, and device name. Attach
/// it alongside a log bundle, or paste it into a chat.
class DiagnosticsSummary {
  const DiagnosticsSummary({
    required this.appVersion,
    required this.buildNumber,
    required this.platform,
    required this.osVersion,
    required this.deviceModel,
    required this.embeddedTailscale,
    required this.playbackAddress,
    required this.verboseLogging,
    required this.server,
  });

  final String appVersion;
  final String buildNumber;
  final String platform;
  final String osVersion;
  final String deviceModel;

  /// Node state, e.g. `running` / `needsLogin` / `off`.
  final String embeddedTailscale;

  /// How streamed audio reaches the server, e.g. `public via loopback proxy`.
  final String playbackAddress;

  final bool verboseLogging;

  /// Jellyfin version plus address *class*, never the address itself.
  final String server;

  static const _unknown = 'unknown';

  /// Read the current state of the app. Safe to call before services are
  /// registered — missing pieces degrade to `unknown` rather than throwing.
  static Future<DiagnosticsSummary> capture() async {
    final metadata = await EnvironmentMetadata.create();
    return DiagnosticsSummary(
      appVersion: metadata.appInfo.version,
      buildNumber: metadata.appInfo.buildNumber,
      platform: metadata.deviceInfo.platform,
      osVersion: metadata.deviceInfo.osVersion,
      deviceModel: metadata.deviceInfo.deviceModel,
      embeddedTailscale: _describeTailscale(),
      playbackAddress: _describePlaybackAddress(),
      verboseLogging: _readSetting((settings) => settings.verboseLogging) ?? false,
      server: _describeServer(metadata.serverInfo),
    );
  }

  static T? _readSetting<T>(T Function(FinampSettings settings) read) {
    try {
      return read(FinampSettingsHelper.finampSettings);
    } catch (_) {
      // Hive is not open (early startup, or a background isolate).
      return null;
    }
  }

  static String _describeTailscale() {
    final enabled = _readSetting((settings) => settings.useEmbeddedTailscale) ?? false;
    if (!enabled) return 'off';
    final status = EmbeddedTailscaleService.lastStatus;
    if (status == null) return 'enabled, not started';

    // Address *families* only — a tailnet IP identifies the device.
    final families = <String>[
      if (status.tailscaleIPs.any((ip) => !ip.contains(':'))) 'ipv4',
      if (status.tailscaleIPs.any((ip) => ip.contains(':'))) 'ipv6',
    ];
    final addresses = families.isEmpty ? 'no addresses' : families.join('+');
    // Health warnings name the failure ("no connectivity to DERP servers")
    // without naming the node.
    final health = status.health.isEmpty ? '' : ', health: ${status.health.join("; ")}';
    return '${status.state.name} ($addresses)$health';
  }

  static String _describePlaybackAddress() {
    final useEmbeddedTailscale = _readSetting((settings) => settings.useEmbeddedTailscale) ?? false;
    if (!useEmbeddedTailscale) return 'direct';
    return TailscaleMediaProxy.instance.isRunning ? 'public via loopback proxy' : 'public, proxy not started';
  }

  static String _describeServer(ServerInfo? info) {
    if (info == null) return _unknown;
    return 'Jellyfin ${info.serverVersion} · ${info.serverAddressType} · ${info.serverProtocol} · port ${info.serverPort}';
  }

  String render() =>
      'Finamp $appVersion ($buildNumber) · $platform $osVersion · $deviceModel\n'
      'Embedded Tailscale: $embeddedTailscale\n'
      'Playback address: $playbackAddress\n'
      'Verbose logging: ${verboseLogging ? "on" : "off"}\n'
      'Server: $server';

  @override
  String toString() => render();
}
