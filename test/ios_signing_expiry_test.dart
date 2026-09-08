import 'package:finamp/services/ios_signing_expiry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IosSigningExpiry.formatExpiryParts', () {
    test('formats en_US date and time', () {
      final parts = IosSigningExpiry.formatExpiryParts(
        DateTime(2026, 9, 14, 15, 22),
        localeName: 'en_US',
      );
      expect(parts.date, contains('2026'));
      expect(parts.date, contains('Sep'));
      expect(parts.time.toLowerCase(), contains('3:22'));
    });
  });

  group('IosSigningExpiry.formatExpiryLine', () {
    test('returns null when expiry missing', () {
      expect(
        IosSigningExpiry.formatExpiryLine(
          null,
          localeName: 'en_US',
          localize: (d, t) => 'Signing expires on $d at $t.',
        ),
        isNull,
      );
    });

    test('uses localize callback', () {
      final line = IosSigningExpiry.formatExpiryLine(
        DateTime(2026, 9, 14, 15, 22),
        localeName: 'en_US',
        localize: (d, t) => 'Signing expires on $d at $t.',
      );
      expect(line, startsWith('Signing expires on '));
      expect(line, contains(' at '));
      expect(line, endsWith('.'));
    });
  });
}
