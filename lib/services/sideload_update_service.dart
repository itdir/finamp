import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Default floating Release asset for [latest.json].
const kSideloadDefaultManifestUrl =
    'https://github.com/itdir/finamp/releases/download/sideload-latest/latest.json';

class SideloadManifest {
  SideloadManifest({
    required this.version,
    required this.build,
    required this.upstreamVersion,
    required this.publishedAt,
    required this.notes,
    this.androidApkUrl,
    this.androidSha256,
    this.androidSizeBytes,
    this.iosIpaUrl,
    this.iosSha256,
    this.iosSizeBytes,
    this.sideStoreSourceUrl,
  });

  final String version;
  final int build;
  final String upstreamVersion;
  final String? publishedAt;
  final String notes;
  final String? androidApkUrl;
  final String? androidSha256;
  final int? androidSizeBytes;
  final String? iosIpaUrl;
  final String? iosSha256;
  final int? iosSizeBytes;
  final String? sideStoreSourceUrl;

  factory SideloadManifest.fromJson(Map<String, dynamic> json) {
    final android = json['android'] as Map<String, dynamic>?;
    final ios = json['ios'] as Map<String, dynamic>?;
    return SideloadManifest(
      version: json['version'] as String? ?? '',
      build: (json['build'] as num?)?.toInt() ?? 0,
      upstreamVersion: json['upstreamVersion'] as String? ?? '',
      publishedAt: json['publishedAt'] as String?,
      notes: json['notes'] as String? ?? '',
      androidApkUrl: android?['apkUrl'] as String?,
      androidSha256: android?['sha256'] as String?,
      androidSizeBytes: (android?['sizeBytes'] as num?)?.toInt(),
      iosIpaUrl: ios?['ipaUrl'] as String?,
      iosSha256: ios?['sha256'] as String?,
      iosSizeBytes: (ios?['sizeBytes'] as num?)?.toInt(),
      sideStoreSourceUrl: ios?['sideStoreSourceUrl'] as String?,
    );
  }

  /// True when the feed points at a real IPA (not a placeholder URL with size 0).
  bool get hasUsableIosIpa {
    final url = iosIpaUrl?.trim() ?? '';
    if (url.isEmpty) return false;
    final size = iosSizeBytes ?? 0;
    final sha = iosSha256?.trim() ?? '';
    return size > 0 || sha.isNotEmpty;
  }

  /// SideStore only when a usable IPA is published with a source URL.
  bool get hasUsableSideStoreSource {
    final url = sideStoreSourceUrl?.trim() ?? '';
    return url.isNotEmpty && hasUsableIosIpa;
  }
}

enum SideloadCheckOutcome {
  upToDate,
  updateAvailable,
  downloaded,
  installed,
  deferredPlaying,
  skippedMetered,
  needPermission,
  needUserConfirm,
  unsupportedPlatform,
  error,
}

class SideloadCheckResult {
  SideloadCheckResult({
    required this.outcome,
    this.manifest,
    this.message,
    this.localBuild,
    this.apkPath,
  });

  final SideloadCheckOutcome outcome;
  final SideloadManifest? manifest;
  final String? message;
  final int? localBuild;
  final String? apkPath;
}

class SideloadManifestException implements Exception {
  SideloadManifestException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Fork-only sideload OTA: fetch [latest.json], compare integer build, download
/// + verify, Android silent PackageInstaller; iOS notify / SideStore / USB only.
class SideloadUpdateService {
  SideloadUpdateService();

  static const _channel = MethodChannel('com.unicornsonlsd.finamp/sideload_update');
  final _log = Logger('SideloadUpdateService');

  SideloadManifest? lastManifest;
  SideloadCheckResult? lastResult;
  String? lastError;
  DateTime? lastCheckAt;

  /// When the in-flight check started, or null when idle.
  ///
  /// A plain bool could only be cleared by the `finally` of the run that set
  /// it, so any hang left the user with "Update check already running" until
  /// they force-quit the app. The individual steps are now bounded, and this
  /// timestamp is the backstop if one still gets stuck.
  DateTime? _busySince;

  /// Longest a check can hold the lock: the download deadline plus the install
  /// wait, with room to spare.
  static const _busyMaxAge = Duration(minutes: 40);

  /// No progress on the APK body for this long means the connection died.
  static const _downloadStallTimeout = Duration(seconds: 60);

  /// Whole-download deadline. The APK is large, so this is generous.
  static const _downloadDeadline = Duration(minutes: 30);

  /// How long to wait for Android to report install status before giving up.
  static const _installTimeout = Duration(minutes: 5);

  bool get isBusy {
    final since = _busySince;
    if (since == null) return false;
    if (DateTime.now().difference(since) >= _busyMaxAge) {
      _log.warning('Clearing a stale busy lock held since $since');
      _busySince = null;
      return false;
    }
    return true;
  }

  /// Fraction of the APK downloaded (0..1), or null when not downloading.
  final ValueNotifier<double?> downloadProgress = ValueNotifier<double?>(null);

  static String get manifestUrl {
    final override = FinampSettingsHelper.finampSettings.sideloadManifestUrl;
    if (override != null && override.trim().isNotEmpty) return override.trim();
    return kSideloadDefaultManifestUrl;
  }

  Future<void> syncNativeSchedule({bool? playing}) async {
    if (!Platform.isAndroid) return;
    final settings = FinampSettingsHelper.finampSettings;
    try {
      await _channel.invokeMethod<void>('syncSchedule', {
        'mode': settings.sideloadUpdateMode == SideloadUpdateMode.auto ? 'auto' : 'manual',
        'minutes': settings.sideloadAutoUpdateMinutes,
        'allowCellular': settings.sideloadAllowCellular,
        'manifestUrl': settings.sideloadManifestUrl,
        'playing': playing ?? _isPlaying(),
      });
    } on MissingPluginException {
      // Desktop / tests
    } catch (e, st) {
      _log.warning('syncNativeSchedule failed', e, st);
    }
  }

  bool _isPlaying() {
    try {
      final task = GetIt.instance<MusicPlayerBackgroundTask>();
      return task.playbackState.valueOrNull?.playing ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> androidSetupStatus() async {
    if (!Platform.isAndroid) {
      return {
        'canRequestPackageInstalls': false,
        'isSelfInstallerOfRecord': false,
        'installerPackageName': null,
        'versionCode': null,
      };
    }
    try {
      final can = await _channel.invokeMethod<bool>('canRequestPackageInstalls') ?? false;
      final self = await _channel.invokeMethod<bool>('isSelfInstallerOfRecord') ?? false;
      final installer = await _channel.invokeMethod<String?>('getInstallerPackageName');
      final code = await _channel.invokeMethod<num>('getVersionCode');
      return {
        'canRequestPackageInstalls': can,
        'isSelfInstallerOfRecord': self,
        'installerPackageName': installer,
        'versionCode': code?.toInt(),
      };
    } catch (e) {
      return {
        'canRequestPackageInstalls': false,
        'isSelfInstallerOfRecord': false,
        'installerPackageName': null,
        'versionCode': null,
        'error': e.toString(),
      };
    }
  }

  Future<void> openInstallUnknownAppsSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openInstallUnknownAppsSettings');
  }

  Future<Map<String, dynamic>?> nativeWorkerStatus() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('getLastWorkerStatus');
      return raw?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  Future<String?> consumePendingNotifyVersion() async {
    final status = await nativeWorkerStatus();
    final version = status?['pendingNotifyVersion'] as String?;
    if (version == null || version.isEmpty) return null;
    try {
      await _channel.invokeMethod<void>('clearPendingNotify');
    } catch (_) {}
    return version;
  }

  /// True when Settings should badge Updates (setup incomplete or pending update).
  bool get needsAttention {
    final r = lastResult;
    if (r == null) return false;
    switch (r.outcome) {
      case SideloadCheckOutcome.updateAvailable:
      case SideloadCheckOutcome.needPermission:
      case SideloadCheckOutcome.needUserConfirm:
      case SideloadCheckOutcome.error:
        return true;
      default:
        return false;
    }
  }

  DateTime nextScheduledLocalRun() {
    final minutes =
        FinampSettingsHelper.finampSettings.sideloadAutoUpdateMinutes.clamp(0, 24 * 60 - 1);
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day).add(Duration(minutes: minutes));
    if (!next.isAfter(now)) {
      next = next.add(const Duration(days: 1));
    }
    return next;
  }

  bool shouldNotifyForBuild(int build) {
    return build > FinampSettingsHelper.finampSettings.sideloadLastNotifiedBuild;
  }

  void markNotifiedBuild(int build) {
    if (build > FinampSettingsHelper.finampSettings.sideloadLastNotifiedBuild) {
      FinampSetters.setSideloadLastNotifiedBuild(build);
    }
  }

  /// Launch / resume catch-up: if Auto and past today's window (or never checked
  /// after a missed alarm), run a check. Defers silent install while playing.
  Future<SideloadCheckResult?> catchUpIfNeeded() async {
    // Surface success toast from a background worker install after relaunch.
    final pendingVersion = await consumePendingNotifyVersion();
    if (pendingVersion != null && pendingVersion.isNotEmpty) {
      return SideloadCheckResult(
        outcome: SideloadCheckOutcome.installed,
        message: 'Finamp updated to $pendingVersion',
      );
    }

    final settings = FinampSettingsHelper.finampSettings;
    await syncNativeSchedule();
    if (settings.sideloadUpdateMode != SideloadUpdateMode.auto) {
      return null;
    }
    final now = DateTime.now();
    final minutes = settings.sideloadAutoUpdateMinutes.clamp(0, 24 * 60 - 1);
    final scheduled = DateTime(now.year, now.month, now.day)
        .add(Duration(minutes: minutes));
    final due = !now.isBefore(scheduled);
    final checkedToday = lastCheckAt != null &&
        lastCheckAt!.year == now.year &&
        lastCheckAt!.month == now.month &&
        lastCheckAt!.day == now.day;
    if (!due && checkedToday) return null;
    if (!due) return null;
    // iOS / Manual-style check: install only on Android.
    return checkForUpdate(installIfReady: Platform.isAndroid);
  }

  Future<SideloadCheckResult> checkForUpdate({
    bool installIfReady = false,
    bool forceMetered = false,
  }) async {
    if (isBusy) {
      return SideloadCheckResult(
        outcome: SideloadCheckOutcome.error,
        message: 'Update check already running — wait for the download to finish, '
            'or force-quit Finamp and try again',
      );
    }
    _busySince = DateTime.now();
    lastError = null;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final localBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

      if (!forceMetered && !await _networkAllowed()) {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.skippedMetered,
          localBuild: localBuild,
          message: 'Waiting for Wi‑Fi (turn on “Use mobile data for updates” to allow cellular)',
        );
        lastResult = r;
        lastCheckAt = DateTime.now();
        return r;
      }

      final manifest = await fetchManifest();
      lastManifest = manifest;
      if (manifest.build <= localBuild) {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.upToDate,
          manifest: manifest,
          localBuild: localBuild,
        );
        lastResult = r;
        lastCheckAt = DateTime.now();
        return r;
      }

      if (!installIfReady) {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.updateAvailable,
          manifest: manifest,
          localBuild: localBuild,
        );
        lastResult = r;
        lastCheckAt = DateTime.now();
        return r;
      }

      if (Platform.isIOS) {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.updateAvailable,
          manifest: manifest,
          localBuild: localBuild,
          message:
              'iOS personal team cannot silent-install. Use SideStore or USB Profile install.',
        );
        lastResult = r;
        lastCheckAt = DateTime.now();
        return r;
      }

      if (!Platform.isAndroid) {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.unsupportedPlatform,
          manifest: manifest,
          localBuild: localBuild,
        );
        lastResult = r;
        return r;
      }

      if (_isPlaying()) {
        await syncNativeSchedule(playing: true);
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.deferredPlaying,
          manifest: manifest,
          localBuild: localBuild,
          message: 'Download deferred install until playback is idle',
        );
        // Still download ahead of time.
        final path = await _downloadAndroidApk(manifest);
        lastResult = r;
        lastCheckAt = DateTime.now();
        return SideloadCheckResult(
          outcome: SideloadCheckOutcome.deferredPlaying,
          manifest: manifest,
          localBuild: localBuild,
          apkPath: path,
          message: r.message,
        );
      }

      final setup = await androidSetupStatus();
      if (setup['canRequestPackageInstalls'] != true) {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.needPermission,
          manifest: manifest,
          localBuild: localBuild,
          message: 'Allow Finamp to install updates',
        );
        lastResult = r;
        lastCheckAt = DateTime.now();
        return r;
      }

      final path = await _downloadAndroidApk(manifest);
      final install = await installAndroidApk(path, requireUserAction: false);
      lastCheckAt = DateTime.now();
      if (install['ok'] == true) {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.installed,
          manifest: manifest,
          localBuild: localBuild,
          apkPath: path,
          message: 'Updated to ${manifest.version}',
        );
        lastResult = r;
        return r;
      }
      if (install['status'] == 'pendingUserAction') {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.needUserConfirm,
          manifest: manifest,
          localBuild: localBuild,
          apkPath: path,
          message:
              'Tap Install when Android asks — just this once. After that, updates can install quietly.',
        );
        lastResult = r;
        return r;
      }
      final r = SideloadCheckResult(
        outcome: SideloadCheckOutcome.error,
        manifest: manifest,
        localBuild: localBuild,
        apkPath: path,
        message: install['message']?.toString() ?? 'Install failed',
      );
      lastResult = r;
      lastError = r.message;
      return r;
    } catch (e, st) {
      _log.severe('checkForUpdate failed', e, st);
      lastError = e.toString();
      final r = SideloadCheckResult(
        outcome: SideloadCheckOutcome.error,
        message: e.toString(),
      );
      lastResult = r;
      lastCheckAt = DateTime.now();
      return r;
    } finally {
      _busySince = null;
      downloadProgress.value = null;
      unawaited(syncNativeSchedule(playing: _isPlaying()));
    }
  }

  Future<SideloadManifest> fetchManifest() async {
    final url = manifestUrl;
    final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (response.statusCode == 404) {
      throw SideloadManifestException(
        'No update feed found yet. An update hasn’t been published, or the link is wrong.',
        statusCode: 404,
      );
    }
    if (response.statusCode != 200) {
      throw SideloadManifestException(
        'Couldn’t reach the update server (error ${response.statusCode}). Try again on Wi‑Fi.',
        statusCode: response.statusCode,
      );
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return SideloadManifest.fromJson(json);
  }

  Future<bool> _networkAllowed() async {
    final allowCellular = FinampSettingsHelper.finampSettings.sideloadAllowCellular;
    if (allowCellular) return true;
    final results = await Connectivity().checkConnectivity();
    if (results.contains(ConnectivityResult.none)) return false;
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return true;
    }
    // Treat VPN-only / other as metered unless wifi also present.
    return false;
  }

  Future<String> _downloadAndroidApk(SideloadManifest manifest) async {
    final url = manifest.androidApkUrl;
    final expectedSha = manifest.androidSha256;
    if (url == null || url.isEmpty || expectedSha == null || expectedSha.isEmpty) {
      throw StateError('Manifest missing android apkUrl/sha256');
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/sideload-update.apk');
    if (await file.exists()) await file.delete();

    final size = manifest.androidSizeBytes ?? 0;
    if (size > 0) {
      final free = await _usableSpace(dir);
      if (free != null && free < size + 50 * 1024 * 1024) {
        throw StateError('Not enough free space for APK download');
      }
    }

    final request = http.Request('GET', Uri.parse(url));
    final streamed = await request.send().timeout(const Duration(seconds: 60));
    if (streamed.statusCode != 200) {
      throw StateError('APK HTTP ${streamed.statusCode}');
    }

    // The body needs its own bound. Timing out request.send() only covers the
    // response headers, so a connection that dies mid-transfer used to hang
    // here forever and wedge the busy lock.
    final expectedBytes = manifest.androidSizeBytes ?? 0;
    final sink = file.openWrite();
    var received = 0;
    try {
      final body = streamed.stream.timeout(
        _downloadStallTimeout,
        onTimeout: (sink) => sink.addError(
          TimeoutException('Download stalled with $received of $expectedBytes bytes', _downloadStallTimeout),
        ),
      );
      final deadline = DateTime.now().add(_downloadDeadline);
      await for (final chunk in body) {
        sink.add(chunk);
        received += chunk.length;
        if (expectedBytes > 0) downloadProgress.value = received / expectedBytes;
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Download exceeded ${_downloadDeadline.inMinutes} minutes', _downloadDeadline);
        }
      }
    } on TimeoutException catch (e) {
      throw StateError('Download stopped responding — check the connection and try again ($e)');
    } finally {
      await sink.close();
      downloadProgress.value = null;
    }

    final digest = await sha256.bind(file.openRead()).first;
    final actual = digest.toString();
    if (actual.toLowerCase() != expectedSha.toLowerCase()) {
      await file.delete();
      throw StateError('SHA-256 mismatch (expected $expectedSha got $actual)');
    }
    return file.path;
  }

  Future<int?> _usableSpace(Directory dir) async {
    try {
      // Dart has no portable free-space API; skip soft check on failure.
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> installAndroidApk(
    String path, {
    required bool requireUserAction,
  }) async {
    try {
      // The native side parks this call until PackageInstaller broadcasts a
      // status. If that broadcast never arrives — process death, a dismissed
      // system dialog, an abandoned session — the future never completes, so
      // bound it and release the native slot on the way out.
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('installApk', {
            'path': path,
            'requireUserAction': requireUserAction,
          })
          .timeout(_installTimeout);
      return raw?.map((k, v) => MapEntry(k.toString(), v)) ?? {'ok': false};
    } on TimeoutException {
      await _cancelPendingNativeInstall();
      _log.warning('installApk did not report status within ${_installTimeout.inMinutes} minutes');
      return {
        'ok': false,
        'status': 'timeout',
        'message': 'Android never reported the install result. '
            'Check Settings → Apps for a pending install, then try again.',
      };
    } on PlatformException catch (e) {
      return {
        'ok': false,
        'status': e.code,
        'message': e.message ?? e.code,
      };
    }
  }

  /// Clears the native pending-install slot so the next attempt is not
  /// rejected with `BUSY` by a call we have already given up on.
  Future<void> _cancelPendingNativeInstall() async {
    try {
      await _channel.invokeMethod<void>('cancelPendingInstall');
    } on MissingPluginException {
      // Older native side without this method; nothing to release.
    } catch (e) {
      _log.warning('cancelPendingInstall failed', e);
    }
  }

  /// One-time bootstrap: reinstall the published APK (even if already current)
  /// with a forced Install confirmation so Finamp becomes installer-of-record.
  Future<SideloadCheckResult> finishOneTimeAndroidSetup({
    bool forceMetered = false,
  }) async {
    if (!Platform.isAndroid) {
      return SideloadCheckResult(
        outcome: SideloadCheckOutcome.unsupportedPlatform,
        message: 'Finish setup is only needed on Android',
      );
    }
    if (isBusy) {
      return SideloadCheckResult(
        outcome: SideloadCheckOutcome.error,
        message: 'Update check already running — wait for the download to finish, '
            'or force-quit Finamp and try again',
      );
    }
    _busySince = DateTime.now();
    lastError = null;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final localBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

      if (!forceMetered && !await _networkAllowed()) {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.skippedMetered,
          localBuild: localBuild,
          message:
              'Need Wi‑Fi to download the installer (or turn on “Use mobile data for updates”)',
        );
        lastResult = r;
        lastCheckAt = DateTime.now();
        return r;
      }

      final setup = await androidSetupStatus();
      if (setup['canRequestPackageInstalls'] != true) {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.needPermission,
          localBuild: localBuild,
          message: 'Allow Finamp to install updates first',
        );
        lastResult = r;
        lastCheckAt = DateTime.now();
        return r;
      }

      final manifest = await fetchManifest();
      lastManifest = manifest;
      // Same build is intentional — USB/adb installs don't make Finamp the
      // installer of record; PackageInstaller must run once with user confirm.
      final path = await _downloadAndroidApk(manifest);
      final install = await installAndroidApk(path, requireUserAction: true);
      lastCheckAt = DateTime.now();
      if (install['ok'] == true) {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.installed,
          manifest: manifest,
          localBuild: localBuild,
          apkPath: path,
          message: 'Setup finished — overnight updates can install quietly',
        );
        lastResult = r;
        return r;
      }
      if (install['status'] == 'pendingUserAction') {
        final r = SideloadCheckResult(
          outcome: SideloadCheckOutcome.needUserConfirm,
          manifest: manifest,
          localBuild: localBuild,
          apkPath: path,
          message:
              'Tap Install when Android asks — just this once. After that, updates can install quietly.',
        );
        lastResult = r;
        return r;
      }
      final r = SideloadCheckResult(
        outcome: SideloadCheckOutcome.error,
        manifest: manifest,
        localBuild: localBuild,
        apkPath: path,
        message: install['message']?.toString() ?? 'Couldn’t start the Install prompt',
      );
      lastResult = r;
      lastError = r.message;
      return r;
    } catch (e, st) {
      _log.severe('finishOneTimeAndroidSetup failed', e, st);
      lastError = e.toString();
      final r = SideloadCheckResult(
        outcome: SideloadCheckOutcome.error,
        message: e.toString(),
      );
      lastResult = r;
      lastCheckAt = DateTime.now();
      return r;
    } finally {
      _busySince = null;
      downloadProgress.value = null;
      unawaited(syncNativeSchedule(playing: _isPlaying()));
    }
  }

  /// Install a previously downloaded APK after playback ends.
  Future<SideloadCheckResult> installPendingApkIfAny() async {
    final pending = lastResult;
    if (pending?.apkPath == null || pending?.manifest == null) {
      return SideloadCheckResult(outcome: SideloadCheckOutcome.upToDate);
    }
    if (_isPlaying()) {
      return SideloadCheckResult(
        outcome: SideloadCheckOutcome.deferredPlaying,
        manifest: pending!.manifest,
        apkPath: pending.apkPath,
      );
    }
    final install = await installAndroidApk(pending!.apkPath!, requireUserAction: false);
    if (install['ok'] == true) {
      return SideloadCheckResult(
        outcome: SideloadCheckOutcome.installed,
        manifest: pending.manifest,
        message: 'Updated to ${pending.manifest!.version}',
      );
    }
    return SideloadCheckResult(
      outcome: SideloadCheckOutcome.error,
      manifest: pending.manifest,
      message: install['message']?.toString() ?? 'Install failed',
    );
  }
}
