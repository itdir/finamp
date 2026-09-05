import 'package:finamp/services/finamp_http_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('looksLikeTailnetHost', () {
    test('MagicDNS is tailnet', () {
      expect(
        FinampHttpClient.looksLikeTailnetHost(
          Uri.parse('https://htpc.tailfb0493.ts.net:8096'),
        ),
        isTrue,
      );
    });

    test('CGNAT 100.x is tailnet', () {
      expect(
        FinampHttpClient.looksLikeTailnetHost(
          Uri.parse('http://100.120.83.28:8096'),
        ),
        isTrue,
      );
    });

    test('LAN IPv4 is Wi-Fi, not tsnet', () {
      expect(
        FinampHttpClient.looksLikeTailnetHost(
          Uri.parse('http://192.168.1.101:8096'),
        ),
        isFalse,
      );
    });

    test('mDNS downloads.local is Wi-Fi, not tsnet', () {
      expect(
        FinampHttpClient.looksLikeTailnetHost(
          Uri.parse('http://downloads.local:8088'),
        ),
        isFalse,
      );
    });
  });
}
