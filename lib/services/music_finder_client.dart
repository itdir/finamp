import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../models/music_finder_models.dart';
import 'embedded_tailscale_service.dart';
import 'finamp_http_client.dart';
import 'music_finder_connection_policy.dart';

/// HTTP client for a self-hosted Music Finder service (non-Jellyfin).
///
/// Uses [FinampHttpClient]. When the saved base URL is a Tailscale path
/// (`*.ts.net` / `100.x`), traffic goes **only** through embedded tsnet —
/// never the OS stack.
///
/// Tailnet requests also get Jellyfin's connect behavior: a soft tsnet heal
/// before the dial and a longer budget, so Android's slower node bring-up does
/// not read as "server unreachable".
class MusicFinderClient {
  MusicFinderClient({http.Client? client}) : _injectedClient = client;

  /// Test/DI override. When null, per-path clients are built on demand so
  /// tailnet dials can use a longer [musicFinderConnectionTimeout].
  final http.Client? _injectedClient;
  http.Client? _lanClient;
  http.Client? _tailnetClient;
  DateTime? _lastSoftHealAt;
  final _log = Logger('MusicFinderClient');

  static bool _isTailnetUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    return uri != null && FinampHttpClient.looksLikeTailnetHost(uri);
  }

  http.Client _clientFor({required bool tailnet}) {
    final injected = _injectedClient;
    if (injected != null) return injected;
    if (tailnet) {
      return _tailnetClient ??= FinampHttpClient(
        connectionTimeout: musicFinderConnectionTimeout(tailnet: true),
      );
    }
    return _lanClient ??= FinampHttpClient(
      connectionTimeout: musicFinderConnectionTimeout(tailnet: false),
    );
  }

  /// Resume a down tsnet node before dialing a tailnet Music Finder URL.
  ///
  /// Safe to call from the UI before a health check: repeat calls inside the
  /// dedup window are skipped, so the screen and the request below it heal once.
  Future<void> prepareForRequest(String baseUrl) =>
      _softHealIfNeeded(_isTailnetUrl(baseUrl));

  Future<void> _softHealIfNeeded(bool tailnet) async {
    if (!musicFinderShouldSoftHeal(
      tailnet: tailnet,
      embeddedTailscaleEnabled: FinampHttpClient.useEmbeddedTailscaleEnabled,
      now: DateTime.now(),
      lastSoftHealAt: _lastSoftHealAt,
    )) {
      return;
    }
    _lastSoftHealAt = DateTime.now();
    try {
      // Soft: resume if the node is down, but do not force a restart for a
      // request that has not failed yet.
      await EmbeddedTailscaleService.healAfterNetworkChange(
        forceRestart: false,
      );
    } catch (e) {
      _log.warning('Music Finder soft heal before request failed: $e');
    }
  }

  Uri _apiUri(String baseUrl, String path) {
    final root = baseUrl.endsWith("/")
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse("$root$path");
  }

  /// Returns true when `GET {baseUrl}/api/health` returns HTTP 200.
  Future<bool> checkConnection(String baseUrl) async {
    try {
      final response = await _getJson(baseUrl, "/api/health");
      return response.statusCode == 200;
    } catch (e) {
      _log.warning('Music Finder health check failed: $e');
      return false;
    }
  }

  Future<MusicFinderSearchResult> search({
    required String baseUrl,
    String song = "",
    String artist = "",
    String album = "",
    String? artistId,
  }) async {
    final body = <String, dynamic>{
      "song": song,
      "artist": artist,
      "album": album,
      if (artistId != null && artistId.isNotEmpty) "artist_id": artistId,
    };
    final response = await _postJson(baseUrl, "/api/v1/search", body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MusicFinderException(
        "Search failed (HTTP ${response.statusCode})",
        statusCode: response.statusCode,
      );
    }
    return MusicFinderSearchResult.fromJson(response.json);
  }

  Future<MusicFinderAddResult> addItems({
    required String baseUrl,
    required List<String> urls,
  }) async {
    final response = await _postJson(baseUrl, "/api/v1/add", {
      "urls": urls,
      // Legacy field name for Music Finder builds that predate `urls`.
      "magnets": urls,
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MusicFinderException(
        "Add failed (HTTP ${response.statusCode})",
        statusCode: response.statusCode,
      );
    }
    return MusicFinderAddResult.fromJson(response.json);
  }

  Future<_JsonResponse> _getJson(String baseUrl, String path) async {
    final uri = _apiUri(baseUrl, path);
    final tailnet = _isTailnetUrl(baseUrl);
    await _softHealIfNeeded(tailnet);
    final response = await _clientFor(tailnet: tailnet)
        .get(uri)
        .timeout(musicFinderRequestTimeout(tailnet: tailnet));
    return _parse(response);
  }

  Future<_JsonResponse> _postJson(
    String baseUrl,
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = _apiUri(baseUrl, path);
    final tailnet = _isTailnetUrl(baseUrl);
    await _softHealIfNeeded(tailnet);
    try {
      final response = await _clientFor(tailnet: tailnet)
          .post(
            uri,
            headers: const {"Content-Type": "application/json; charset=utf-8"},
            body: jsonEncode(body),
          )
          .timeout(musicFinderPostTimeout(tailnet: tailnet));
      return _parse(response);
    } on FormatException catch (e) {
      throw MusicFinderException("Invalid JSON response: $e");
    }
  }

  _JsonResponse _parse(http.Response response) {
    Map<String, dynamic> json = {};
    if (response.body.isNotEmpty) {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        json = decoded;
      } else if (decoded is Map) {
        json = Map<String, dynamic>.from(decoded);
      }
    }
    return _JsonResponse(statusCode: response.statusCode, json: json);
  }
}

class _JsonResponse {
  const _JsonResponse({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, dynamic> json;
}
