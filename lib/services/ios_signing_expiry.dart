import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Reads personal-team / development provisioning expiry from the iOS bundle.
///
/// Android and other platforms always return null (no UI).
class IosSigningExpiry {
  IosSigningExpiry._();

  static const _channel = MethodChannel('com.unicornsonlsd.finamp/ios_signing');

  static DateTime? _cached;

  /// Provisioning `ExpirationDate`, or null if unavailable / not iOS.
  static Future<DateTime?> readProvisioningExpiration() async {
    if (!Platform.isIOS) return null;
    if (_cached != null) return _cached;
    try {
      final raw = await _channel.invokeMethod<String>('getProvisioningExpiration');
      if (raw == null || raw.isEmpty) return null;
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) return null;
      _cached = parsed.toLocal();
      return _cached;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Locale-aware date and time strings for [sideloadIosSigningExpires].
  static ({String date, String time}) formatExpiryParts(
    DateTime expiry, {
    required String localeName,
  }) {
    final local = expiry.toLocal();
    final date = DateFormat.yMMMd(localeName).format(local);
    final time = DateFormat.jm(localeName).format(local);
    return (date: date, time: time);
  }

  /// Full line for UI, or null when expiry cannot be shown.
  static String? formatExpiryLine(
    DateTime? expiry, {
    required String localeName,
    required String Function(String date, String time) localize,
  }) {
    if (expiry == null) return null;
    final parts = formatExpiryParts(expiry, localeName: localeName);
    return localize(parts.date, parts.time);
  }

  @visibleForTesting
  static void debugClearCache() {
    _cached = null;
  }
}
