import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:logging/logging.dart';
import 'package:tailscale/tailscale.dart';

import 'embedded_tailscale_service.dart';
import 'finamp_settings_helper.dart';

/// [http.Client] that optionally routes through embedded Tailscale tsnet.
///
/// Chopper keeps a single client for the process lifetime; this delegates each
/// [send] to either the default [IOClient] or [Tailscale.instance.http.client]
/// based on the current [FinampSettings.useEmbeddedTailscale] flag and whether
/// tsnet is up.
///
/// Do **not** use this from background isolates — Hive settings are not open
/// there, and tsnet's [http.Client] is main-isolate. Prefer
/// [requiresTsnetHttp] / [JellyfinApiHelper.runInIsolate] (which stays on the
/// main isolate when embedded Tailscale is needed) instead of
/// [JellyfinApi.create] with `inForeground: false`.
class FinampHttpClient extends http.BaseClient {
  FinampHttpClient({Duration connectionTimeout = const Duration(seconds: 10)})
    : _connectionTimeout = connectionTimeout,
      _default = IOClient(HttpClient()..connectionTimeout = connectionTimeout);

  final Duration _connectionTimeout;
  final http.Client _default;
  final _log = Logger('FinampHttpClient');

  /// Whether Settings → Embedded Tailscale is enabled (Hive; main isolate only).
  static bool get useEmbeddedTailscaleEnabled {
    try {
      return FinampSettingsHelper.finampSettings.useEmbeddedTailscale;
    } catch (_) {
      return false;
    }
  }

  bool get _useEmbeddedTs => useEmbeddedTailscaleEnabled;

  /// Userspace tsnet only for MagicDNS / CGNAT. LAN (`192.168.x`,
  /// `downloads.local`) and normal internet stay on the OS Wi-Fi stack so
  /// Network → Prefer Local Network can actually switch sources.
  http.Client _clientFor(Uri url) {
    if (!_useTsnetFor(url)) return _default;
    if (!EmbeddedTailscaleService.isRunning) return _default;
    try {
      return Tailscale.instance.http.client;
    } catch (e) {
      _log.warning('Tailscale http.client unavailable ($e); using default');
      return _default;
    }
  }

  bool _useTsnetFor(Uri url) =>
      _useEmbeddedTs && looksLikeTailnetHost(url);

  /// MagicDNS (`*.ts.net`) or Tailscale CGNAT (`100.64.0.0/10`).
  static bool looksLikeTailnetHost(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.endsWith('.ts.net') || host.endsWith('.ts.net.')) return true;
    final ip = InternetAddress.tryParse(host);
    if (ip == null || ip.type != InternetAddressType.IPv4) return false;
    final b = ip.rawAddress;
    return b[0] == 100 && b[1] >= 64 && b[1] <= 127;
  }

  /// True when requests must use this client on the main isolate (not a plain
  /// [IOClient] / [NetworkImage] / background isolate).
  static bool requiresTsnetHttp([Uri? uri]) {
    if (useEmbeddedTailscaleEnabled) return true;
    return uri != null && looksLikeTailnetHost(uri);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_useEmbeddedTs && looksLikeTailnetHost(request.url) && !EmbeddedTailscaleService.isRunning) {
      // Resume only: enrolling with the control plane can take ~30s, and every
      // queued request would wait behind it. Startup and Settings own that.
      await EmbeddedTailscaleService.ensureRunning(timeout: const Duration(seconds: 8), allowEnroll: false);
    }
    if (_useEmbeddedTs && !EmbeddedTailscaleService.isRunning && looksLikeTailnetHost(request.url)) {
      _log.warning(
        'MagicDNS request while tsnet is not Running: ${request.url} '
        '(status=${EmbeddedTailscaleService.lastStatus?.state}). '
        'Connect with an auth key under Settings → Embedded Tailscale.',
      );
      throw http.ClientException(
        'Embedded Tailscale is not connected (node not Running). '
        'Open Settings → Embedded Tailscale, paste a tskey-auth-… key, '
        'and Connect before using MagicDNS URLs like ${request.url.host}.',
        request.url,
      );
    }
    if (_useEmbeddedTs && !EmbeddedTailscaleService.isRunning) {
      _log.warning('useEmbeddedTailscale is on but tsnet is not running; using default client');
    }
    try {
      return await _sendOnce(request);
    } catch (e) {
      // Running-but-dead after a radio/VPN change: connectivity heal may have
      // raced before Android interfaces were ready and then hit cooldown.
      // Dial failures always force a rebuild (ignoreCooldown).
      if (!_useEmbeddedTs || !looksLikeTailnetHost(request.url)) {
        rethrow;
      }
      _log.warning(
        'MagicDNS request failed; healing embedded Tailscale then retrying once: $e',
      );
      final healed = await EmbeddedTailscaleService.healAfterNetworkChange(
        forceRestart: true,
        ignoreCooldown: true,
      );
      if (!healed) rethrow;
      if (request is! http.Request) {
        // Streamed/multipart bodies cannot be safely resent; heal so the
        // caller's next attempt uses a fresh path.
        rethrow;
      }
      final retry = http.Request(request.method, request.url)
        ..bodyBytes = request.bodyBytes
        ..encoding = request.encoding
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection;
      retry.headers.addAll(request.headers);
      return _sendOnce(retry);
    }
  }

  Future<http.StreamedResponse> _sendOnce(http.BaseRequest request) {
    final sent = _clientFor(request.url).send(request);
    if (!_useTsnetFor(request.url)) return sent;
    // tsnet's client has no connectionTimeout; hung sockets after a radio
    // change never threw, so heal-on-failure never ran until force-quit.
    return sent.timeout(_connectionTimeout);
  }

  @override
  void close() {
    _default.close();
    // Do not close Tailscale.instance.http.client — owned by the package.
  }
}
