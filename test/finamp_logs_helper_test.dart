import 'package:finamp/services/finamp_logs_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a log line in the format [CensoredMessage] writes to disk.
String record(String time, String message, {String logger = 'Test', String level = 'INFO'}) =>
    '[$logger/$level] $time: $message\n';

void main() {
  group('sliceLogsSince', () {
    final cutoff = DateTime.parse('2026-08-14 18:00:00.000000');

    test('drops records older than the cutoff', () {
      final text =
          record('2026-08-14 17:45:00.000000', 'previous session') +
          record('2026-08-14 18:30:00.000000', 'this session');

      final result = FinampLogsHelper.sliceLogsSince(text, cutoff);

      expect(result, isNot(contains('previous session')));
      expect(result, contains('this session'));
    });

    test('keeps a record exactly at the cutoff', () {
      final text = record('2026-08-14 18:00:00.000000', 'boundary');
      expect(FinampLogsHelper.sliceLogsSince(text, cutoff), contains('boundary'));
    });

    test('keeps indented continuation lines with their record', () {
      final text =
          '${record('2026-08-14 18:30:00.000000', 'failed to play')}'
          '\t\t#0      MusicPlayer.play\n'
          '\t\t#1      QueueService.start\n';

      final result = FinampLogsHelper.sliceLogsSince(text, cutoff);

      expect(result, contains('#0      MusicPlayer.play'));
      expect(result, contains('#1      QueueService.start'));
    });

    test('drops a stack trace belonging to a record older than the cutoff', () {
      final text =
          '${record('2026-08-14 17:00:00.000000', 'old failure')}'
          '\t\t#0      Old.frame\n'
          '${record('2026-08-14 18:30:00.000000', 'recent')}';

      final result = FinampLogsHelper.sliceLogsSince(text, cutoff);

      expect(result, isNot(contains('#0      Old.frame')));
      expect(result, contains('recent'));
    });

    test('keeps text before the first parsable record', () {
      // Interleaved and truncated writes were observed in real exports.
      const text = 'half a line with no header\n';
      expect(FinampLogsHelper.sliceLogsSince(text, cutoff), contains('half a line'));
    });

    test('trims oldest records when over the byte cap and says so', () {
      final text =
          record('2026-08-14 18:10:00.000000', 'a' * 400) +
          record('2026-08-14 18:20:00.000000', 'b' * 400) +
          record('2026-08-14 18:30:00.000000', 'c' * 400);

      final result = FinampLogsHelper.sliceLogsSince(text, cutoff, maxBytes: 900);

      expect(result, contains('earlier records omitted'));
      expect(result, isNot(contains('a' * 400)));
      expect(result, contains('c' * 400));
    });

    test('returns text under the cap untouched', () {
      final text = record('2026-08-14 18:30:00.000000', 'short');
      expect(FinampLogsHelper.sliceLogsSince(text, cutoff, maxBytes: 512 * 1024), text);
    });

    test('handles empty input', () {
      expect(FinampLogsHelper.sliceLogsSince('', cutoff), '');
    });

    test('keeps records whose logger name contains a slash', () {
      final text = record('2026-08-14 18:30:00.000000', 'kept', logger: 'Finamp/Audio', level: 'SEVERE');
      expect(FinampLogsHelper.sliceLogsSince(text, cutoff), contains('kept'));
    });
  });
}
