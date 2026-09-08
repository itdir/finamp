import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'embedded_tailscale_service.dart';
import 'finamp_http_client.dart';

/// Localhost reverse proxy so `just_audio` (OS HTTP stack) can stream Jellyfin
/// media from MagicDNS / Tailscale CGNAT hosts via [FinampHttpClient] / tsnet.
///
/// Without this, API calls succeed through Embedded Tailscale while playback
/// fails with host-unreachable errors (`-1004` / `-1008` on iOS) because the
/// native player never joins the userspace tailnet.
class TsnetMediaProxy {
  TsnetMediaProxy._();

  static final instance = TsnetMediaProxy._();
  static final _log = Logger('TsnetMediaProxy');

  HttpServer? _server;
  Future<HttpServer>? _starting;
  final http.Client _client = FinampHttpClient(connectionTimeout: const Duration(seconds: 60));

  /// Whether [mediaUri] must be rewritten through this proxy.
  static bool shouldProxy(Uri mediaUri) {
    if (!FinampHttpClient.looksLikeTailnetHost(mediaUri)) return false;
    // OS stack cannot resolve/reach *.ts.net / 100.x without system Tailscale.
    // Only proxy when Embedded Tailscale is enabled so FinampHttpClient can
    // route the upstream fetch.
    return FinampHttpClient.useEmbeddedTailscaleEnabled;
  }

  /// Encode upstream origin for the `/o/<token>/…` path prefix.
  @visibleForTesting
  static String encodeOriginToken(String origin) =>
      base64Url.encode(utf8.encode(origin)).replaceAll('=', '');

  /// Decode a token from [encodeOriginToken].
  @visibleForTesting
  static String decodeOriginToken(String token) {
    final padded = token + ('=' * ((4 - token.length % 4) % 4));
    return utf8.decode(base64Url.decode(padded));
  }

  /// Build the localhost URI for an upstream media URL (no server start).
  @visibleForTesting
  static Uri buildProxyUri({required int port, required Uri upstream}) {
    final token = encodeOriginToken(upstream.origin);
    final path = upstream.path.isEmpty ? '/' : upstream.path;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/o/$token$path',
      query: upstream.hasQuery ? upstream.query : null,
    );
  }

  /// Returns [mediaUri] unchanged when proxying is unnecessary; otherwise a
  /// `http://127.0.0.1:<port>/o/…` URI that [just_audio] can fetch locally.
  Future<Uri> rewriteIfNeeded(Uri mediaUri) async {
    if (!shouldProxy(mediaUri)) return mediaUri;
    if (!EmbeddedTailscaleService.isRunning) {
      await EmbeddedTailscaleService.ensureRunning();
    }
    final server = await _ensureServer();
    final rewritten = buildProxyUri(port: server.port, upstream: mediaUri);
    _log.fine('proxy ${mediaUri.host} → ${rewritten.host}:${rewritten.port}');
    return rewritten;
  }

  Future<HttpServer> _ensureServer() {
    final existing = _server;
    if (existing != null) return Future.value(existing);
    return _starting ??= () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      _log.info('Tsnet media proxy listening on 127.0.0.1:${server.port}');
      server.listen(_handleRequest, onError: (Object e, StackTrace st) {
        _log.warning('proxy accept error', e, st);
      });
      return server;
    }().whenComplete(() {
      _starting = null;
    });
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final upstream = resolveUpstream(request.uri);
      if (upstream == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final outHeaders = <String, String>{};
      request.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower == HttpHeaders.hostHeader ||
            lower == HttpHeaders.connectionHeader ||
            lower == 'keep-alive' ||
            lower == 'transfer-encoding' ||
            lower == 'content-length') {
          return;
        }
        outHeaders[name] = values.join(',');
      });

      final clientRequest = http.Request(request.method, upstream)..headers.addAll(outHeaders);
      if (request.method != 'GET' && request.method != 'HEAD') {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in request) {
          builder.add(chunk);
        }
        clientRequest.bodyBytes = builder.takeBytes();
      }

      final upstreamResponse = await _client.send(clientRequest);
      request.response.statusCode = upstreamResponse.statusCode;
      upstreamResponse.headers.forEach((name, value) {
        final lower = name.toLowerCase();
        if (lower == 'transfer-encoding' || lower == 'content-length') return;
        request.response.headers.set(name, value);
      });

      final contentType = upstreamResponse.headers['content-type'] ?? '';
      final isPlaylist =
          contentType.contains('mpegurl') ||
          contentType.contains('m3u8') ||
          upstream.path.toLowerCase().endsWith('.m3u8');

      if (isPlaylist) {
        final bytes = await upstreamResponse.stream.toBytes();
        var text = utf8.decode(bytes, allowMalformed: true);
        final token = encodeOriginToken(upstream.origin);
        final proxyOrigin = 'http://127.0.0.1:${_server!.port}/o/$token';
        text = text.replaceAll(upstream.origin, proxyOrigin);
        final out = utf8.encode(text);
        request.response.headers.contentLength = out.length;
        request.response.add(out);
      } else {
        await request.response.addStream(upstreamResponse.stream);
      }
      await request.response.close();
    } catch (e, st) {
      _log.warning('proxy request failed ${request.uri}', e, st);
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Parse `/o/<token>/<path>` into an upstream [Uri].
  @visibleForTesting
  static Uri? resolveUpstream(Uri requestUri) {
    final segments = requestUri.pathSegments;
    if (segments.length < 2 || segments.first != 'o') return null;
    try {
      final origin = decodeOriginToken(segments[1]);
      final remainder = segments.length > 2 ? '/${segments.sublist(2).join('/')}' : '/';
      final base = Uri.parse(origin);
      return base.replace(
        path: remainder,
        query: requestUri.hasQuery ? requestUri.query : null,
      );
    } catch (e) {
      _log.warning('bad proxy token: $e');
      return null;
    }
  }

  /// Test helper / shutdown (optional).
  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
