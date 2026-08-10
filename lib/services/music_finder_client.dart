import 'dart:async';
import 'dart:io';

/// Probes the external Music Finder server (non-Jellyfin).
class MusicFinderClient {
  /// Returns true when [baseUrl] responds with HTTP 200.
  ///
  /// [baseUrl] must already be trimmed and validated (http/https, no trailing slash).
  Future<bool> checkConnection(String baseUrl) async {
    final uri = Uri.parse(baseUrl);
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(uri);
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      // Drain so the connection can close cleanly.
      await response.drain<void>();
      return response.statusCode == 200;
    } on TimeoutException {
      return false;
    } on SocketException {
      return false;
    } on HttpException {
      return false;
    } on HandshakeException {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
