import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:tailscale/tailscale.dart';

import 'embedded_tailscale_service.dart';
import 'finamp_http_client.dart';

/// Loopback HTTP server that lets the native media stack reach tailnet-only
/// Jellyfin hosts.
///
/// `just_audio` hands stream URLs to AVPlayer / ExoPlayer, which use the OS
/// network stack. That stack cannot resolve MagicDNS names or route
/// `100.64.0.0/10` addresses served by the in-app userspace tsnet node, so
/// playback fails with DNS errors (`-1003` on iOS) while Chopper API calls
/// succeed. The player instead fetches `http://127.0.0.1:<port>/…` from this
/// server, which replays the request over [Tailscale.instance.http.client] and
/// streams the bytes back, preserving `Range` requests so seeking works.
///
/// Main isolate only: tsnet's [http.Client] is not usable from background
/// isolates (same constraint as [FinampHttpClient]).
class TailscaleMediaProxy {
  TailscaleMediaProxy._();

  static final TailscaleMediaProxy instance = TailscaleMediaProxy._();

  static final _log = Logger('TailscaleMediaProxy');

  /// Request headers that must not be replayed upstream.
  static const _dropRequestHeaders = {
    'host',
    'connection',
    'keep-alive',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };

  /// Response headers the loopback server sets itself.
  static const _dropResponseHeaders = {'connection', 'keep-alive', 'transfer-encoding', 'content-length', 'upgrade'};

  /// Content types whose bodies contain further URLs that need rewriting.
  static const _playlistContentTypes = {
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'audio/mpegurl',
    'audio/x-mpegurl',
  };

  HttpServer? _server;
  String? _secret;
  Future<bool>? _startInFlight;

  int? get port => _server?.port;

  bool get isRunning => _server != null;

  /// Bind the loopback server if it is not already listening.
  ///
  /// Returns false when tsnet is not Running, since replaying a request over a
  /// down node would only trade a DNS failure for a connection failure.
  Future<bool> ensureStarted() {
    if (_server != null) return Future.value(true);
    return _startInFlight ??= _start().whenComplete(() {
      _startInFlight = null;
    });
  }

  Future<bool> _start() async {
    if (!EmbeddedTailscaleService.isRunning) {
      final running = await EmbeddedTailscaleService.ensureRunning();
      if (!running) {
        _log.warning('Not starting media proxy: tsnet is not Running');
        return false;
      }
    }

    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.autoCompress = false;
      _server = server;
      _secret = _newSecret();
      _log.info('Media proxy listening on loopback port ${server.port}');
      unawaited(_serve(server));
      return true;
    } catch (e, st) {
      _log.severe('Failed to bind loopback media proxy', e, st);
      return false;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _secret = null;
    if (server == null) return;
    _log.info('Stopping media proxy');
    try {
      await server.close(force: true);
    } catch (e, st) {
      _log.warning('Error closing media proxy', e, st);
    }
  }

  /// Loopback URL the native player should fetch instead of [upstream].
  ///
  /// Returns null when the proxy is not listening or [upstream] is already
  /// reachable by the OS (only tailnet hosts need replaying).
  ///
  /// The upstream origin is encoded as a path segment rather than a query
  /// parameter so that relative URLs inside HLS playlists resolve back onto
  /// this proxy without rewriting.
  Uri? proxyUri(Uri upstream) {
    final server = _server;
    final secret = _secret;
    if (server == null || secret == null) return null;
    if (!FinampHttpClient.looksLikeTailnetHost(upstream)) return null;
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      pathSegments: [secret, _encodeOrigin(upstream), ...upstream.pathSegments],
      query: upstream.hasQuery ? upstream.query : null,
    );
  }

  static String _encodeOrigin(Uri upstream) {
    final origin = Uri(scheme: upstream.scheme, host: upstream.host, port: upstream.hasPort ? upstream.port : null);
    return base64Url.encode(utf8.encode(origin.toString())).replaceAll('=', '');
  }

  static Uri? _decodeOrigin(String segment) {
    try {
      final padded = segment.padRight((segment.length + 3) & ~3, '=');
      final origin = Uri.parse(utf8.decode(base64Url.decode(padded)));
      if (origin.scheme != 'http' && origin.scheme != 'https') return null;
      if (origin.host.isEmpty) return null;
      return origin;
    } catch (_) {
      return null;
    }
  }

  static String _newSecret() {
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _serve(HttpServer server) async {
    try {
      await for (final request in server) {
        unawaited(_handle(request));
      }
    } catch (e, st) {
      if (identical(_server, server)) {
        _log.warning('Media proxy accept loop ended', e, st);
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final upstream = _resolveUpstream(request);
      if (upstream == null) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      await _forward(request, response, upstream);
    } catch (e, st) {
      // The native player cancels requests constantly while seeking; those
      // surface as socket errors and are not worth logging above fine.
      _log.fine('Media proxy request failed', e, st);
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    }
  }

  /// Validated upstream URL, or null when the request is not ours to serve.
  Uri? _resolveUpstream(HttpRequest request) {
    final secret = _secret;
    if (secret == null) return null;
    final segments = request.uri.pathSegments;
    if (segments.length < 2 || segments[0] != secret) return null;
    final origin = _decodeOrigin(segments[1]);
    if (origin == null) return null;
    // Only tailnet hosts justify replaying traffic through this process.
    if (!FinampHttpClient.looksLikeTailnetHost(origin)) return null;
    return origin.replace(pathSegments: segments.sublist(2), query: request.uri.hasQuery ? request.uri.query : null);
  }

  Future<void> _forward(HttpRequest request, HttpResponse response, Uri upstream) async {
    final client = Tailscale.instance.http.client;
    final upstreamRequest = http.Request(request.method, upstream)..followRedirects = true;

    request.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      if (_dropRequestHeaders.contains(lower)) return;
      if (values.isNotEmpty) upstreamRequest.headers[lower] = values.join(', ');
    });
    // Identity encoding keeps Content-Length / Content-Range accurate for the
    // player's byte-range seeking.
    upstreamRequest.headers['accept-encoding'] = 'identity';

    final upstreamResponse = await client.send(upstreamRequest);

    response.statusCode = upstreamResponse.statusCode;
    upstreamResponse.headers.forEach((name, value) {
      if (_dropResponseHeaders.contains(name.toLowerCase())) return;
      response.headers.set(name, value);
    });

    if (request.method == 'HEAD') {
      response.contentLength = upstreamResponse.contentLength ?? -1;
      await upstreamResponse.stream.drain<void>();
      await response.close();
      return;
    }

    if (_isPlaylist(upstreamResponse)) {
      // Transcoded playback fetches an HLS playlist whose segment URLs point at
      // the tailnet host. The player would resolve those itself, so they have to
      // be rewritten back onto this proxy before the body is handed over.
      final body = await upstreamResponse.stream.bytesToString();
      final rewritten = utf8.encode(_rewritePlaylist(body, upstream));
      response.contentLength = rewritten.length;
      response.add(rewritten);
      await response.close();
      return;
    }

    response.contentLength = upstreamResponse.contentLength ?? -1;
    await upstreamResponse.stream.pipe(response);
  }

  bool _isPlaylist(http.StreamedResponse response) {
    final contentType = response.headers['content-type']?.split(';').first.trim().toLowerCase();
    return contentType != null && _playlistContentTypes.contains(contentType);
  }

  /// Rewrite every URL in an HLS playlist to point back at this proxy.
  String _rewritePlaylist(String body, Uri playlistUrl) {
    final lines = const LineSplitter().convert(body);
    final rewritten = lines.map((line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) return line;
      if (!trimmed.startsWith('#')) return _rewriteReference(trimmed, playlistUrl) ?? line;
      // Tags such as #EXT-X-KEY and #EXT-X-MAP carry URI="…" attributes.
      return line.replaceAllMapped(RegExp(r'URI="([^"]*)"'), (match) {
        final replacement = _rewriteReference(match.group(1)!, playlistUrl);
        return replacement == null ? match.group(0)! : 'URI="$replacement"';
      });
    });
    return rewritten.join('\n');
  }

  /// Proxy URL for a playlist reference, or null to leave it untouched.
  String? _rewriteReference(String reference, Uri playlistUrl) {
    if (reference.isEmpty) return null;
    final resolved = playlistUrl.resolve(reference);
    if (!FinampHttpClient.looksLikeTailnetHost(resolved)) return null;
    return proxyUri(resolved)?.toString();
  }
}
