import 'package:finamp/services/embedded_tailscale_hostname_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('slugifyTailscaleHostname', () {
    test('slugifies iPhone-style names', () {
      expect(slugifyTailscaleHostname("BP's iPhone"), 'bps-iphone');
    });

    test('lowercases and collapses junk', () {
      expect(slugifyTailscaleHostname('  Pixel  6!! '), 'pixel-6');
    });

    test('empty becomes finamp', () {
      expect(slugifyTailscaleHostname(''), kDefaultTailscaleHostname);
      expect(slugifyTailscaleHostname('@@@'), kDefaultTailscaleHostname);
    });

    test('caps at 63 characters without trailing dash', () {
      final long = 'a' * 80;
      final slug = slugifyTailscaleHostname(long);
      expect(slug.length, lessThanOrEqualTo(kTailscaleHostnameMaxLength));
      expect(slug.endsWith('-'), isFalse);
    });
  });

  group('isValidTailscaleHostname', () {
    test('accepts simple labels', () {
      expect(isValidTailscaleHostname('bps-iphone'), isTrue);
      expect(isValidTailscaleHostname('pixel-6'), isTrue);
      expect(isValidTailscaleHostname('finamp'), isTrue);
    });

    test('rejects invalid labels', () {
      expect(isValidTailscaleHostname(''), isFalse);
      expect(isValidTailscaleHostname("BP's iPhone"), isFalse);
      expect(isValidTailscaleHostname('-bad'), isFalse);
      expect(isValidTailscaleHostname('bad-'), isFalse);
      expect(isValidTailscaleHostname('Has Caps'), isFalse);
    });
  });

  group('resolveEmbeddedTailscaleHostname', () {
    test('locked prefers saved valid name', () {
      expect(
        resolveEmbeddedTailscaleHostname(
          saved: 'bps-iphone',
          locked: true,
          draft: 'ignored',
        ),
        'bps-iphone',
      );
    });

    test('unlocked prefers draft', () {
      expect(
        resolveEmbeddedTailscaleHostname(
          saved: 'old-name',
          locked: false,
          draft: 'Pixel BP',
        ),
        'pixel-bp',
      );
    });

    test('unlocked with empty draft uses saved', () {
      expect(
        resolveEmbeddedTailscaleHostname(
          saved: 'bps-iphone',
          locked: false,
          draft: null,
        ),
        'bps-iphone',
      );
    });
  });

  group('embeddedTailscaleHostnameIsEditable', () {
    test('editable only when unlocked', () {
      expect(embeddedTailscaleHostnameIsEditable(locked: false), isTrue);
      expect(embeddedTailscaleHostnameIsEditable(locked: true), isFalse);
    });
  });
}
