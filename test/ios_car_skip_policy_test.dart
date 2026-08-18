import 'package:audio_service/audio_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS car skip system actions', () {
    test('iOS seek controls expose scrubber only, not hold-to-scan', () {
      expect(
        mediaNotificationSystemActions(showSeekControls: true, isIOS: true),
        const {MediaAction.seek},
      );
    });

    test('Android seek controls keep hold-to-scan', () {
      expect(
        mediaNotificationSystemActions(showSeekControls: true, isIOS: false),
        const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      );
    });

    test('disabling seek controls advertises no system seek actions', () {
      expect(
        mediaNotificationSystemActions(showSeekControls: false, isIOS: true),
        isEmpty,
      );
    });
  });
}
