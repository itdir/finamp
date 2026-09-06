import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';

/// User-visible device name for Embedded Tailscale hostname prefill.
class DeviceDisplayName {
  DeviceDisplayName._();

  static const _androidChannel = MethodChannel(
    'com.unicornsonlsd.finamp/device_display_name',
  );

  /// Best-effort friendly name (iOS Settings name, Android Device name, etc.).
  static Future<String> read() async {
    try {
      if (Platform.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        final name = info.name.trim();
        if (name.isNotEmpty) return name;
      } else if (Platform.isAndroid) {
        try {
          final fromOs = await _androidChannel.invokeMethod<String>('getDeviceName');
          final trimmed = fromOs?.trim() ?? '';
          if (trimmed.isNotEmpty) return trimmed;
        } catch (_) {
          // Fall through to device_info_plus.
        }
        final info = await DeviceInfoPlugin().androidInfo;
        final name = info.name.trim();
        if (name.isNotEmpty && name.toLowerCase() != 'unknown') return name;
        final model = info.model.trim();
        if (model.isNotEmpty) return model;
      } else if (Platform.isMacOS) {
        final info = await DeviceInfoPlugin().macOsInfo;
        final name = info.computerName.trim();
        if (name.isNotEmpty) return name;
      } else if (Platform.isLinux) {
        final info = await DeviceInfoPlugin().linuxInfo;
        final name = info.prettyName.trim();
        if (name.isNotEmpty) return name;
      } else if (Platform.isWindows) {
        final info = await DeviceInfoPlugin().windowsInfo;
        final name = info.computerName.trim();
        if (name.isNotEmpty) return name;
      }
    } catch (_) {
      // Fall through to default.
    }
    return 'finamp';
  }
}
