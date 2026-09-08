import 'package:finamp/services/tsnet_media_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TsnetMediaProxy URI encoding', () {
    test('origin token round-trips', () {
      const origin = 'http://htpc.tailfb0493.ts.net:8096';
      final token = TsnetMediaProxy.encodeOriginToken(origin);
      expect(TsnetMediaProxy.decodeOriginToken(token), origin);
    });

    test('buildProxyUri preserves path and query', () {
      final upstream = Uri.parse(
        'http://htpc.tailfb0493.ts.net:8096/Items/abc/File?ApiKey=secret&x=1',
      );
      final proxy = TsnetMediaProxy.buildProxyUri(port: 12345, upstream: upstream);
      expect(proxy.scheme, 'http');
      expect(proxy.host, '127.0.0.1');
      expect(proxy.port, 12345);
      expect(proxy.path, startsWith('/o/'));
      expect(proxy.path, endsWith('/Items/abc/File'));
      expect(proxy.queryParameters['ApiKey'], 'secret');
      expect(proxy.queryParameters['x'], '1');

      final resolved = TsnetMediaProxy.resolveUpstream(proxy);
      expect(resolved, isNotNull);
      expect(resolved!.origin, upstream.origin);
      expect(resolved.path, '/Items/abc/File');
      expect(resolved.queryParameters['ApiKey'], 'secret');
    });

    test('resolveUpstream rejects non-proxy paths', () {
      expect(TsnetMediaProxy.resolveUpstream(Uri.parse('http://127.0.0.1/x')), isNull);
    });
  });
}
